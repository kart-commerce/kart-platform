---
doc_type: database-design
service: kart-order-service
status: approved
generated_by: database-design-agent
source: docs/services/kart-order-service/ddd-model.md, docs/services/kart-order-service/architecture.md, docs/services/kart-order-service/design-decisions.md
---

# Database Design: kart-order-service

Write model is PostgreSQL (source of truth), matching BRD §6.1's `orders` table example and requirement-spec §2's Persistence & Messaging section. Read model is MongoDB (`GET /orders/{id}` serves from here, never PostgreSQL directly — BRD §7 CQRS). Order is on the write-heavy/PostgreSQL-source-of-truth side of BRD §6.1's Read-Heavy vs. Write-Heavy table.

## Write Model (PostgreSQL)

```sql
-- Order aggregate root
CREATE TABLE orders (
    order_id          UUID PRIMARY KEY,
    user_id           UUID NOT NULL,
    status            VARCHAR(24) NOT NULL,   -- OrderStatus (ddd-model.md): Created|Reserved|Paid|Shipped|Delivered|FulfillmentException|Cancelled|Refunded
    total_amount      NUMERIC(12,2) NOT NULL,
    currency          TEXT NOT NULL,
    idempotency_key   TEXT NOT NULL,          -- ddd-model.md's IdempotencyKey value object
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by        TEXT NOT NULL,          -- BRD §24.3 — the owning user_id for a client-created order
    updated_by        TEXT NOT NULL           -- BRD §24.3 — the owning user_id for a client-initiated cancel, Admin Service's client-credentials principal for resolve-fulfillment-exception, or a well-known system:* Saga-step-consumer id (ddd-model.md's audit-actor invariant) for every other transition
) PARTITION BY RANGE (created_at);

CREATE TABLE orders_2026_07 PARTITION OF orders
    FOR VALUES FROM ('2026-07-01') TO ('2026-08-01');

CREATE UNIQUE INDEX idx_orders_idempotency_key ON orders (idempotency_key);
CREATE INDEX idx_orders_user_id ON orders (user_id);
CREATE INDEX idx_orders_status_created ON orders (status, created_at DESC);

-- OrderLineItem child entity (not independently partitioned — requirement-spec §2 only names orders/order_events as partitioned)
CREATE TABLE order_items (
    id             UUID PRIMARY KEY,
    order_id       UUID NOT NULL REFERENCES orders(order_id),
    sku            TEXT NOT NULL,
    qty            INT NOT NULL CHECK (qty > 0),
    unit_price     NUMERIC(12,2) NOT NULL,
    currency       TEXT NOT NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),   -- BRD §24.3
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),   -- BRD §24.3; line items are never independently mutated post-creation (no partial fulfillment, requirement-spec Open Questions resolution #4), so this never advances past insert in v1 — carried for platform-wide uniformity and to cover a future split-shipment schema change without a migration
    created_by     TEXT NOT NULL,                        -- BRD §24.3 — the owning order's user_id, stamped once at POST /orders creation (order_items has no independent write path of its own)
    updated_by     TEXT NOT NULL                          -- BRD §24.3 — same value as created_by in v1, for the reason above
);

CREATE INDEX idx_order_items_order_id ON order_items (order_id);

-- OrderEvent child entity — doubles as the Outbox table (requirement-spec Open Questions
-- resolution #5: no separate, unlisted outbox table). Records EVERY state transition (audit
-- trail), but only some transitions also carry a published business event (event_type NOT NULL).
CREATE TABLE order_events (
    id             UUID PRIMARY KEY,
    order_id       UUID NOT NULL REFERENCES orders(order_id),
    sequence       INT NOT NULL,              -- OrderEventSequence: monotonic per order_id (edge-cases.md, reordering guard)
    from_status    VARCHAR(24) NOT NULL,
    to_status      VARCHAR(24) NOT NULL,
    event_type     VARCHAR(64) NULL,          -- OrderCreated|OrderConfirmed|OrderCancelled|OrderCompensationTriggered|OrderDelivered; NULL for internal-only transitions with no published counterpart (Created→Reserved, Paid→Shipped, FulfillmentException retry-to-Paid)
    payload        JSONB NULL,                -- outbox payload; present only when event_type IS NOT NULL
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    published_at   TIMESTAMPTZ NULL,
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),   -- BRD §24.3; bumped when published_at is set — this row's only post-insert write
    created_by     TEXT NOT NULL,             -- BRD §24.3 — the same acting principal that drove the orders.status transition this row records (ddd-model.md's audit-actor invariant: owning userId, Admin's client-credentials principal, or a system:* Saga-step-consumer id)
    updated_by     TEXT NOT NULL DEFAULT 'system:order-outbox-poller' -- BRD §24.3 — the Outbox poller is the only process that ever updates a row after insert
) PARTITION BY RANGE (created_at);

CREATE TABLE order_events_2026_07 PARTITION OF order_events
    FOR VALUES FROM ('2026-07-01') TO ('2026-08-01');

CREATE UNIQUE INDEX idx_order_events_order_seq ON order_events (order_id, sequence);
CREATE INDEX idx_outbox_unpublished ON order_events (created_at)
    WHERE event_type IS NOT NULL AND published_at IS NULL;   -- BRD §11's named index, scoped to rows that actually need publishing
```

## State-Transition Write Mechanics (implements ddd-model.md's Legal Transitions + Compare-and-Swap invariants)

Every Saga-step handler and the cancel/resolve-fulfillment-exception endpoints all write through the identical pattern — the compare-and-swap `design-decisions.md`'s "Concurrency Control for Order State Transitions" decision requires, combined in one transaction with the corresponding `order_events` insert (the Atomic state-transition/event emission invariant):

```sql
BEGIN;
UPDATE orders
SET status = $to_status, updated_at = now(), updated_by = $acting_principal
WHERE order_id = $1 AND status = $expected_from_status;
-- 0 rows affected → 409/retry at the caller (a concurrent writer already moved this order,
-- or a duplicate/out-of-order event arrived after the expected pre-state had already changed —
-- ddd-model.md's Idempotent event consumption invariant covers this as a no-op, not an error).
-- $acting_principal (BRD §24.3) is resolved by the shared kart-shared current-principal
-- accessor, never a value the caller/consumer's own payload supplies directly — see
-- ddd-model.md's audit-actor invariant for the full per-trigger id mapping.

INSERT INTO order_events (id, order_id, sequence, from_status, to_status, event_type, payload, created_at, created_by, updated_by)
VALUES ($2, $1, (SELECT COALESCE(MAX(sequence), 0) + 1 FROM order_events WHERE order_id = $1),
        $expected_from_status, $to_status, $event_type_or_null, $payload_or_null, now(), $acting_principal, $acting_principal);
COMMIT;
```

`POST /orders`'s initial insert is the one exception — it inserts a new `orders` row directly (no prior status to compare against) plus its `order_items` rows and the first `order_events` row (`from_status = NULL`, `to_status = 'Created'`, `event_type = 'OrderCreated'`) all in one transaction, guarded by `idx_orders_idempotency_key`'s unique constraint instead of a compare-and-swap.

## Read Model (MongoDB)

```json
{
  "_id": "order-...",
  "userId": "...",
  "status": "Paid",
  "items": [{ "sku": "...", "qty": 2, "unitPrice": { "amount": 24.99, "currency": "USD" } }],
  "totalAmount": { "amount": 49.98, "currency": "USD" },
  "createdAt": "2026-07-20T10:00:00Z",
  "updatedAt": "2026-07-20T10:00:05Z"
}
```

Projected by a consumer reading `order_events`'s published rows (every `event_type IS NOT NULL` row, not just the five business events — the projector also needs the internal `to_status` transitions to keep `status` current for reads even though some transitions have no externally-published event; it reads directly off the Outbox stream via its own internal subscription, not the public RabbitMQ exchange, for exactly this reason) and upserting into a single `order_read_model` collection, keyed by `order_id`. Rebuildable from the write side at any time — the core CQRS safety property (BRD §7). No sharding is needed at this collection's scale relative to Product/Search's hundred-million-SKU catalog (BRD §4.3); a single replica set is sufficient, revisited only if Order's own read volume (20:1 per BRD §4.4) demands it under real load.

## Row-Level Security Policy (BRD §24.1.4)

Per BRD §24.1.4, the service whose database physically holds a row decides and enforces that row's row-level security — never a shared, central component. Order's write model is entirely PostgreSQL (`orders`, `order_items`, `order_events`), and `orders` (with `order_items`/`order_events` transitively via `order_id`) has a genuine per-row end-user ownership concept, so native RLS is the mechanism for all three.

**Session-scoped principal setting.** Same ambient mechanism already established platform-wide (see `kart-identity-service/database-design.md`'s precedent): immediately after acquiring a pooled connection and before any query runs, this service issues `SET LOCAL app.current_principal = <id>` and `SET LOCAL app.current_principal_kind = <'user'|'service'|'system'>`, resolved server-side from the validated JWT (customer requests), Admin Service's client-credentials context (`resolve-fulfillment-exception`), or the internal Saga-step-consumer/reconciliation-sweep context (`system`) — never a client-suppliable value. This is the same resolved-principal value the shared `kart-shared` `created_by`/`updated_by` interceptor (§24.3, above) stamps onto every mutation — RLS and audit-column injection read one ambient current-principal accessor from that same package, not two independently-maintained notions of "who is acting."

**Policy shape.**

```sql
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;

CREATE POLICY orders_owner_isolation ON orders
    USING (
        current_setting('app.current_principal_kind') IN ('service', 'system')
        OR user_id = current_setting('app.current_principal')::uuid
    );

-- RLS on a partitioned table's parent is inherited by every existing and future partition
-- automatically (PostgreSQL 11+) — no per-partition (orders_2026_07, ...) policy is needed.

ALTER TABLE order_items ENABLE ROW LEVEL SECURITY;

-- order_items has no owner column of its own — the policy joins back to the parent orders row,
-- the same pattern kart-cart-service's database-design.md uses for cart_line_items, rather than
-- denormalizing user_id onto every line item purely to satisfy RLS.
CREATE POLICY order_items_owner_isolation ON order_items
    USING (
        current_setting('app.current_principal_kind') IN ('service', 'system')
        OR EXISTS (
            SELECT 1 FROM orders o
            WHERE o.order_id = order_items.order_id
              AND o.user_id = current_setting('app.current_principal')::uuid
        )
    );

ALTER TABLE order_events ENABLE ROW LEVEL SECURITY;

-- Same join-to-parent shape as order_items — order_events is an internal audit/Outbox trail,
-- not a customer-facing read path (GET /orders/{id} reads the MongoDB projection, never this
-- table directly), but the policy is still applied for defense-in-depth against a future
-- direct-read code path that forgets that distinction.
CREATE POLICY order_events_owner_isolation ON order_events
    USING (
        current_setting('app.current_principal_kind') IN ('service', 'system')
        OR EXISTS (
            SELECT 1 FROM orders o
            WHERE o.order_id = order_events.order_id
              AND o.user_id = current_setting('app.current_principal')::uuid
        )
    );
```

The `service`/`system` branch is not a blanket bypass: it is only ever reached by Admin Service's own client-credentials principal on `resolve-fulfillment-exception` (already restricted to that one endpoint at the API layer, requirement-spec §5) and by Order's own internal Saga-step consumers/reconciliation sweep, none of which are externally reachable. RLS's marginal, additive protection here is specifically against the failure mode §24.1.4 itself names — a user-facing code path (e.g. a future customer-facing order-history endpoint) that forgets its own `WHERE user_id = ...` clause — which stays fully blocked whenever `app.current_principal_kind = 'user'`.

## Sensitive / PII Column Classification (BRD §24.1.5)

Column-level security answers a narrower question than row-level security: of the columns in a row a caller already has `CanRead` on (BRD §24.1.2), which does that caller's own coarse role actually see — full value, masked, or nothing.

**Order has no sensitive/PII columns to classify.** `orders` holds an opaque `user_id` owner reference (already governed by the RLS policy above, not column-level masking), `status`, `total_amount`/`currency`, and `idempotency_key`; `order_items` holds only `sku`/`qty`/`unit_price`/`currency`; `order_events` holds only state-transition metadata and the Outbox `payload` (the same order/line-item shape already visible to the owning caller via the API). None of these is the kind of column §24.1.5 exists to mask — no phone number, address, or credential-shaped value is stored on any of Order's own tables (contrast with User Service's `phone`/address columns, the BRD's own worked example, or Payment's tokenized-at-the-gateway credentials). This mirrors BRD §24.1.5's own reasoning for Payment Service ("no unmasked PCI data exists to protect in the first place") for a structurally similar reason: Order's columns are commercial/state-machine data, never PII, so there is nothing here for column-level masking to gate.

**Enforcement point:** not applicable — there is no column requiring role-differentiated response shaping today. If a future requirement introduces a genuinely sensitive column (e.g. a denormalized shipping-address copy), the primary control would be this service's own response-serialization DTO (api-contract.yaml) per §24.1.5's stated default, consistent with every other service on this platform.

## Indexing Rationale

| Index | Query it supports | Why needed |
|---|---|---|
| `idx_orders_idempotency_key` (unique) | `POST /orders` dedup check | Direct enforcement of the Idempotent creation invariant — a DB constraint, not just application logic |
| `idx_orders_user_id` | "This user's orders" (customer order history, if ever exposed) | BRD §6.1 names this exact index for `orders` |
| `idx_orders_status_created` | Reconciliation sweep's "orders stuck past threshold" scan (edge-cases.md, Orphaned/Stuck Saga Detection); ops "all pending orders in last hour" dashboards | BRD §6.1 names this exact composite index; the sweep query is `WHERE status = $awaited_status AND created_at < now() - $threshold`, a direct range scan on this index |
| `idx_order_items_order_id` | Loading an order's line items alongside its parent row | Every `GET`/projection read needs this join; without it, a full table scan per order |
| `idx_order_events_order_seq` (unique) | Per-order sequence uniqueness/ordering check (edge-cases.md, reordering guard) | Enforces `OrderEventSequence`'s monotonic invariant as a DB constraint |
| `idx_outbox_unpublished` | Outbox poller's "unpublished rows" scan | BRD §11's named index pattern, scoped with the added `event_type IS NOT NULL` predicate so the poller never scans audit-only rows that were never meant to be published |

## Partitioning/Sharding

`orders` and `order_events` are range-partitioned by month on `created_at`, exactly as BRD §6.1 specifies and requirement-spec §2 confirms — bounded index size under the platform's highest write volume (1M orders/day normal, 20M/day at 20x flash-sale peak, BRD §4.1) and fast archival of old partitions. `order_items` is not partitioned (requirement-spec §2 only names `orders`/`order_events`) — its row count scales with `orders` but each row is small and always accessed by `order_id`, not by a time-range scan, so partitioning it would add operational overhead (extra partition-maintenance jobs) without a corresponding query-pattern benefit. No sharding is needed at the write side — Order's throughput (§4.1–4.2) is well within a single well-indexed, partitioned PostgreSQL instance's capacity at this platform's stated scale; horizontal write scaling, if ever needed, is a future re-evaluation, not a day-one requirement.

## Idempotency-Key Replay Window

Not specified by the BRD or requirement-spec beyond "unique constraint." Assuming a 24-hour replay window (matching `kart-payment-service`'s own `IdempotencyRecord` TTL default) as a defensible, consistent-with-precedent engineering default: a client retry within 24h of the original `POST /orders` returns the same order; after 24h, a request reusing the same key is treated as a new logical attempt subject to full validation (in practice a near-zero-probability event, since Order's `Idempotency-Key`s are client-generated, typically UUIDs). Enforced at the application layer (a conditional check against `created_at` before treating a duplicate-key hit as a safe replay), not a separate expiry column — `orders` rows are never deleted, so there is nothing to physically expire.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner
- [x] Approved (write-model schema)
