---
doc_type: ddd-model
service: kart-identity-service
status: approved
generated_by: ddd-agent
source: docs/services/kart-identity-service/requirement-spec.md, docs/services/kart-identity-service/edge-cases.md, docs/services/kart-identity-service/design-decisions.md, docs/services/kart-identity-service/architecture.md
---

# DDD Model: kart-identity-service

Four aggregate roots in one bounded context — "who is this, what can they do, and is their token still good" (architecture.md, Boundary Rationale). This model formalizes the aggregate shape `database-design.md` and `api-contract.yaml` already implied consistently while this stage's own file did not yet exist; no aggregate boundary or invariant introduced here contradicts either of those docs — this is a retroactive formalization, not a new design pass.

## Aggregate: UserIdentity

**Entity:** `UserIdentity` — identified by `UserId` (referenced from other bounded contexts, e.g. `kart-cart-service`'s `CartOwner`, per the ubiquitous-language glossary).

**Child entities:**
- `FederatedIdentity` — one external IdP link (enterprise or social) to this `UserIdentity`; identified by `(IdpType, IdpKey, ExternalSubjectId)`.
- `MfaCredential` — the single active or pending TOTP credential for this `UserIdentity`; at most one per user.

**Value objects:**
- `Email` — case-insensitive, nullable (an enterprise assertion is not guaranteed to carry one).
- `PasswordHash` — one-way hash, `null` for a pure federated account that never set a native password.
- `AccountOrigin` — `Native | Social | Enterprise`, denormalized for audit only; source of truth for provenance is the `FederatedIdentity` child collection when not `Native`.
- `RoleGrant` — `(Role, GrantedAt, GrantedBy, RevokedAt)`; a `UserIdentity` holds zero or more live `RoleGrant`s from the fixed vocabulary `Customer | SupportAgent | Admin | PartnerApi`.

**Invariants:**
- `Email`, when present, is unique across all `UserIdentity` instances (case-insensitive).
- At most one live (non-revoked) `RoleGrant` per `(UserIdentity, Role)`.
- `Admin` is never auto-granted merely by a successful federated assertion — a `RoleGrant` of `Admin` requires either self-registration-default `Customer` promotion via an out-of-band administrative process, or an explicit `IdpGroupRoleMapping` entry (see that aggregate below) at enterprise-federation time. Social federation resolves to `Customer` only, never consults any mapping.
- A `FederatedIdentity` is JIT-created on first successful federation for an external identity with no existing link, for both enterprise and social paths (requirement-spec.md §2).
- `MfaCredential` moves `pending → active` only via explicit confirmation with a valid first TOTP code; an unconfirmed `pending` credential expires and must be re-enrolled, never silently activates.
- On consuming `UserDataErased` (ADR-0016): `Email`/display name are overwritten with tombstone values, `PasswordHash` is cleared, the `MfaCredential` child is deleted entirely, every `FederatedIdentity` child is deleted, and every `Session` aggregate (below) belonging to this `UserId` is revoked — this is a cross-aggregate side effect the `UserDataErased` handler orchestrates (not a single-aggregate transaction; see Cross-Aggregate Interaction below).

**Domain events:**
- `UserRegistered` (published — existing, BRD §5.4)
- `UserAccountUpdated` (published — existing, ADR-0006; payload `userId`, `email`, `displayName`, `updatedAt`, finalized in event-contract.md)
- `UserDataErased` (consumed — ADR-0016, updated to name Identity; triggers the redaction/revocation invariant above)

## Aggregate: Session

**Entity:** `Session` — identified by `SessionId`; owns the child `RefreshToken` rotation chain.

**Child entity:**
- `RefreshToken` — identified by `TokenId`; forms a rotation lineage via `ParentTokenId` (`null` for a session's first-issued token).

**Value objects:**
- `SessionOrigin` — `Native | Federated`, fixes which absolute-expiry rule applies (30-day sliding / 90-day absolute cap for native; 24-hour absolute, no sliding, for federated — requirement-spec.md §4).
- `RevocationReason` — `Logout | ReuseDetected | AdminLock | RoleChange | PasswordReset | Erasure` (the last added by this model to cover the `UserDataErased` invariant above — a proposed vocabulary addition to `database-design.md`'s existing `revoked_reason` CHECK constraint, flagged here since that file predates this addition).

**Invariants:**
- A `RefreshToken` is single-use: once consumed (rotated), replaying it revokes the entire `Session` (`RevocationReason = ReuseDetected`), not just that one token (edge-cases.md, "Refresh Token Replay After Rotation").
- No `RefreshToken`'s `expires_at` may exceed its parent `Session.absolute_expires_at`, regardless of sliding-window recalculation.
- A `Session`'s identifier is always newly generated at successful authentication, never carried over from a pre-auth session (edge-cases.md, "Session Fixation via Pre-Auth Session Reuse").

**Domain events:**
- `SessionCreated` (published — existing, BRD §5.4)

## Aggregate: ServicePrincipal

**Entity:** `ServicePrincipal` — identified by `ClientId`; covers Partner API clients and Admin Service's own internal caller (ADR-0010).

**Value objects:** `ClientSecretHash` (one-way hash, same treatment as `PasswordHash`), `PrincipalRole` (`Admin | PartnerApi` — the two roles a non-interactive principal can hold).

**Invariants:**
- A revoked `ServicePrincipal` (`status = revoked`) can never obtain a new token via the Client Credentials grant, regardless of a valid `client_secret`.
- No `RefreshToken`/`Session` is ever issued for a `ServicePrincipal` — every Client Credentials grant re-requests a token per the standard OAuth2 pattern (requirement-spec.md §2).

**Domain events:** None — token issuance for a `ServicePrincipal` is a query against this aggregate's state, not a state transition that itself needs to be published.

## Aggregate: IdpGroupRoleMapping

**Entity:** `IdpGroupRoleMapping` — identified by `(IdpAlias, ExternalGroupClaim)`; the config-driven authority requirement-spec.md §2 (resolved Open Question #7) establishes.

**Value objects:** `MappedRole` (`SupportAgent | Admin` only — `Customer`/`PartnerApi` are never federation-mapped targets).

**Invariants:**
- Absent an explicit `IdpGroupRoleMapping` entry for an asserted external group, enterprise federation grants **zero** `RoleGrant`s — fail-closed, never a fallback to `Customer` or `Admin`.
- This aggregate is consulted fresh on every enterprise-federated login, never cached (design-decisions.md, "Caching Strategy for Role/Group-Mapping Resolution (No Cache)") — a staleness concern this model reaffirms as a hard invariant, not just an infrastructure choice.

**Domain events:** None — mapping entries are managed out-of-band by an operator process (database-design.md); no domain event is published on mapping change in v1.

## Cross-Aggregate Interaction

`UserDataErased` consumption is the one operation in this bounded context that touches more than one aggregate root in a single logical unit of work: it writes to `UserIdentity` (tombstone fields, delete `MfaCredential`/`FederatedIdentity` children) and to every affected `Session` (revoke). This does not violate the single-aggregate-transaction DDD convention in spirit — each `Session` revocation is its own idempotent, individually-safe write (the same shape already used for admin-lock's "revoke every live session for this user" operation), and the `UserIdentity` tombstone write is itself a single-aggregate transaction. The handler orchestrates multiple single-aggregate writes sequentially, not one multi-aggregate ACID transaction — consistent with how `RBAC Role Change Outlives an Already-Minted JWT` and admin-lock already extend the same revocation-list write across a user's session set.

All other cross-aggregate reads (`IdpGroupRoleMapping` consulted during `UserIdentity` federation) are reads only, never a write spanning both aggregates in one transaction.

## Modeling Decisions & Assumptions (resolved here, not escalated — engineering defaults, revisable)

1. **`RevocationReason = Erasure` is a proposed vocabulary addition** to `database-design.md`'s `sessions.revoked_reason` CHECK constraint (currently `logout | reuse_detected | admin_lock | role_change | password_reset`) — additive, non-breaking, needed to give the erasure-triggered revocation edge case (edge-cases.md, "`UserDataErased` Arrives While the User Holds Active Sessions") a distinct audit value rather than overloading `admin_lock`.
2. **No new aggregate for `IdpGroupRoleMapping` management.** Per `database-design.md`'s own note, this table is written by an out-of-band operator process with no self-service endpoint in v1 — modeled here as an aggregate for invariant purposes (fail-closed resolution) without implying a public write API exists for it yet.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner, see docs/adr and this run's decision log
- [x] Approved to proceed to API/Database/Event Design Agents
