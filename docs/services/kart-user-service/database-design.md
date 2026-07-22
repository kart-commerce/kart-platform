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
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT now()
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
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
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
    occurred_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    published_at TIMESTAMPTZ
);

CREATE INDEX idx_user_outbox_unpublished ON user_outbox_events (id) WHERE published_at IS NULL;
```

### Why the default-address invariant is a database constraint, not just an application check

`ddd-model.md`'s invariant ("at most one default `Address` per type") is enforced by the load-mutate-save-whole-aggregate pattern at the application layer (edge-cases.md's last-write-wins concurrency decision already commits to whole-record replace, so the application already loads every address before writing any one of them) — the partial unique index above is a database-layer backstop against that application logic having a bug, not the primary enforcement mechanism. This mirrors the same "invariant enforced in the aggregate, API/DB-layer checks are a backstop, never the only line of defense" principle `api-standards.md` already states generally.

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
