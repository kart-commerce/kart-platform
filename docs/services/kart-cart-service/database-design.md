---
doc_type: database-design
service: kart-cart-service
status: approved
generated_by: database-design-agent
source: docs/services/kart-cart-service/requirement-spec.md, docs/services/kart-cart-service/edge-cases.md, docs/services/kart-cart-service/design-decisions.md, docs/services/kart-cart-service/architecture.md, docs/services/kart-cart-service/ddd-model.md, docs/adr/0016-user-gdpr-erasure-policy.md
---

# Database Design: kart-cart-service

One aggregate root (`Cart`, `ddd-model.md`) with one child entity (`CartLineItem`) maps to two write-model tables, plus the Transactional Outbox `design-decisions.md`'s "Reliable Event Publication" decision already commits to. Write model is **PostgreSQL** (source of truth, Strong consistency per requirement-spec §3). **No MongoDB read model** — unlike Product/Search's eventual-consistency read side, Cart's own NFR explicitly rejects that pattern ("a user must never see a stale cart," requirement-spec §3); the read path is instead served by a **write-through Redis cache** in front of PostgreSQL (`design-decisions.md`'s "Caching Strategy for Cart State" decision), synchronously updated on every mutation, never an independently-lagging projection.

## Write Model (PostgreSQL)

```sql
-- Cart — the service's one aggregate root (ddd-model.md). CartOwner is mutually exclusive:
-- exactly one of user_id / guest_session_id is set, never both, never neither (invariant 1).
-- A CheckedOut cart is not deleted under ordinary operation (invariant 4) — a new Cart row is
-- created for that owner's next shopping session, so multiple rows can exist per owner over
-- time, but at most one may be 'active' at once (enforced by the partial unique indexes below).
CREATE TABLE carts (
    cart_id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id             UUID NULL,
                                -- opaque reference to Identity/User Service's own UserId
                                -- (ddd-model.md, ACL); the userId a UserDataErased event
                                -- deletes every row for, regardless of status (ADR-0016).
    guest_session_id    TEXT NULL,
                                -- opaque anonymous-session identifier (ddd-model.md Modeling
                                -- Decision #4) — modeled locally, no other context owns it.
    status              TEXT NOT NULL DEFAULT 'active'
                                CHECK (status IN ('active', 'checked_out')),
    version             BIGINT NOT NULL DEFAULT 1,
                                -- CartVersion (ddd-model.md) — optimistic-concurrency counter,
                                -- checked and incremented on every write (design-decisions.md's
                                -- "Concurrency Control for Cart Mutations and Merge"); surfaced
                                -- as an HTTP ETag / If-Match precondition (api-contract.yaml).
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
                                -- bumped on every write (direct mutation, merge, or the
                                -- InventoryReservationFailed availability-flag update); the
                                -- anchor the PostgreSQL soft-expiry purge job (below) scans
                                -- against — Postgres itself does not observe reads (only Redis,
                                -- which owns its own TTL reset on read, does), so a write-only
                                -- touch timestamp is the correct, and only available, anchor here.

    CHECK (
        (user_id IS NOT NULL AND guest_session_id IS NULL)
        OR (user_id IS NULL AND guest_session_id IS NOT NULL)
    )                           -- ddd-model.md invariant 1: exactly one owner shape, never both/neither
);

-- At most one 'active' cart per logged-in user (ddd-model.md invariant 1 read together with
-- Modeling Decision #1's "exactly one live Cart aggregate instance remains for that owner going
-- forward" — a CheckedOut cart is no longer the "live" one). Also the lookup GET /v1/cart runs
-- on a cache miss, and the row a direct mutation or merge writes to.
CREATE UNIQUE INDEX uq_carts_user_active
    ON carts (user_id)
    WHERE status = 'active' AND user_id IS NOT NULL;

-- Same invariant, guest side.
CREATE UNIQUE INDEX uq_carts_guest_active
    ON carts (guest_session_id)
    WHERE status = 'active' AND guest_session_id IS NOT NULL;

-- Backs the UserDataErased handler's "every Cart row for this user, any status" bulk delete
-- (ddd-model.md invariant 6) — deliberately NOT partial/status-scoped like the two indexes
-- above, since erasure must reach a retained CheckedOut row too.
CREATE INDEX idx_carts_user_id
    ON carts (user_id)
    WHERE user_id IS NOT NULL;

-- The PostgreSQL soft-expiry purge job's own scan: "find carts not written to in over
-- (sliding-TTL-window + 30-day grace)" (Decision D1). Partial on status='active' only —
-- a CheckedOut cart is governed by invariant 4's retention, not the expiry mechanism, and is
-- never a purge-job candidate (only a UserDataErased-triggered delete removes one).
CREATE INDEX idx_carts_active_updated_at
    ON carts (updated_at)
    WHERE status = 'active';

-- CartLineItem — child entity within the Cart aggregate (ddd-model.md). Sku is the line's own
-- identity within its parent Cart (Modeling Decision #3); at most one row per (cart_id, sku)
-- (invariant 3), which is what makes Decision D2's "sum quantities on overlapping SKUs" and the
-- 100-distinct-line-item cap (invariant 2, Decision D4) well-defined.
CREATE TABLE cart_line_items (
    line_item_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    cart_id              UUID NOT NULL REFERENCES carts (cart_id) ON DELETE CASCADE,
    sku                  TEXT NOT NULL,
    quantity             INTEGER NOT NULL CHECK (quantity > 0),
    availability         TEXT NOT NULL DEFAULT 'available'
                                CHECK (availability IN ('available', 'flagged_unavailable')),
                                -- LineItemAvailability (ddd-model.md) — set by consuming
                                -- InventoryReservationFailed pre-checkout only (Decision D3),
                                -- cleared on the line's next successful validation.

    CONSTRAINT uq_cart_line_items_cart_sku UNIQUE (cart_id, sku)
);

-- "All line items for cart X" — the primary read a cache-miss GET /v1/cart falls back to, and
-- what a direct mutation or merge writes against.
CREATE INDEX idx_cart_line_items_cart
    ON cart_line_items (cart_id);

-- Backs the checkout-time lazy validation call (architecture.md's gRPC edge) and the
-- InventoryReservationFailed handler: "which cart line items hold this sku" is resolved via
-- idx_cart_line_items_cart plus an application-level filter once the owning cart_id is known
-- from InventoryReservationFailed's own orderId->cart lookup — no separate sku index is needed
-- here since Cart never fans an inbound event out across carts by sku alone (unlike Wishlist's
-- ProductPriceChanged, which is genuinely cross-user; InventoryReservationFailed already carries
-- enough context — Order's own orderId — to resolve to one specific cart directly).

-- Transactional Outbox for CartCheckedOut (design-decisions.md, "Reliable Event Publication and
-- Idempotent Event Consumption"). One row per checkout, written in the same transaction as the
-- carts.status = 'checked_out' write.
CREATE TABLE cart_outbox_events (
    outbox_id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    cart_id              UUID NOT NULL REFERENCES carts (cart_id),
    event_type           TEXT NOT NULL DEFAULT 'CartCheckedOut',
    payload              JSONB NOT NULL,
                                -- {cartId, userId, items} per event-contract.md.
    occurred_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    published_at         TIMESTAMPTZ NULL
);

-- The Outbox relay's own scan: "find everything not yet published, oldest first" — same
-- pattern as every other service's Outbox table on this platform.
CREATE INDEX idx_cart_outbox_unpublished
    ON cart_outbox_events (occurred_at)
    WHERE published_at IS NULL;
```

### GDPR Erasure — `UserDataErased` Write Path (ADR-0016)

Per `design-decisions.md`'s "Erasure Mechanism for `UserDataErased`" decision and `ddd-model.md`'s invariant 6: on consuming `UserDataErased` for a `user_id`, one handler transaction runs `DELETE FROM carts WHERE user_id = ?` (cascading to `cart_line_items` via `ON DELETE CASCADE`, and to any not-yet-published `cart_outbox_events` row for that cart) — hard delete, no tombstone column, since neither an `Active` nor a `CheckedOut` cart is BRD-required retained history (ADR-0016 item 3). `idx_carts_user_id` backs this with an index scan across every status, not just `active`. The handler also evicts the corresponding Redis cache entry (below) in the same logical operation. A redelivered `UserDataErased` for an already-erased `user_id` deletes zero rows — a no-op, not an error, satisfying the idempotent-consumer invariant already required of `InventoryReservationFailed` handling.

## Cache (Redis) — Write-Through, Not a CQRS Read Model

Per `design-decisions.md`'s "Caching Strategy for Cart State" decision, confirming requirement-spec Decision D5:

- `cart:{ownerKey}` (where `ownerKey` is `user:{userId}` or `guest:{guestSessionId}`) → the full serialized cart (line items, version, status) for O(1) reads on the `GET /v1/cart` / cache-miss-fallback path.
- **Write-through, not write-behind or cache-aside:** every mutation (direct `/cart` write, merge, or the `InventoryReservationFailed` availability-flag update) writes PostgreSQL first (or in the same synchronous path) before the write is acknowledged, then updates this Redis key — never the reverse order. This is what makes requirement-spec NFR §3's "Strong" consistency target correct: a client never observes a Redis value that hasn't already been durably committed to PostgreSQL.
- **Sliding TTL** on this key: 30 days idle for `user:*` keys, 7 days idle for `guest:*` keys (Decision D1), reset on every read *or* write — the one place "read resets the clock" is actually implemented, since PostgreSQL's own `updated_at` column (above) only ever reflects writes.
- On Redis eviction (TTL expiry or memory-pressure eviction), a read is a cache miss repopulated from PostgreSQL — never a lost mutation, since PostgreSQL was already the authoritative write target. The PostgreSQL row itself is only physically purged later, by the scheduled soft-expiry job described below.
- On `UserDataErased`, this key is deleted synchronously in the same handler as the PostgreSQL delete above (`design-decisions.md`'s erasure decision; `edge-cases.md`'s "Residual Cart State" decision) — never left to expire on its own TTL, since ADR-0016 item 7 treats a delayed erasure as a compliance failure, not a tolerable staleness window.

## Soft-Expiry Purge Job

A scheduled job (cadence: daily is sufficient — this is a storage-reclamation concern, not a user-facing latency path, per `ddd-model.md` Modeling Decision #2) deletes any `active`-status `carts` row whose `updated_at` is older than its owner type's sliding window plus the 30-day PostgreSQL soft-expiry grace window (Decision D1): `now() - updated_at > INTERVAL '60 days'` for `user_id`-owned rows (30-day TTL + 30-day grace), `now() - updated_at > INTERVAL '37 days'` for `guest_session_id`-owned rows (7-day TTL + 30-day grace — the grace window physically exists in the schema for both owner types identically; `edge-cases.md`'s point that "a guest has no recovery path" is about the front-end session having no way to reattach to that snapshot on return, not a different retention mechanism in this table). `idx_carts_active_updated_at` backs this scan with an index-only lookup rather than a full-table scan. This job never touches a `checked_out`-status row — those are governed by invariant 4's retention (or, going forward, by an explicit `UserDataErased` delete), never by idle-timeout.

## Indexing Rationale

| Index | Query it supports | Why needed |
|---|---|---|
| `carts` PK on `cart_id` | Direct row lookup; FK target for `cart_line_items`/`cart_outbox_events` | Standard PK access path |
| `uq_carts_user_active` (partial unique) | Enforces "at most one active cart per user_id" at write time; the `GET /v1/cart` cache-miss lookup for a logged-in user | `ddd-model.md` invariant 1 must be a database-enforced constraint, not just an application check, per `api-standards.md`'s "domain invariants are also enforced inside the aggregate" rule |
| `uq_carts_guest_active` (partial unique) | Same invariant, guest side | Same reasoning, scoped to `guest_session_id` |
| `idx_carts_user_id` | `UserDataErased` bulk delete across every status | Must reach a retained `checked_out` row too — the two partial indexes above deliberately don't, so a separate unbounded index is needed |
| `idx_carts_active_updated_at` (partial, `status = 'active'`) | Soft-expiry purge job's "not touched in N days" scan | Backs Decision D1's reclamation mechanism with an index scan rather than a full-table scan as the table grows |
| `uq_cart_line_items_cart_sku` (unique) | Enforces "at most one line item per `(cart, sku)`" at write time | The actual mechanism `ddd-model.md` invariant 3 and Decision D2's merge-by-sum-on-overlap logic depend on |
| `idx_cart_line_items_cart` | "All line items for cart X" — every read/write path's own lookup | The one query every cart mutation and cache-miss read runs |
| `idx_cart_outbox_unpublished` (partial, `published_at IS NULL`) | Outbox relay's "find rows not yet published" scan | Standard Outbox mechanics, same pattern as every other service's Outbox table on this platform |

## Partitioning/Sharding

Not needed at current scale. `carts`' row count is bounded by (active + recently-checked-out) accounts, each capped at 100 line items (`ddd-model.md` invariant 2) — orders of magnitude below Product's/Search's 100M-SKU cardinality (BRD §4.1), and the soft-expiry purge job actively bounds unbounded growth from idle carts. A single PostgreSQL table with the indexes above, plus read replicas if the checkout-time gRPC validation call or the purge job ever contends with live traffic, is sufficient; `user_id`/`guest_session_id` remain candidate future shard keys if that changes, but nothing in this service's own read/write volume calls for it today.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner
- [x] Approved (write-model schema)
