---
doc_type: database-design
service: kart-inventory-service
status: approved
generated_by: database-design-agent
source: docs/services/kart-inventory-service/requirement-spec.md, docs/services/kart-inventory-service/edge-cases.md, docs/services/kart-inventory-service/design-decisions.md, docs/services/kart-inventory-service/architecture.md, docs/services/kart-inventory-service/ddd-model.md, docs/services/kart-inventory-service/api-contract.yaml, docs/adr/0007-event-catalog-completeness.md, docs/adr/0009-order-inventory-sync-scope.md
---

# Database Design: kart-inventory-service

Write model is **PostgreSQL** (source of truth), matching `ddd-model.md`'s two aggregates (`WarehouseStock`, `Reservation`) exactly. **No MongoDB read model** — this service's own consistency NFR (strong, PostgreSQL write path) rules one out; the read path (`GET /inventory/{sku}`) is served by a short-TTL Redis cache-aside in front of PostgreSQL, per `design-decisions.md`'s "Read-Path Caching Strategy," the same pattern `kart-category-service` uses for the analogous reason (a smaller, non-per-SKU-record read need than Product/Search's 100M-SKU MongoDB split).

## Write Model (PostgreSQL)

```sql
-- =====================================================================
-- WarehouseStock aggregate: the row every reservation/release/replenishment
-- write locks (ddd-model.md). Primary key is the natural (warehouse_id, sku)
-- pair -- this IS the lock target, not a surrogate id pointing at one.
-- =====================================================================
CREATE TABLE warehouse_stock (
    warehouse_id            TEXT NOT NULL,
    sku                     TEXT NOT NULL,
    available_qty           INTEGER NOT NULL CHECK (available_qty >= 0),
                                    -- the oversell invariant itself (ddd-model.md) --
                                    -- this CHECK is defense-in-depth; the actual
                                    -- enforcement is the SELECT ... FOR UPDATE +
                                    -- application-level decrement, never a bare
                                    -- UPDATE that could race past this constraint
    replenishment_threshold INTEGER NOT NULL,
                                    -- per-SKU-per-warehouse reorder point
                                    -- (requirement-spec.md Decision 5; default
                                    -- 20% of target stocking level, overridable)
    target_stocking_level   INTEGER NOT NULL,
                                    -- the 100% baseline replenishment_threshold
                                    -- is computed against
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),

    PRIMARY KEY (warehouse_id, sku)
);

-- "Sum available quantity for a SKU across all warehouses" -- backs
-- GET /inventory/{sku} with no warehouseId filter, and backs the
-- multi-warehouse fallback's candidate-warehouse lookup before it locks
-- rows in ascending warehouse_id order (requirement-spec.md Decision 3).
CREATE INDEX idx_warehouse_stock_sku ON warehouse_stock (sku, warehouse_id);

-- =====================================================================
-- Reservation aggregate: one row per POST /inventory/reserve call.
-- reservation_id is the idempotency key every release trigger (explicit
-- call, OrderCancelled, OrderCompensationTriggered, TTL sweep) converges
-- on (ddd-model.md's ReservationStatus terminal-state machine).
-- =====================================================================
CREATE TABLE reservations (
    reservation_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id         UUID NOT NULL,
    sku              TEXT NOT NULL,
    qty              INTEGER NOT NULL CHECK (qty > 0),
    status           TEXT NOT NULL DEFAULT 'reserved'
                             CHECK (status IN ('reserved', 'released', 'expired')),
                             -- terminal once released/expired -- no transition out
                             -- (design-decisions.md, "Release Idempotency & State
                             -- Machine Design")
    release_reason   TEXT NULL CHECK (release_reason IS NULL OR release_reason IN (
                             'explicit_call', 'order_cancelled', 'compensation_triggered', 'ttl_expiry'
                         )),
                             -- audit trail of which of the four converging triggers
                             -- actually caused the release -- all four still resolve
                             -- to the identical idempotent write path
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at       TIMESTAMPTZ NOT NULL,
                             -- created_at + 15 minutes (requirement-spec.md Decision 2)
                             -- -- the periodic sweep's own query target, see below
    released_at      TIMESTAMPTZ NULL
);

-- Order Cancelled / OrderCompensationTriggered consumers look up "the live
-- reservation(s) for this orderId" -- this is the join key every release
-- trigger except the TTL sweep uses.
CREATE INDEX idx_reservations_order_id ON reservations (order_id) WHERE status = 'reserved';

-- The TTL sweep's own scan (every 60s, requirement-spec.md Decision 2):
-- "find every still-reserved hold whose expiry has passed" -- a small,
-- partial-index scan regardless of total reservations table size, since it
-- only ever matches rows still in the live 'reserved' state.
CREATE INDEX idx_reservations_expiry_sweep ON reservations (expires_at) WHERE status = 'reserved';

-- =====================================================================
-- WarehouseAllocation child entity: one row per warehouse a Reservation
-- drew from. A single-warehouse reservation has exactly one row; the
-- multi-warehouse fallback (requirement-spec.md Decision 3) has two or
-- more, all inserted in the same transaction as the reservation row and
-- the warehouse_stock debits.
-- =====================================================================
CREATE TABLE reservation_allocations (
    reservation_id   UUID NOT NULL REFERENCES reservations (reservation_id),
    warehouse_id     TEXT NOT NULL,
    qty              INTEGER NOT NULL CHECK (qty > 0),

    PRIMARY KEY (reservation_id, warehouse_id)
);

-- Release's own read: "which warehouse_stock rows does this reservation's
-- credit-back need to touch" -- a direct indexed lookup by the PK's leading
-- column, backing the same all-or-nothing release transaction.
CREATE INDEX idx_reservation_allocations_reservation ON reservation_allocations (reservation_id);

-- =====================================================================
-- Transactional Outbox (design-decisions.md, "Event Publish Atomicity").
-- One table for all four of this service's published events:
-- InventoryReserved, InventoryReservationFailed, InventoryReleased,
-- InventoryReplenished.
-- =====================================================================
CREATE TABLE inventory_outbox_events (
    event_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_type     TEXT NOT NULL CHECK (event_type IN (
                       'InventoryReserved', 'InventoryReservationFailed',
                       'InventoryReleased', 'InventoryReplenished'
                   )),
    aggregate_ref  TEXT NOT NULL,      -- reservation_id for the first three; (warehouse_id, sku) for InventoryReplenished
    payload        JSONB NOT NULL,
    occurred_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    published_at   TIMESTAMPTZ NULL    -- set only by the Outbox relay after a successful publish to ecommerce.events
);

-- Standard Outbox poller scan (BRD §11) -- an index range-scan, not a
-- full-table scan, as this table grows with every reserve/release/
-- replenish write (the platform's highest-write-frequency service).
CREATE INDEX idx_inventory_outbox_unpublished ON inventory_outbox_events (occurred_at) WHERE published_at IS NULL;
```

## Read Model / Cache (Redis)

Not a rebuildable CQRS projection — a **short-TTL cache-aside** in front of PostgreSQL (`design-decisions.md`), used only by the informational read paths (`GET /inventory/{sku}` and the internal `InventoryAvailabilityService.CheckAvailability` gRPC RPC, `api-contract.yaml`). The write path (reserve/release/replenish) never reads through this cache — every write takes a fresh `SELECT ... FOR UPDATE` inside its own transaction, so the oversell invariant is never exposed to cached staleness.

- `inventory:stock:{sku}` (or `inventory:stock:{sku}:{warehouseId}` when warehouse-scoped) → `{availableQty}`, short TTL (a few seconds), invalidated by natural expiry only, not synchronously on write (design-decisions.md rejects write-through here as unnecessary complexity on the hottest write path).

## Indexing Rationale

| Index | Query it supports | Why needed |
|---|---|---|
| `warehouse_stock` PK on `(warehouse_id, sku)` | The `SELECT ... FOR UPDATE` lock target for every reservation/release/replenishment write | This pair *is* the lock granularity `design-decisions.md`'s concurrency-control decision names — no surrogate key sits between the lock and the natural identity |
| `idx_warehouse_stock_sku` | Multi-warehouse candidate lookup before the fallback locks rows in ascending `warehouse_id` order; `GET /inventory/{sku}` with no warehouse filter | Backs requirement-spec.md Decision 3's deadlock-avoidance ordering and the platform-wide read path's summed-across-warehouses view |
| `idx_reservations_order_id` (partial, `status = 'reserved'`) | `OrderCancelled`/`OrderCompensationTriggered` consumers' "find the live reservation(s) for this orderId" lookup | Both async release triggers key off `order_id`, not `reservation_id` — this index keeps that a partial-index lookup, not a table scan, and naturally shrinks as reservations terminate |
| `idx_reservations_expiry_sweep` (partial, `status = 'reserved'`) | The 60-second TTL sweep's "find every still-reserved hold past its expiry" scan | requirement-spec.md Decision 2 — keeps the sweep a cheap partial-index range scan regardless of total historical reservation volume |
| `idx_reservation_allocations_reservation` | Release's "which warehouse_stock rows does this reservation touch" lookup | Backs the credit-back transaction on release, symmetric to the debit transaction on reserve |
| `idx_inventory_outbox_unpublished` (partial, `published_at IS NULL`) | The Outbox relay's "find rows not yet published" scan | Standard Outbox mechanics; keeps the relay a cheap partial-index scan on the platform's highest-write-frequency service |

## Partitioning/Sharding

**Not needed for `warehouse_stock`** — its row count is bounded by (number of warehouses) × (number of SKUs), not by transaction volume; the table itself stays small even under the platform's 1M RPS burst ceiling, since burst traffic is repeated writes to the *same* rows, not new rows. **`reservations` and `inventory_outbox_events` are this service's fastest-growing tables** (one row per reservation attempt and one row per published event, at the platform's highest-contention throughput) — range-partitioning both by `created_at`/`occurred_at` (e.g. daily, given expected volume) with old, fully-terminal partitions archived is the natural next step once retention policy is set; the partial indexes above (`status = 'reserved'`, `published_at IS NULL`) already keep the *operative* working set small regardless of total partition count, so partitioning here is a storage/backup-time concern, not a hot-path latency one — flagged as a later capacity-planning detail, not decided here, mirroring `kart-order-service/database-design.md`'s identical treatment of its own `orders`/`order_events` tables.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner
- [x] Approved (write-model schema)
