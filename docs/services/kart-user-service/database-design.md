---
doc_type: database-design
service: kart-user-service
status: approved
generated_by: database-design-agent
source: docs/services/kart-user-service/ddd-model.md, docs/services/kart-user-service/architecture.md, docs/services/kart-user-service/design-decisions.md, docs/services/kart-user-service/requirement-spec.md, docs/services/kart-user-service/edge-cases.md, docs/services/kart-user-service/api-contract.yaml, docs/adr/0016-user-gdpr-erasure-policy.md
---

# Database Design: kart-user-service

Two PostgreSQL tables (`user_profiles`, `addresses`), matching ddd-model.md's one-aggregate, child-entity split — every write touching an address goes through the same aggregate-level transaction as its parent `user_profiles` row (ddd-model.md's "why one aggregate" reasoning: the per-type default-address invariant requires it). One MongoDB collection (`user_read_model`), one document per `userId`.

## PostgreSQL (Write Side)

```sql
-- ── user_profiles ───────────────────────────────────────────────────────
-- Backs the UserProfile aggregate root (ddd-model.md). One row per user;
-- created only by consuming UserRegistered, never by a client-facing write.
CREATE TABLE user_profiles (
    user_id               TEXT PRIMARY KEY,        -- issued by kart-identity-service (ddd-model.md — this service never generates its own)
    email_copy            TEXT,                    -- denormalized from UserAccountUpdated (ADR-0006); never write-authoritative here
    display_name_copy     TEXT,
    contact_copy_updated_at TIMESTAMPTZ,            -- the UserAccountUpdated.updatedAt value last applied — the apply-if-newer guard's comparison column (ddd-model.md)
    locale                TEXT,
    currency              TEXT,
    notification_opt_in   JSONB NOT NULL DEFAULT '{}',  -- {email, sms, push} — requirement-spec §2's JSONB decision
    marketing_consent     BOOLEAN NOT NULL DEFAULT false,
    app_installed         BOOLEAN NOT NULL DEFAULT false,
    erasure_status        TEXT NOT NULL CHECK (erasure_status IN ('Active', 'Erased')) DEFAULT 'Active',
    erased_at             TIMESTAMPTZ,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),   -- BRD §24.3; stamped only by the UserRegistered consumer, never a client write
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),   -- BRD §24.3; bumped on every profile/preference/erasure write
    created_by            TEXT NOT NULL,                       -- BRD §24.3 — the acting principal; 'system:identity-registration-consumer' for the UserRegistered-triggered insert (this row is never client-created directly)
    updated_by            TEXT NOT NULL                        -- BRD §24.3 — the owning userId for a self-service write, 'system:identity-account-sync-consumer' for a UserAccountUpdated-triggered contactCopy reconciliation, or Admin Service's client-credentials principal for the erasure-tombstone write (ADR-0017)
);

-- ── addresses ───────────────────────────────────────────────────────────
-- Child entity of UserProfile (ddd-model.md) — never its own aggregate.
-- Every write here is issued inside the same transaction as its parent
-- user_profiles row's updated_at bump, enforcing the per-type default
-- invariant atomically (see the partial unique index below).
CREATE TABLE addresses (
    address_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id       TEXT NOT NULL REFERENCES user_profiles(user_id),
    type          TEXT NOT NULL CHECK (type IN ('Shipping', 'Billing', 'Other')),
    line1         TEXT NOT NULL,
    line2         TEXT,
    city          TEXT NOT NULL,
    region        TEXT,
    postal_code   TEXT NOT NULL,
    country_code  TEXT NOT NULL,
    phone         TEXT,
    is_default    BOOLEAN NOT NULL DEFAULT false,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),   -- BRD §24.3
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),   -- BRD §24.3; bumped on every whole-record-replace write touching this address
    created_by    TEXT NOT NULL,                        -- BRD §24.3 — the owning userId for every client-facing address write (this table has no system-only insert path)
    updated_by    TEXT NOT NULL                         -- BRD §24.3 — the owning userId, or Admin Service's client-credentials principal for the erasure-tombstone write (ADR-0017)
);

-- Enforces "at most one default Address per (user_id, type)" (ddd-model.md
-- invariant) at the database layer, not just in application code — a
-- partial unique index that only constrains rows where is_default is true.
CREATE UNIQUE INDEX idx_addresses_one_default_per_type
    ON addresses (user_id, type) WHERE is_default;

-- Supports "list every address for this user" — the read-projection
-- rebuild query and the address-book write path's own "load the whole
-- aggregate" pattern (ddd-model.md's whole-record-replace concurrency
-- model, edge-cases.md "Concurrent profile writes").
CREATE INDEX idx_addresses_user_id ON addresses (user_id);

-- ── user_outbox_events ──────────────────────────────────────────────────
-- Standard platform Outbox table (BRD §11; design-decisions.md's "Event
-- Publication Reliability" decision) — one mechanism reused for
-- UserProfileUpdated, UserNotificationPreferenceUpdated, and
-- UserDataErased alike, never a separate publish path per event type.
CREATE TABLE user_outbox_events (
    id           BIGSERIAL PRIMARY KEY,
    event_type   TEXT NOT NULL,       -- UserProfileUpdated | UserNotificationPreferenceUpdated | UserDataErased
    user_id      TEXT NOT NULL,
    payload      JSONB NOT NULL,
    occurred_at  TIMESTAMPTZ NOT NULL DEFAULT now(),  -- this table's created_at under BRD §24.3, in the domain's own event vocabulary
    published_at TIMESTAMPTZ,
    created_by   TEXT NOT NULL,                        -- BRD §24.3 — the principal whose write to user_profiles/addresses produced this outbox row (the acting userId, or a system:* principal for a consumer-triggered write, mirroring created_by on the row that triggered it)
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),   -- BRD §24.3; bumped when published_at is set
    updated_by   TEXT NOT NULL DEFAULT 'system:user-outbox-poller' -- BRD §24.3 — the Outbox poller is the only process that ever updates a row after insert
);

CREATE INDEX idx_user_outbox_unpublished ON user_outbox_events (id) WHERE published_at IS NULL;
```

### Why the default-address invariant is a database constraint, not just an application check

`ddd-model.md`'s invariant ("at most one default `Address` per type") is enforced by the load-mutate-save-whole-aggregate pattern at the application layer (edge-cases.md's last-write-wins concurrency decision already commits to whole-record replace, so the application already loads every address before writing any one of them) — the partial unique index above is a database-layer backstop against that application logic having a bug, not the primary enforcement mechanism. This mirrors the same "invariant enforced in the aggregate, API/DB-layer checks are a backstop, never the only line of defense" principle `api-standards.md` already states generally.

## Row-Level Security Policy (BRD §24.1.4)

Per BRD §24.1.4, the service whose database physically holds a row decides and enforces that row's row-level security — never a shared, central component. User Service's write model is entirely PostgreSQL (`user_profiles`, `addresses`), and both tables have a genuine per-row end-user ownership concept, so native RLS is the mechanism for each.

**Session-scoped principal setting.** Same ambient mechanism already established platform-wide (see `kart-identity-service/database-design.md`'s precedent): immediately after acquiring a pooled connection and before any query runs, this service issues `SET LOCAL app.current_principal = <id>` and `SET LOCAL app.current_principal_kind = <'user'|'service'|'system'>`, resolved server-side from the validated JWT / client-credentials / event-consumer context — never a client-suppliable value. `app.current_principal` is the caller's own `user_id` for self-service profile/address requests, Admin Service's client-credentials `client_id` for the erasure-tombstone write (ADR-0017), or a well-known `system:*` id for the `UserRegistered`/`UserAccountUpdated` event consumers and the Outbox poller. This is the same resolved-principal value the shared `kart-shared` `created_by`/`updated_by` interceptor (§24.3, above) stamps onto every mutation — RLS and audit-column injection read one ambient current-principal accessor from that same package, not two independently-maintained notions of "who is acting."

**Policy shape.** Both tables' policies grant access when the row's `user_id` matches `app.current_principal`, **or** when `app.current_principal_kind` is `service`/`system`. The latter branch is not a blanket bypass: per requirement-spec.md's §24.1.2 cross-reference, the erasure-tombstone write is already restricted to Admin Service's own client-credentials principal at the API layer, and the `UserRegistered`/`UserAccountUpdated` consumers and the Outbox poller are internal processes no external caller can reach at all — RLS's marginal, additive protection here is specifically against the failure mode §24.1.4 itself names (a user-facing code path that forgets its own `WHERE user_id = ...` clause), which stays fully blocked whenever `app.current_principal_kind = 'user'`.

```sql
-- user_profiles: the row's own primary key is the ownership column
ALTER TABLE user_profiles ENABLE ROW LEVEL SECURITY;
CREATE POLICY user_profiles_owner_or_system ON user_profiles
    USING (
        user_id = current_setting('app.current_principal')
        OR current_setting('app.current_principal_kind', true) IN ('service', 'system')
    );

-- addresses: child entity of UserProfile, same user_id ownership column as its parent
ALTER TABLE addresses ENABLE ROW LEVEL SECURITY;
CREATE POLICY addresses_owner_or_system ON addresses
    USING (
        user_id = current_setting('app.current_principal')
        OR current_setting('app.current_principal_kind', true) IN ('service', 'system')
    );
```

**Not covered by this policy (no per-row end-user ownership concept):**

- `user_outbox_events` — an internal relay table read exclusively by this service's own Outbox poller process, never by any end-user- or admin-facing request path directly; its `user_id` column records event-payload provenance for audit, not an access-control predicate the poller itself needs gated against, the same carve-out `kart-identity-service/database-design.md` already documents for its own `outbox_events` table.

## Sensitive / PII Column Classification (BRD §24.1.5)

Column-level security answers a narrower question than row-level security: of the columns in a row a caller already has `CanRead` on (BRD §24.1.2), which does that caller's own coarse role actually see — full value, masked, or nothing. This service is the exact worked example BRD §24.1.5 itself names, so the classification below grounds directly in that table rather than deriving one from scratch.

| Column | Full Value Visible To | Masked/Omitted For | Masking Rule |
|---|---|---|---|
| `addresses.line1`, `addresses.line2` | Owning Customer, Admin | Support Agent | Support Agent sees `city`/`region`/`postal_code` only — enough to verify a shipping/billing location without exposing the exact street address |
| `addresses.phone` | Owning Customer, Admin | Support Agent | Support Agent sees only the last 4 digits (e.g. rendered as `•••• 4821`) — enough to verify caller identity against the account without exposing the full number |
| `user_profiles.email_copy`, `user_profiles.display_name_copy` | Owning Customer, Admin, Support Agent | — | Not masked — these are the denormalized copies of Identity-owned contact fields (ADR-0006) already needed for support-ticket lookups/correspondence; masking them here would block Support Agent's legitimate need to identify and correspond with the customer, the same "already necessary for a caller who can already see the row" carve-out BRD §24.1.5 itself allows for operationally-required columns |

**Why this list and no more:** `locale`/`currency`/`notification_opt_in`/`marketing_consent`/`app_installed`/`erasure_status` and the §24.3 audit columns carry no PII and are not classified as sensitive — every principal who legitimately reaches the row at all (owner, Admin, Support Agent, per the RLS policy above) needs to see them to do their job (e.g. a Support Agent needs the opt-in state to explain why a notification was or wasn't sent). This mirrors BRD §24.1.5's own reasoning for Identity's non-credential columns.

**Enforcement point:** primarily this service's own response-serialization DTO (api-contract.yaml) shaping the `addresses.line1`/`line2`/`phone` fields per the caller's coarse role, per §24.1.5's stated primary control; secondarily, for any direct database connection bypassing this service's own API entirely (an analytics/BI read-replica, ops tooling), native `GRANT SELECT (col1, col2, ...) ON addresses TO <db_role>` restricted to exclude `line1`/`line2`/`phone` for any database role other than this service's own application service role — no such secondary direct-access role exists today per this document, so this is the defense-in-depth control to apply if/when one is added.

## MongoDB (Read Side) — `user_read_model`

```js
// One document per userId — this service's scale (50M registered users,
// BRD §4.1) gives no BRD-stated reason to shard the way Product/Search's
// 100M-SKU catalog does; a single replica set holds this comfortably.
db.createCollection("user_read_model")
// {
//   _id: <userId>,
//   email: <string>,               // denormalized IdentityContactCopy (ddd-model.md)
//   displayName: <string>,
//   addresses: [
//     { addressId, type, line1, line2, city, region, postalCode, countryCode, phone, isDefault }
//   ],
//   preferences: { locale, currency, notificationOptIn: { email, sms, push }, marketingConsent },
//   appInstalled: <bool>,
//   erasureStatus: "Active" | "Erased",
//   lastUpdatedAt: <ISODate>
// }

// Point lookup/write key for GET /v1/users/{userId} and the projector's
// own upsert-on-userId idempotency pattern (edge-cases.md "Duplicate/
// out-of-order UserRegistered delivery").
```

Unlike `kart-product-service`'s SKU-keyed projection (which needed a separate parent/child aggregate reconciliation), this read model is a direct, whole-document reflection of the single `UserProfile` aggregate — the addresses array here is a legitimate embedded array (not a modeling mismatch the way a nested-variants-array would have been for Product), because the write side's own aggregate boundary already treats the full address list as one unit written together.

## Indexing Rationale

| Index | Query it supports | Why needed |
|---|---|---|
| `user_profiles` PK (`user_id`) | Every read/write path — point lookup, keyed by the same id `UserRegistered` carries | Direct primary-key access, no other column identifies a profile |
| `addresses(user_id, type) WHERE is_default` (unique) | The default-address invariant | Database-layer backstop for the aggregate-enforced invariant (see above) |
| `addresses(user_id)` | "Load every address for this user" — the whole-aggregate read/write pattern | Without it, loading one user's full address list before a write scans the entire table |
| `user_outbox_events(id) WHERE published_at IS NULL` | The Outbox poller's own unpublished-row scan | Without it, the poller scans the full, ever-growing outbox history every cycle |

## Partitioning/Sharding

- **`user_profiles`/`addresses`** are bounded by registered-user count (50M, BRD §4.1) — an order of magnitude below Product's 100M-SKU catalog and well within a single PostgreSQL instance's comfortable range for point-lookup-keyed tables; no partitioning called for.
- **`user_outbox_events`** follows the same standard Outbox housekeeping (delete/archive once `published_at` is set and a retention window elapses) every other Outbox-backed service in this platform already uses.
- **`user_read_model`** needs no sharding at this service's stated scale — confirmed here rather than silently assumed, since Product's/Search's sharding-by-`category.id` decision might otherwise read as a platform-wide default it isn't; nothing in the BRD's capacity section names a sharding requirement for User.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner
- [x] Approved (write-model schema — `user_profiles`/`addresses` — reviewed at full write-model approval weight; `user_read_model` is a standard rebuildable projection)
