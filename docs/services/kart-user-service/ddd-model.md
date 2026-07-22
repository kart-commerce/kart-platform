---
doc_type: ddd-model
service: kart-user-service
status: approved
generated_by: ddd-agent
source: docs/services/kart-user-service/architecture.md, docs/services/kart-user-service/design-decisions.md, docs/services/kart-user-service/requirement-spec.md, docs/services/kart-user-service/edge-cases.md, docs/ddd/ubiquitous-language.md, docs/adr/0006-identity-user-profile-sync-event.md, docs/adr/0016-user-gdpr-erasure-policy.md, docs/adr/0017-user-erasure-request-intake-caller.md
---

# DDD Model: kart-user-service

One aggregate root. Addresses are modeled as child entities inside it, not a separate aggregate — this is a direct consequence of two decisions already locked upstream, not a fresh call this stage is making unilaterally:

- **Per-type default-address invariant** ("at most one default `shipping` address and one default `billing` address at a time," requirement-spec §2) is a real cross-row invariant — setting a new default must atomically clear any prior default of the same type for the same user. That can only be enforced inside one transaction boundary, which is exactly the aggregate-boundary test (`ddd-agent.md`): if two things must commit together, they're one aggregate, not two.
- **edge-cases.md's concurrency decision already assumes this shape.** "Concurrent profile writes from multiple devices/sessions" chose last-write-wins "generalized... for the profile write model as a whole (addresses, preferences, and any future profile field), not scoped only to the 'two default addresses' case" — a whole-record-replace semantic, explicitly rejecting the alternative ("field-level merge instead of whole-record replace"). Whole-record replace only makes sense if there is one record (one aggregate) being replaced, not several independently-versioned ones.

## Aggregate: UserProfile

**Entity:** `UserProfile` — identified by `UserId` (referenced from `kart-identity-service`'s `UserIdentity`; this service never generates its own user identifier — requirement-spec §4's domain invariant that a profile record must not exist independent of a corresponding `UserRegistered` event).

**Child entity:**
- `Address` — identified by `AddressId` (server-generated); zero or more per `UserProfile`.

**Value objects:**
- `AddressDetail` — `{ type: AddressType, line1, line2, city, region, postalCode, countryCode, phone }`, the structured fields requirement-spec §2 already fixed.
- `AddressType` — `Shipping | Billing | Other`.
- `Preferences` — `{ locale, currency, notificationOptIn: { email, sms, push }, marketingConsent }`, stored as one JSONB value (requirement-spec §2's "single JSONB column... additive fields don't require a schema migration" decision — modeled here as one value object so the write-side column and this aggregate's own field stay in lockstep).
- `IdentityContactCopy` — `{ email, displayName, updatedAt }`, the denormalized, eventually-consistent copy of Identity-owned fields (ADR-0006) — `UserProfile` never treats this as write-authoritative for conflict purposes (requirement-spec §4).
- `ErasureStatus` — `Active | Erased`, plus `erasedAt` (nullable) — the tombstone marker ADR-0016 requires.

**Fields:** `userId`, `addresses: Address[]`, `preferences: Preferences`, `appInstalled: boolean`, `contactCopy: IdentityContactCopy`, `erasureStatus: ErasureStatus`, `lastUpdatedAt`.

**Invariants:**
- A `UserProfile` may only come into existence by consuming `UserRegistered` (requirement-spec §4) — this service never creates one via a client-facing write; `POST`-style creation has no meaning on this aggregate's own API surface (see api-contract.yaml).
- At most one `Address` per `AddressType` may have `isDefault = true` at a time, enforced by clearing any prior default of the same type in the same write that sets a new one (the load-mutate-save-whole-aggregate pattern this modeling forces — see "Why one aggregate" above).
- `contactCopy` is written only by consuming `UserAccountUpdated`, never by a client-facing profile write, and only if the incoming `updatedAt` is strictly newer than the currently-stored value (ADR-0006; `kart-identity-service/event-contract.md`'s confirmed `updatedAt` field — resolves the ordering gap `architecture.md`'s earlier drafting pass had left open).
- Once `erasureStatus = Erased`, every PII-bearing field (`addresses`, `contactCopy.email`, `contactCopy.displayName`, address `phone` fields) is overwritten with a fixed tombstone sentinel (ADR-0016 item 2) — this is a one-directional transition; nothing in requirement-spec.md, edge-cases.md, or ADR-0016 defines or asks for an "un-erase" path.
- The MongoDB read projection must be rebuildable from this aggregate's PostgreSQL rows plus replayed events (requirement-spec §4's CQRS-rebuildability invariant, general platform property).

**Domain events:**
- Consumed: `UserRegistered` (external — owned by `kart-identity-service`; `userId`, `email`; aggregate-creation trigger only, requirement-spec §2/§4).
- Consumed: `UserAccountUpdated` (external — owned by `kart-identity-service`; `userId`, `email`, `displayName`, `updatedAt`) — writes only `contactCopy`, applied only if newer (see invariants above).
- Published: `UserProfileUpdated` — fired on a write to `addresses` or `preferences` (this aggregate's own authoritative fields). **Modeling decision, not re-litigating anything upstream:** a `contactCopy` reconciliation from `UserAccountUpdated` does **not** re-publish `UserProfileUpdated` — Analytics (the confirmed consumer, ADR-0004) already receives `UserAccountUpdated` directly from Identity; re-publishing here would double-signal the identical underlying change through two different events for the same consumer.
- Published: `UserNotificationPreferenceUpdated` — fired on a write to `preferences.notificationOptIn` or `appInstalled` specifically (`userId`, per-channel-per-category opt-out map, `appInstalled`). **New — resolved from `kart-notification-service`'s own approved docs** (its requirement-spec §6 Q3, its architecture.md's "Resolved Integration-Contract Question"), formalized as a first-class domain event here per this stage's own remit. Fired alongside `UserProfileUpdated` when the triggering write touches these specific fields, not instead of it — Notification needs the narrower, translated shape; Analytics/other consumers of the general profile-changed signal still get `UserProfileUpdated`.
- Published: `UserDataErased` (`userId`, `erasedAt`) — fired once the tombstone write (triggered by `POST /internal/users/{userId}/erasure-requests`, ADR-0016/ADR-0017) commits.

## Referenced Elsewhere (owned by another bounded context — accessed via ACL, not redefined here)

| Term | Owning Context | How this service uses it |
|---|---|---|
| UserId | `kart-identity-service` | `UserProfile`'s own identity; this service never generates or issues one, only consumes it from `UserRegistered`. |
| Email / DisplayName | `kart-identity-service` | Mirrored into `contactCopy` as a denormalized, eventually-consistent projection (ADR-0006); never treated as write-authoritative here. |
| Admin (erasure-request caller) | `kart-admin-service` | `POST /internal/users/{userId}/erasure-requests` is invoked by Admin Service (ADR-0017); this service never models Admin's own permission-grant or role concepts. |

## Modeling Decisions & Assumptions (resolved here, not escalated — engineering defaults, revisable)

1. **One aggregate, not two.** `Address` is a child entity of `UserProfile`, not its own aggregate root — see "Why one aggregate" above. Revisable only if a future requirement demands independent, non-blocking concurrent writes to different addresses under the same user, which nothing today asks for.
2. **`UserProfileUpdated` and `UserNotificationPreferenceUpdated` are not mutually exclusive.** A single write that changes `notificationOptIn` publishes both — the general-purpose signal and the narrow translation event — rather than picking one. Rejected alternative: firing only the narrower event for a preference-only change, which would silently stop notifying Analytics (a full-fan-in consumer, ADR-0004) of a change it currently expects to see via `UserProfileUpdated`.
3. **`appInstalled` is modeled as a top-level field, not nested inside `Preferences`.** `kart-notification-service/architecture.md` treats it as "the same category of user-set signal as opt-out" but does not describe it as a user-configurable preference in the same UI sense (`locale`/`marketingConsent`, etc.) — likely set by a device-registration signal rather than a settings-page toggle. Kept as its own field so a future distinction between "things the user explicitly chose" and "things the client app reported" isn't collapsed into one JSONB blob prematurely.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner
- [x] Approved to proceed to API/Database/Event Design Agents
