---
doc_type: database-design
service: kart-identity-service
status: approved
generated_by: database-design-agent
source: docs/services/kart-identity-service/requirement-spec.md, docs/services/kart-identity-service/edge-cases.md, docs/services/kart-identity-service/design-decisions.md, docs/services/kart-identity-service/architecture.md, docs/services/kart-identity-service/api-contract.yaml, docs/services/kart-identity-service/ddd-model.md, docs/adr/0006-identity-user-profile-sync-event.md, docs/adr/0007-event-catalog-completeness.md, docs/adr/0010-admin-service-scope-and-integration.md, docs/adr/0016-user-gdpr-erasure-policy.md
---

# Database Design: kart-identity-service

This schema was originally drafted before `ddd-model.md` existed for this service. That file has since been produced and approved; this schema has been re-checked against its four aggregates (`UserIdentity`, `Session`, `ServicePrincipal`, `IdpGroupRoleMapping`) and needed only one addition (the `erasure` revocation reason below) — no table or index required rework.

The implied aggregate roots, grounded directly in the two approved docs: **UserIdentity** (the account/credential/role/MFA aggregate — requirement-spec.md §2's AuthN/RBAC FRs), **Session** (the login-to-logout/revocation lifecycle a refresh-token family belongs to — requirement-spec.md §4's TTL invariant, edge-cases.md's "Refresh Token Replay After Rotation" and "Session Fixation" cases), and **ServicePrincipal** (the Client Credentials-flow entity for Partner API clients and Admin Service's own internal caller — requirement-spec.md §2's OAuth2-flow FR, ADR-0010). `IdpGroupRoleMapping` is a fourth, smaller aggregate: the config-driven table Identity itself is stated as the sole authority over (requirement-spec.md §2, resolved Open Question #7).

## Write Model (PostgreSQL)

```sql
-- =====================================================================
-- UserIdentity aggregate: native, social-federated, and enterprise-
-- federated (JIT-provisioned) Kart accounts all live in one table
-- (requirement-spec.md §2's "same issuance path as native login" /
-- "same Kart account model" framing). password_hash is NULL for an
-- account that has never set a native password (pure federated
-- accounts) -- no FR states federation ever gains a native password.
-- =====================================================================
CREATE TABLE users (
    user_id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email               CITEXT NULL,             -- nullable: an enterprise assertion is not guaranteed to carry an email claim; case-insensitive per CITEXT to avoid duplicate-account creation on case variants at /auth/login and /auth/register
    password_hash       TEXT NULL,                -- one-way hash (bcrypt/argon2id), NOT the AES-256-at-rest reversible encryption the PII invariant requires for the TOTP secret below -- these are two different security properties and must not be conflated
    display_name        TEXT NOT NULL,
    account_origin       TEXT NOT NULL CHECK (account_origin IN ('native', 'social', 'enterprise')), -- denormalized for observability/audit only; source of truth for "how did this account come to exist" is federated_identities below when account_origin <> 'native'
    locked_at            TIMESTAMPTZ NULL,        -- set by POST /internal/users/{userId}/lock (Admin Service's client-credentials caller only, ADR-0010); NULL = not locked
    locked_by            TEXT NULL,               -- Admin Service's service-principal id, from the calling client-credentials token, for audit
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT now() -- bumped whenever email/display_name changes; the trigger/application write that bumps this is also what enqueues UserAccountUpdated (ADR-0006) into outbox_events below
);

-- Case-insensitive uniqueness for native login lookup and duplicate-registration
-- rejection (api-contract.yaml POST /auth/register, 409 response). Partial because
-- email may be NULL for an enterprise account with no email claim.
CREATE UNIQUE INDEX uq_users_email ON users (email) WHERE email IS NOT NULL;

-- =====================================================================
-- Federated identity link: maps one external IdP identity to exactly one
-- Kart user, for both federation paths (requirement-spec.md §2's SSO FRs).
-- This is the table the SAML ACS / OIDC callback endpoints check first
-- ("does this external identity already have a Kart account") before
-- deciding whether to JIT-provision a new users row (requirement-spec.md
-- §2, resolved "Federated Login With No Matching Kart Account" edge case).
-- =====================================================================
CREATE TABLE federated_identities (
    federated_identity_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id               UUID NOT NULL REFERENCES users(user_id),
    idp_type              TEXT NOT NULL CHECK (idp_type IN ('enterprise', 'social')),
    idp_key               TEXT NOT NULL,          -- idpAlias for enterprise (Okta/Azure AD/Google Workspace instance), provider for social (google/apple) -- matches api-contract.yaml's {idpAlias}/{provider} path params
    external_subject_id   TEXT NOT NULL,           -- the IdP's own subject/NameID for this identity -- Identity never generates this
    linked_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- The JIT-provisioning existence check at every federated callback
-- (SAML ACS, enterprise OIDC callback, social OIDC callback) -- this is
-- the single query that must be an index lookup, not a scan, on the
-- federation critical path (requirement-spec.md §3 Latency NFR).
CREATE UNIQUE INDEX uq_federated_identities_external
    ON federated_identities (idp_type, idp_key, external_subject_id);

-- =====================================================================
-- Config-driven IdP group -> Kart role mapping (requirement-spec.md §2/§4,
-- resolved Open Question #7). Enterprise federation only -- social login
-- is hardcoded to Customer at the application layer and never consults
-- this table (requirement-spec.md §2, explicit). Written by an
-- out-of-band operator process; no endpoint for it exists yet in
-- api-contract.yaml (that spec's own §2 says only "an operator creates
-- that mapping," naming no route) -- flagged here as a gap for a later
-- API Design Agent pass if a self-service management UI/endpoint is ever
-- wanted, not invented as new scope in this document.
-- =====================================================================
CREATE TABLE idp_group_role_mappings (
    mapping_id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    idp_alias             TEXT NOT NULL,           -- the specific configured enterprise IdP this mapping applies to
    external_group_claim  TEXT NOT NULL,           -- the IdP's own group/claim value, e.g. an Okta/Azure AD group name
    role                  TEXT NOT NULL CHECK (role IN ('support_agent', 'admin')), -- 'customer'/'partner_api' are never federation-mapped targets (requirement-spec.md §2/§4: Admin is never auto-granted merely by a successful assertion -- an explicit mapping row is what grants it, this CHECK just narrows to the two roles federation can plausibly grant)
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by            TEXT NOT NULL            -- operator identity/process that created the mapping, for audit
);

-- Read on every enterprise-federated login's role resolution
-- (design-decisions.md, "Caching Strategy for Role/Group-Mapping
-- Resolution (No Cache)" -- must be a direct, uncached, strongly-consistent
-- PostgreSQL read at token-mint time). Absence of a matching row is the
-- fail-closed "zero roles granted" case, not an error.
CREATE UNIQUE INDEX uq_idp_group_role_mappings ON idp_group_role_mappings (idp_alias, external_group_claim);

-- =====================================================================
-- Persisted role grants -- native accounts (Customer by default at
-- registration; Support Agent/Admin elevation is an out-of-band
-- administrative process no stated FR defines a public endpoint for,
-- same "flagged, not invented" treatment as idp_group_role_mappings
-- above) and social-login accounts (always exactly one 'customer' row,
-- inserted at JIT-provisioning time). Enterprise-federated role grants
-- are deliberately NOT persisted here -- they are resolved fresh against
-- idp_group_role_mappings on every login, per the same "no cache /
-- always current" reasoning above; persisting a federated role snapshot
-- would silently reintroduce the staleness that decision exists to
-- prevent (a since-revoked mapping still granting a role from a stale
-- stored row).
-- =====================================================================
CREATE TABLE user_roles (
    user_role_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES users(user_id),
    role            TEXT NOT NULL CHECK (role IN ('customer', 'support_agent', 'admin')), -- 'partner_api' is a ServicePrincipal-only role, see service_principals below
    granted_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    granted_by      TEXT NOT NULL,           -- 'self-registration', 'social-jit', or an admin/operator principal id
    revoked_at      TIMESTAMPTZ NULL
);

-- At most one *live* grant per (user, role) -- read at every native/social
-- token mint to embed the roles claim (requirement-spec.md §2's RBAC FR).
-- Mirrors kart-admin-service's admin_permission_grants pattern for the
-- same "single live row per key" shape.
CREATE UNIQUE INDEX uq_user_roles_live ON user_roles (user_id, role) WHERE revoked_at IS NULL;

-- =====================================================================
-- TOTP (RFC 6238) credential -- requirement-spec.md §2's MFA FR. Secret
-- is reversibly encrypted (AES-256, requirement-spec.md §4's PII
-- invariant) because validating a submitted code requires computing the
-- expected code from the secret, unlike password_hash's one-way hash.
-- 'pending' rows exist between POST /auth/mfa/enroll and
-- .../enroll/confirm (api-contract.yaml); an unconfirmed pending row
-- expires and must be restarted, it never silently activates.
-- =====================================================================
CREATE TABLE mfa_credentials (
    user_id             UUID PRIMARY KEY REFERENCES users(user_id), -- one active TOTP credential per user; enrolling again replaces the row
    encrypted_secret     BYTEA NOT NULL,          -- AES-256 encrypted TOTP secret
    status               TEXT NOT NULL CHECK (status IN ('pending', 'active')),
    enrolled_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    pending_expires_at   TIMESTAMPTZ NULL,        -- set only while status = 'pending'
    confirmed_at         TIMESTAMPTZ NULL
);

-- =====================================================================
-- Session aggregate: the "login-to-logout" lifecycle a refresh-token
-- family belongs to (requirement-spec.md §4's TTL invariant frames the
-- native/federated cap as a per-session property; edge-cases.md's
-- "Session Fixation via Pre-Auth Session Reuse" -- session_id is always
-- newly generated at successful auth, never carried over from a pre-auth
-- session). One row is inserted per successful authentication in the
-- same local transaction as the SessionCreated outbox row (ADR-0007).
-- absolute_expires_at is the hard ceiling refresh-token rotation can
-- never extend past (30-day-sliding/90-day-absolute for native,
-- requirement-spec.md §4; 24-hour absolute, no sliding, for federated,
-- same section resolving edge-cases.md's "Federated Session Can Outlive
-- IdP-Side Revocation Indefinitely").
-- =====================================================================
CREATE TABLE sessions (
    session_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id             UUID NOT NULL REFERENCES users(user_id),
    is_federated         BOOLEAN NOT NULL,
    idp_alias            TEXT NULL,               -- set only when is_federated; enterprise idpAlias or social provider, for audit/per-IdP accounting
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    absolute_expires_at  TIMESTAMPTZ NOT NULL,     -- created_at + 90d (native) or + 24h (federated); refresh_tokens.expires_at below can never exceed this
    revoked_at           TIMESTAMPTZ NULL,
    revoked_reason        TEXT NULL CHECK (revoked_reason IS NULL OR revoked_reason IN (
                              'logout', 'reuse_detected', 'admin_lock', 'role_change', 'password_reset', 'erasure'
                          )) -- 'erasure' added: set by the UserDataErased consumer (ADR-0016; ddd-model.md's UserIdentity aggregate) when revoking every live session for an erased user
);

-- Enumerate a user's live sessions -- the write path for admin-triggered
-- lock/unlock (requirement-spec.md §2's admin-suspension FR) and
-- password-reset-confirm ("all outstanding sessions/refresh-token
-- families... are revoked," api-contract.yaml) both need to mark every
-- live session revoked for a given user_id in one statement.
CREATE INDEX idx_sessions_user_live ON sessions (user_id) WHERE revoked_at IS NULL;

-- =====================================================================
-- Refresh-token rotation chain within a Session (Domain Invariant,
-- requirement-spec.md §4: "single-use and rotated on every refresh").
-- token_hash, not the raw opaque token value, is stored -- same
-- never-store-the-live-secret principle as password_hash. Reuse of an
-- already-consumed token (consumed_at IS NOT NULL when presented again)
-- triggers revoking the *entire session* (edge-cases.md, "Refresh Token
-- Replay After Rotation" -- token-family reuse detection, formalized as
-- Domain Invariant §4), not just this one row.
-- =====================================================================
CREATE TABLE refresh_tokens (
    token_id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id           UUID NOT NULL REFERENCES sessions(session_id),
    parent_token_id      UUID NULL REFERENCES refresh_tokens(token_id), -- NULL for a session's first-issued token; forms the rotation lineage edge-cases.md's decision requires storing
    token_hash           TEXT NOT NULL,
    issued_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at           TIMESTAMPTZ NOT NULL,     -- min(issued_at + 30d, session.absolute_expires_at) for native (sliding, recalculated on each rotation); session.absolute_expires_at itself for federated (no sliding)
    consumed_at          TIMESTAMPTZ NULL,         -- set by the rotation write; NULL = still the live, presentable token for this session
    replaced_by_token_id UUID NULL REFERENCES refresh_tokens(token_id)
);

-- O(1) lookup of the presented token at every POST /auth/refresh call --
-- on the write-path latency budget (requirement-spec.md §3: P95 < 300ms).
CREATE UNIQUE INDEX uq_refresh_tokens_hash ON refresh_tokens (token_hash);

-- Backs the atomic rotation write itself: an UPDATE ... WHERE token_id = $1
-- AND consumed_at IS NULL is the DB-level conditional update
-- design-decisions.md's "Concurrency Control for Refresh-Token Rotation"
-- names as this service's general concurrency pattern for token-state
-- mutation (edge-cases.md, "Concurrent Refresh Race" -- the losing
-- request gets 409, per api-contract.yaml, not an infrastructure error).
CREATE INDEX idx_refresh_tokens_session ON refresh_tokens (session_id);

-- =====================================================================
-- Native password reset -- requirement-spec.md §2's reset-initiate/
-- reset-confirm FRs, added because BRD §24.2's native-account model is
-- unusable without one. Modeled in PostgreSQL, not Redis, for the same
-- reason refresh tokens are: strong-consistency single-use semantics via
-- the same DB-conditional-update pattern, plus the reset-confirm side
-- effect of revoking every outstanding session for the user
-- (api-contract.yaml) benefits from being in the same transactional
-- store as sessions/refresh_tokens rather than a second store.
-- =====================================================================
CREATE TABLE password_reset_tokens (
    reset_token_id  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES users(user_id),
    token_hash      TEXT NOT NULL,
    issued_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at      TIMESTAMPTZ NOT NULL,
    consumed_at     TIMESTAMPTZ NULL
);

CREATE UNIQUE INDEX uq_password_reset_tokens_hash ON password_reset_tokens (token_hash);

-- =====================================================================
-- ServicePrincipal aggregate -- OAuth2 Client Credentials flow
-- (requirement-spec.md §2: "Terminate both OAuth2 flows... Client
-- Credentials (service-to-service)"). Covers Partner API clients and
-- Admin Service's own internal lock/unlock caller (ADR-0010: "callable
-- only by Admin Service's client-credentials principal, Admin-scoped").
-- No refresh token is issued for this grant (api-contract.yaml,
-- POST /auth/token) so there is no sessions/refresh_tokens row for a
-- service principal -- it re-requests a token per the standard
-- client-credentials pattern.
-- =====================================================================
CREATE TABLE service_principals (
    client_id            TEXT PRIMARY KEY,
    client_secret_hash    TEXT NOT NULL,          -- one-way hash, same treatment as users.password_hash
    role                  TEXT NOT NULL CHECK (role IN ('admin', 'partner_api')), -- the two roles a non-interactive service principal can plausibly hold (requirement-spec.md §2: "not applicable to Partner API" for MFA, i.e. Partner API is itself a role a client-credentials principal can carry)
    status                TEXT NOT NULL CHECK (status IN ('active', 'revoked')) DEFAULT 'active',
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- =====================================================================
-- Transactional Outbox (design-decisions.md, "Event Publication
-- Reliability -- Transactional Outbox on RabbitMQ"). One table for all
-- three of this service's published events: UserRegistered
-- (ADR-0007), SessionCreated (ADR-0007), UserAccountUpdated (ADR-0006).
-- sequence_no gives User Service's consumer a monotonic value to apply
-- last-write-wins by (edge-cases.md, "Out-of-Order Delivery of
-- Successive UserAccountUpdated Events") -- flagged, per that edge
-- case's own note, as a *proposed* payload-field addition the Event
-- Design Agent must still confirm, not treated as already-approved here.
-- =====================================================================
CREATE TABLE outbox_events (
    event_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    sequence_no    BIGSERIAL NOT NULL,             -- monotonic across this table; source of the proposed UserAccountUpdated ordering field above
    aggregate_id   UUID NOT NULL,                  -- users.user_id
    event_type     TEXT NOT NULL CHECK (event_type IN ('UserRegistered', 'SessionCreated', 'UserAccountUpdated')),
    payload        JSONB NOT NULL,
    occurred_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    published_at   TIMESTAMPTZ NULL                -- set only by the Outbox poller after a successful publish to ecommerce.events (kart-conventions.md)
);

-- Standard Outbox poller scan (BRD §11) -- keeps it an index range-scan,
-- not a full-table scan, as this table grows with every login/refresh.
CREATE INDEX idx_outbox_events_unpublished ON outbox_events (occurred_at) WHERE published_at IS NULL;
```

### Note on `CITEXT`

`users.email` uses PostgreSQL's `citext` extension for case-insensitive comparison/uniqueness, avoiding an application-layer `lower(email)` normalization step on every login/registration write and read. This is a standard PostgreSQL extension, not a new external dependency; if `citext` is unavailable in the target environment, the equivalent is a `TEXT` column plus a `lower(email)` expression-based unique index and lower-cased comparisons everywhere `email` is queried -- flagged here as an implementation choice, not a requirement-spec-stated one.

## Read Model / Cache

**No MongoDB read model.** Identity has no read-heavy, latency-budgeted query path that benefits from a separate denormalized store: `/auth/login` and `/auth/refresh` need strongly-consistent reads against exactly the write-model tables above (design-decisions.md, "Caching Strategy for Role/Group-Mapping Resolution (No Cache)"; architecture.md's "Redundancy / Availability Architecture" explicitly rules out even an async PostgreSQL read replica on this path, "an async replica reintroduces the exact staleness risk that decision rejected a cache for"). This mirrors `kart-admin-service`'s precedent (also no read model, for the analogous reason: a stale authorization-adjacent read is a security defect, not a UX one).

**Redis holds only ephemeral, non-authoritative security state -- never a cache of the PostgreSQL tables above:**

- The revocation list (`identity:revocation:*`) the Gateway consults on every request (edge-cases.md, "Stale Revocation Under Stateless JWT Validation"; also reused for role-change and admin-lock per "RBAC Role Change Outlives an Already-Minted JWT").
- MFA partial-auth challenge state (`identity:mfa-challenge:*`, edge-cases.md, "Partial-Auth Window During MFA") -- deliberately never a token, only a server-side challenge id.
- SAML consumed-assertion-ID replay cache (`identity:saml-assertion:*`, edge-cases.md, "SAML Assertion Replay at the ACS Endpoint"), TTL'd to the assertion's own validity window.
- Per-account/per-IP login-attempt throttle counters for `/auth/login` (edge-cases.md, "Credential Stuffing / Brute-Force"). Not explicitly named alongside the three items above in design-decisions.md's "Shared State-Store Technology" decision, but the same shape of problem (short-lived, TTL-bounded, must-be-visible-to-every-instance) -- placed in the same shared Redis deployment as a direct extension of that decision's own reasoning, flagged here as this document's own inference rather than a restatement of an already-made call.

All four are namespaced keys in the single shared Redis deployment design-decisions.md already specifies -- none of them are modeled as PostgreSQL tables, and none of them are rebuilt/projected from the write model above (they are original, not derived, state -- the CQRS standard's "read model is always rebuildable from the write model" rule does not apply to them because they are not read models of `users`/`sessions`/etc., they are their own short-lived security state).

## Indexing Rationale

| Index | Query it supports | Why needed |
|---|---|---|
| `uq_users_email` (partial, `email IS NOT NULL`) | `/auth/login` credential lookup, `/auth/register` duplicate-email rejection (409), `/auth/password/reset-initiate` account lookup | All three are on the auth critical path (requirement-spec.md §3: P95 < 150ms read / P95 < 300ms write); partial because enterprise-federated accounts may have no email claim |
| `uq_federated_identities_external` | The JIT-provisioning existence check every SAML ACS / enterprise OIDC callback / social OIDC callback endpoint runs first | Same latency budget as login; without this index, every federated callback would scan the whole table to answer "does this external identity already have a Kart account" |
| `uq_idp_group_role_mappings` | Enterprise-federation role resolution at token-mint time | design-decisions.md's "No Cache" decision requires this to be a direct, indexed PostgreSQL read on every enterprise login, not a cached lookup -- the index is what keeps that read cheap enough to accept |
| `uq_user_roles_live` (partial, `revoked_at IS NULL`) | Native/social role-claim embedding at token mint | Same latency budget; also the DB-enforced invariant "at most one live grant per (user, role)," mirroring `kart-admin-service`'s `admin_permission_grants` pattern |
| `idx_sessions_user_live` (partial, `revoked_at IS NULL`) | `POST /internal/users/{userId}/lock` and `POST /auth/password/reset-confirm`'s "revoke every outstanding session for this user" write | Both must enumerate/update a user's live sessions in one indexed pass, not a full-table scan of `sessions` |
| `uq_refresh_tokens_hash` | `POST /auth/refresh`'s token lookup + the atomic conditional-update rotation write | On the write-path latency budget (P95 < 300ms, requirement-spec.md §3); also the row the DB-level conditional update (`WHERE token_id = $1 AND consumed_at IS NULL`) targets, per design-decisions.md's concurrency-control decision |
| `idx_refresh_tokens_session` | Reuse-detection / audit walk of a session's rotation lineage; joining a session's revoked state into a refresh-token validity check | Supports edge-cases.md's "Refresh Token Replay After Rotation" family-revocation logic without a scan |
| `uq_password_reset_tokens_hash` | `POST /auth/password/reset-confirm`'s token lookup | Same write-path latency budget as refresh-token rotation |
| `idx_outbox_events_unpublished` (partial, `published_at IS NULL`) | The Outbox poller's "find rows not yet published" scan | Standard Outbox mechanics (BRD §11); keeps the poller a cheap index range-scan as this table accumulates one row per login/registration/profile-field change |

No index is added for `service_principals` beyond its `client_id` primary key -- `POST /auth/token`'s Client Credentials lookup is a direct PK read, and the table's row count (configured Partner API clients + Admin Service's own principal) is small and static by construction.

## Partitioning/Sharding

Not needed at current scale for any table. `refresh_tokens` is the fastest-growing table (one new row per rotation, and native sessions can refresh repeatedly over a 30-day sliding window), but each row is small and the table is never scanned end-to-end on the request path (every read is an indexed point lookup by `token_hash`, per the Indexing Rationale above) -- this is a fundamentally different shape from the BRD capacity plan's high-throughput order/payment paths. `outbox_events` accumulates similarly (one row per login/registration/profile change) but the poller's partial index keeps its operative working set small regardless of total table size. If retention of old, fully-consumed `refresh_tokens`/`outbox_events` rows later becomes an operational concern (backup/restore time, table bloat), range-partitioning either by `issued_at`/`occurred_at` (e.g., monthly) with old partitions archived is the natural next step -- flagged as a later cost detail, not decided here, mirroring `kart-admin-service/database-design.md`'s identical partitioning note for its own append-only `admin_actions` table.

## Resolved — `UserDataErased` (ADR-0016) Redaction Shape

ADR-0016 has been updated to name Identity as a consumer, closing the gap `architecture.md` previously flagged. On consuming `UserDataErased` (`userId`), the handler performs, per `ddd-model.md`'s `UserIdentity` aggregate invariant:

1. `UPDATE users SET email = NULL, display_name = '[erased]', password_hash = NULL WHERE user_id = $1;`
2. `DELETE FROM mfa_credentials WHERE user_id = $1;`
3. `DELETE FROM federated_identities WHERE user_id = $1;`
4. For every row in `idx_sessions_user_live` matching `user_id = $1`: `UPDATE sessions SET revoked_at = now(), revoked_reason = 'erasure' WHERE session_id = ...` (same enumerate-and-revoke shape already used by admin-lock and password-reset-confirm).

All four steps run in the same application-layer handler; steps 1–3 are a single `UserIdentity`-aggregate transaction, step 4 is a per-`Session` write (consistent with `ddd-model.md`'s Cross-Aggregate Interaction note — this is sequential single-aggregate writes, not one multi-aggregate ACID transaction). `refresh_tokens` and `outbox_events` rows for the erased user are left as historical audit rows (their `session_id`/`aggregate_id` foreign keys remain valid against the now-tombstoned `users` row) — nothing in ADR-0016 or requirement-spec.md requires purging them, only the live PII fields and the ability to authenticate.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner
- [x] Approved (write-model schema)
