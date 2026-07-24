---
doc_type: database-design
service: kart-wishlist-service
status: approved
generated_by: database-design-agent
source: docs/services/kart-wishlist-service/requirement-spec.md, docs/services/kart-wishlist-service/edge-cases.md, docs/services/kart-wishlist-service/design-decisions.md, docs/services/kart-wishlist-service/architecture.md, docs/services/kart-wishlist-service/ddd-model.md, docs/adr/0016-user-gdpr-erasure-policy.md
---

# Database Design: kart-wishlist-service

One aggregate root (`WishlistEntry`, `ddd-model.md`) maps to one write-model table, plus the technical Outbox/dedup tables `ddd-model.md` deliberately excluded from the domain model itself. Write model is **PostgreSQL** (source of truth); read model is **MongoDB**, following the platform's default CQRS split — `architecture.md`'s resolution of requirement-spec §6 item 4's write-side-datastore ambiguity (PostgreSQL write side + MongoDB read side, not a deliberate Mongo-only exception). A third store, **Redis**, holds the ephemeral per-user alert-batching accumulator (`design-decisions.md`) — not a CQRS read model, and not rebuilt from the event log the way MongoDB is; it is purely a publish-cadence buffer.

## Write Model (PostgreSQL)

```sql
-- WishlistEntry — the service's one aggregate root (ddd-model.md). One row per
-- (user_id, sku) pair a user has saved.
CREATE TABLE wishlist_entries (
    entry_id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id             UUID NOT NULL,
                                -- opaque reference to Identity/User Service's own UserId
                                -- (ddd-model.md, ACL — never validated or joined against
                                -- another service's table); the userId a UserDataErased
                                -- event deletes every row for (ADR-0016).
    sku                 TEXT NOT NULL,
                                -- opaque reference to kart-product-service's Variant.sku
                                -- (ddd-model.md, ACL); never a foreign key across services.
    reference_price     NUMERIC(12, 2) NOT NULL,
                                -- ddd-model.md ReferencePrice value object: the baseline the
                                -- 5%-drop evaluation runs against; set at add-time (edge-cases.md
                                -- "Wishlist Entry Added After the Price Drop Already Happened" —
                                -- no retroactive backfill), reset to the alerted price on every
                                -- qualifying WishlistPriceAlertTriggered.
    status              TEXT NOT NULL DEFAULT 'active'
                                CHECK (status IN ('active', 'stale')),
                                -- ddd-model.md WishlistEntryStatus. Set to 'stale' by the
                                -- ProductDiscontinued consumer or the hourly reconciliation job
                                -- (requirement-spec §2, §4) — never itself deletes the row.
    last_alerted_at     TIMESTAMPTZ NULL,
                                -- ddd-model.md AlertCooldownState: backs the 24-hour-per-pair
                                -- cooldown (requirement-spec §4, §6 item 3). NULL = never alerted.
    added_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
                                -- this table's created_at under BRD §24.3, in the domain's own
                                -- "added" vocabulary -- not duplicated as a second created_at column.
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
                                -- BRD §24.3; bumped on every reference_price reset, status
                                -- transition, or last_alerted_at write.
    created_by          TEXT NOT NULL,
                                -- BRD §24.3 -- the owning userId; every insert is a client-facing
                                -- add-to-wishlist write, so this table has no system-only insert path.
    updated_by          TEXT NOT NULL
                                -- BRD §24.3 -- the owning userId for a client-facing write (none
                                -- exists today beyond add/remove, but carried for uniformity), or a
                                -- well-known system:* principal for the ProductDiscontinued-consumer
                                -- / reconciliation-job stale transition and the alert-triggered
                                -- reference_price/last_alerted_at reset (see ddd-model.md's
                                -- audit-actor invariant for the exact system:* ids).

    CONSTRAINT uq_wishlist_entries_user_sku UNIQUE (user_id, sku)
                                -- ddd-model.md invariant: a (userId, sku) pair maps to at most
                                -- one WishlistEntry.
);

-- "List (active) entries for user X" — the GET /wishlist read-model projection source, the
-- count-then-insert check backing the 500-active-entry cap (ddd-model.md), and the row set a
-- UserDataErased handler deletes wholesale.
CREATE INDEX idx_wishlist_entries_user_status
    ON wishlist_entries (user_id, status);

-- "Which entries hold this sku" — the ProductPriceChanged and ProductDiscontinued consumer
-- handlers' own lookup (requirement-spec §2, §4), fan-out from one event to every affected
-- (userId, sku) row.
CREATE INDEX idx_wishlist_entries_sku
    ON wishlist_entries (sku)
    WHERE status = 'active';

-- "Distinct active skus across every user's wishlist" — what the hourly reconciliation job
-- (edge-cases.md "Stale Wishlist Entry" decision; design-decisions.md's bulkhead-worker-pool
-- decision) scans to build its GET /products/{id} call list, without re-scanning per-user.
CREATE INDEX idx_wishlist_entries_status_sku
    ON wishlist_entries (status, sku);

-- Redelivery-idempotency dedup record (design-decisions.md "Idempotent Alert Publication —
-- Dedup Table + Transactional Outbox"; edge-cases.md "Duplicate Alert Delivery from
-- At-Least-Once Redelivery"). One row per price point an alert has actually fired on for a
-- given (userId, sku) — deliberately not a single "last alerted price" column on
-- wishlist_entries itself, because it must survive the same price being re-announced under a
-- different message id (republish/backfill), not just a literal redelivery of the same message.
CREATE TABLE wishlist_alert_dedup (
    dedup_id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id             UUID NOT NULL,
    sku                 TEXT NOT NULL,
    price_observed      NUMERIC(12, 2) NOT NULL,
    alerted_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
                                -- this table's created_at under BRD §24.3, in the domain's own
                                -- "alerted" vocabulary.
    created_by          TEXT NOT NULL DEFAULT 'system:wishlist-price-evaluator',
                                -- BRD §24.3 -- this row is always written by the ProductPriceChanged
                                -- qualify-time evaluation process, never a client-facing request;
                                -- there is no human/API caller to attribute the insert to.
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
                                -- BRD §24.3 uniformity -- no update path exists in v1 (a dedup row
                                -- is inserted once, never edited), carried for platform-wide
                                -- consistency and to cover a future correction path without a schema
                                -- change.
    updated_by          TEXT NOT NULL DEFAULT 'system:wishlist-price-evaluator',
                                -- mirrors created_by until an update path exists

    CONSTRAINT uq_wishlist_alert_dedup UNIQUE (user_id, sku, price_observed)
                                -- the actual idempotency guard: inserting the same
                                -- (user_id, sku, price_observed) twice violates this constraint,
                                -- which the publish path treats as "already alerted, skip" rather
                                -- than an error.
);

-- Backs a UserDataErased handler's "every dedup row for this user" delete, and a duplicate-check
-- lookup keyed on the pair the price-evaluation handler already has in hand.
CREATE INDEX idx_wishlist_alert_dedup_user_sku
    ON wishlist_alert_dedup (user_id, sku);

-- Transactional Outbox for WishlistPriceAlertTriggered (design-decisions.md). One row is written
-- per digest flush per user (design-decisions.md's Redis-backed batching decision) — not one row
-- per individual qualifying trigger, since the batching window is what determines how many
-- distinct triggers a single flush's payload actually reports.
CREATE TABLE wishlist_outbox_events (
    outbox_id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id             UUID NOT NULL,
    sku                 TEXT NOT NULL,
    event_type          TEXT NOT NULL DEFAULT 'WishlistPriceAlertTriggered',
    payload             JSONB NOT NULL,
                                -- {userId, sku, oldPrice, newPrice} per event-contract.md;
                                -- newPrice is the digest-send-time re-checked value
                                -- (edge-cases.md "Price Rebound During the Batching/Digest
                                -- Window"), not necessarily the value captured at qualify-time.
    occurred_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
                                -- this table's created_at under BRD §24.3, in the domain's own
                                -- event vocabulary.
    published_at        TIMESTAMPTZ NULL,
    created_by          TEXT NOT NULL DEFAULT 'system:wishlist-digest-flush',
                                -- BRD §24.3 -- the digest-flush sweep is the only process that ever
                                -- writes a row here (design-decisions.md's batching decision); there
                                -- is no client-facing insert path.
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
                                -- BRD §24.3; bumped when published_at is set.
    updated_by          TEXT NOT NULL DEFAULT 'system:wishlist-outbox-poller'
                                -- BRD §24.3 -- the Outbox poller is the only process that ever
                                -- updates a row after insert.
);

-- The Outbox relay's own scan: "find everything not yet published, oldest first" — same
-- pattern as every other service's Outbox table on this platform (e.g.
-- kart-category-service's idx_category_outbox_unpublished).
CREATE INDEX idx_wishlist_outbox_unpublished
    ON wishlist_outbox_events (occurred_at)
    WHERE published_at IS NULL;
```

### GDPR Erasure — `UserDataErased` Write Path (ADR-0016)

Per `design-decisions.md`'s "Erasure Mechanism for `UserDataErased`" decision and `ddd-model.md`'s matching invariant: on consuming `UserDataErased` for a `user_id`, one handler transaction runs three deletes — `DELETE FROM wishlist_entries WHERE user_id = ?`, `DELETE FROM wishlist_alert_dedup WHERE user_id = ?`, and the Redis accumulator purge (below) — all hard deletes, no tombstone column, since none of this data is BRD-required retained history (ADR-0016 item 3). `idx_wishlist_entries_user_status` and `idx_wishlist_alert_dedup_user_sku` back both deletes with an index scan rather than a table scan. A redelivered `UserDataErased` for an already-erased `user_id` deletes zero rows in both tables — a no-op, not an error, satisfying the idempotent-consumer invariant.

## Row-Level Security Policy (BRD §24.1.4)

Per BRD §24.1.4, the service whose database physically holds a row decides and enforces that row's row-level security. Wishlist's write model is PostgreSQL (see above), and `wishlist_entries`/`wishlist_alert_dedup` both have a genuine per-row `user_id` ownership concept, so native RLS is the mechanism for each.

**Session-scoped principal setting.** Same ambient mechanism already established platform-wide (see `kart-identity-service/database-design.md`'s precedent, generic plumbing owned by the shared `kart-shared` `ICurrentPrincipalAccessor`, not reimplemented here): immediately after acquiring a pooled connection and before any query runs, this service issues `SET LOCAL app.current_principal = <id>` and `SET LOCAL app.current_principal_kind = <'user'|'service'|'system'>`, resolved server-side from the validated JWT context or the internal consumer/job context — never a client-suppliable value. `app.current_principal` is the caller's own `user_id` for client-facing `/wishlist` add/remove requests, or a well-known `system:*` id for the `ProductPriceChanged`/`ProductDiscontinued` consumers, the reconciliation job, the digest-flush process, and the `UserDataErased` consumer. This is the same resolved-principal value the shared `kart-shared` `created_by`/`updated_by` interceptor (§24.3, above) stamps onto every mutation — RLS and audit-column injection read one ambient current-principal accessor from that same package, not two independently-maintained notions of "who is acting."

**Policy shape.** Both tables' policies grant access when the row's `user_id` matches `app.current_principal`, **or** when `app.current_principal_kind` is `service`/`system`. The latter branch is not a blanket bypass: per requirement-spec.md's §24.1.2 cross-reference, every system-initiated write here (stale-marking, dedup-insert, erasure-delete) has no client-facing entry point at all — these are internal consumer/job processes no external caller can reach — so RLS's marginal, additive protection is specifically against the failure mode §24.1.4 itself names (a user-facing code path that forgets its own `WHERE user_id = ...` clause), which stays fully blocked whenever `app.current_principal_kind = 'user'`.

```sql
-- wishlist_entries
ALTER TABLE wishlist_entries ENABLE ROW LEVEL SECURITY;
CREATE POLICY wishlist_entries_owner_or_system ON wishlist_entries
    USING (
        user_id = current_setting('app.current_principal')::uuid
        OR current_setting('app.current_principal_kind', true) IN ('service', 'system')
    );

-- wishlist_alert_dedup
ALTER TABLE wishlist_alert_dedup ENABLE ROW LEVEL SECURITY;
CREATE POLICY wishlist_alert_dedup_owner_or_system ON wishlist_alert_dedup
    USING (
        user_id = current_setting('app.current_principal')::uuid
        OR current_setting('app.current_principal_kind', true) IN ('service', 'system')
    );
```

**Not covered by this policy (no per-row end-user ownership concept reachable by a request path):**

- `wishlist_outbox_events` — despite carrying a `user_id` column for payload provenance, this table is an internal Outbox relay written exclusively by the digest-flush process and read exclusively by the Outbox poller (both `system:*`-attributed, above); no end-user- or admin-facing request path ever queries it directly, the same carve-out `kart-identity-service/database-design.md` draws for its own `outbox_events` table. Adding a redundant RLS policy on a table reached by exactly one, fully-trusted internal code path would be defense-in-depth against a code path that doesn't exist.

## Read Model (MongoDB)

`wishlist_read` collection, one document per `user_id`, projected from `wishlist_entries` via the same Outbox → RabbitMQ → consumer pipeline every other service on this platform uses (BRD §7) — fully rebuildable from the PostgreSQL write side, never written to directly outside the projection consumer (`ddd-cqrs-standards.md`).

```json
{
  "_id": "<userId>",
  "entries": [
    { "sku": "...", "referencePrice": 129.99, "status": "active", "addedAt": "2026-01-01T00:00:00Z" }
  ],
  "updatedAt": "2026-01-01T00:00:00Z"
}
```

- Backs `GET /wishlist` (`api-contract.yaml`) directly — a single document read by `user_id`, meeting the P95 < 150ms / P99 < 400ms read-path NFR (requirement-spec §3) without a join.
- Every write to `wishlist_entries` (add, remove, stale-marking, alert-triggered reference-price reset) re-projects that user's document in full — the same "denormalize the whole owned collection per owner" shape `kart-cart-service`'s own Cart read model uses, appropriate here since a user's wishlist is bounded (max 500 entries, `ddd-model.md`) and never approaches Product's/Search's 100M-SKU cardinality.
- A `UserDataErased` erasure deletes the user's `wishlist_read` document outright in the same logical operation as the PostgreSQL deletes above — an erased user has no wishlist to read, not an empty one lingering as a stale projection.

## Ephemeral State (Redis) — Per-User Alert Batching/Digest Accumulator

Not a CQRS read model — a publish-cadence buffer, per `design-decisions.md`'s "State-Store Mechanism for the Per-User Alert Batching/Digest Window" decision.

- `wishlist:digest:{userId}` → a list/hash of pending `{sku, oldPrice, newPrice}` entries accumulated since the window opened, TTL set to the 60-minute hard cap.
- A scheduled sweep flushes any key past its 15-minute rolling-quiet mark (or the 60-minute hard cap, whichever comes first) — writing one row into `wishlist_outbox_events` per user per flush, re-checking each entry's current price immediately before doing so (edge-cases.md's rebound decision) and dropping any item that has rebounded to/above its original baseline.
- On `UserDataErased`, this key is deleted synchronously in the same handler as the PostgreSQL deletes above (`design-decisions.md`'s erasure decision; `edge-cases.md`'s "Residual Wishlist State" decision) — never left to expire on its own TTL, since ADR-0016 item 7 treats a delayed erasure as a compliance failure, not a tolerable staleness window.
- Redis availability is a **latency/timeliness**, not a correctness, dependency for the alert feature: if Redis is down, the qualify-time check simply cannot accumulate a pending trigger for that window, at worst delaying (not corrupting or duplicating) an alert — `wishlist_entries`/`wishlist_alert_dedup` in PostgreSQL remain the durable source of truth for whether a `(userId, sku)` pair has already qualified and/or already alerted.

## Sensitive / PII Column Classification (BRD §24.1.5)

Column-level security answers a narrower question than row-level security: of the columns in a row a caller already has `CanRead` on (BRD §24.1.2), which does that caller's own coarse role actually see — full value, masked, or nothing. Wishlist has no sensitive/PII column of its own to classify:

- `wishlist_entries.sku`, `.reference_price`, `.status`, `.last_alerted_at`, `wishlist_alert_dedup.price_observed` — plain catalog/pricing/state facts, not PII, and already scoped to the row's owner by the RLS policy above (no other principal reaches the row at all, so there is no *further* column-masking question within it).
- `user_id` (both tables) — an opaque foreign-key reference into Identity/User Service's own identity (`ddd-model.md`'s Anti-Corruption Layer note), never resolved to a name, email, or phone within this service. Wishlist never returns another user's `user_id` in any response — the RLS policy above already ensures the only caller who can reach a row at all is its own owner — so there is no masking rule to define, the same "no unmasked sensitive data exists to protect in the first place" reasoning BRD §24.1.5's own Payment Service example uses for PCI columns.

**Why none:** unlike User Service (`addresses.line1`/`line2`/`phone`) or Identity (credential/token material), nothing in Wishlist's own domain data is directly identifying or credential-shaped — the service exists to track `(userId, sku)` pairs and price thresholds, not personal contact or account-security data. No `GRANT SELECT (col1, ...)` database-role restriction is needed for the same reason.

**Enforcement point:** not applicable at the primary API response-serialization layer (BRD §24.1.5) since there is no sensitive column to mask or omit; the secondary database-column-privilege control is likewise not needed, consistent with the reasoning above.

## Indexing Rationale

| Index | Query it supports | Why needed |
|---|---|---|
| `wishlist_entries` PK on `entry_id` | Direct row lookup; FK target for future references | Standard PK access path |
| `uq_wishlist_entries_user_sku` (unique) | Enforces the one-entry-per-`(userId, sku)` invariant at write time | `ddd-model.md`'s core uniqueness invariant — must be a database-enforced constraint, not just an application check, per `api-standards.md`'s "domain invariants are also enforced inside the aggregate" rule |
| `idx_wishlist_entries_user_status` | `GET /wishlist` projection source; 500-active-entry cap count-check at add-time; `UserDataErased` bulk delete | The read-path latency NFR and the max-size invariant both need this as an index lookup, not a per-request table scan |
| `idx_wishlist_entries_sku` (partial, `status = 'active'`) | `ProductPriceChanged`/`ProductDiscontinued` consumer fan-out: "which active entries hold this sku" | Both consumer handlers key off `sku`, not `user_id` — without this index each event would force a full-table scan across every user's entries |
| `idx_wishlist_entries_status_sku` | Reconciliation job's "distinct active skus across the whole table" scan | Backs the bulkhead-worker-pool reconciliation decision (design-decisions.md) with an index-only scan rather than a full-table scan as the wishlist table grows |
| `uq_wishlist_alert_dedup` (unique) | Enforces the redelivery-idempotency guard at insert time | The actual mechanism `design-decisions.md`'s Outbox+dedup decision depends on — a constraint violation on insert *is* the "already alerted, skip" signal |
| `idx_wishlist_alert_dedup_user_sku` | `UserDataErased` bulk delete; per-pair dedup lookup before insert | Same reasoning as `idx_wishlist_entries_user_status`, scoped to the dedup table |
| `idx_wishlist_outbox_unpublished` (partial, `published_at IS NULL`) | Outbox relay's "find rows not yet published" scan | Standard Outbox mechanics, same pattern as every other service's Outbox table on this platform |

## Partitioning/Sharding

Not needed. Even at platform scale (BRD §4.1's cardinality figures are stated for Product's 100M-SKU catalog, not per-user saved-item counts), `wishlist_entries`' row count is bounded by `(active user count) × (≤500 entries per user, ddd-model.md's cap)` — orders of magnitude below Product's/Search's own sharding trigger. A single PostgreSQL table with the indexes above, plus a read replica if the reconciliation job's scans ever contend with live traffic, is sufficient at current scale; `user_id` remains a candidate future shard key if that changes, but nothing in this service's own read/write volume calls for it today.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner
- [x] Approved (write-model schema)
