---
doc_type: database-design
service: kart-shipping-service
status: approved
generated_by: database-design-agent
source: docs/services/kart-shipping-service/ddd-model.md, docs/services/kart-shipping-service/architecture.md, docs/services/kart-shipping-service/design-decisions.md, docs/services/kart-shipping-service/requirement-spec.md, docs/services/kart-shipping-service/edge-cases.md
---

# Database Design: kart-shipping-service

Write model is PostgreSQL, the sole source of truth (requirement-spec §3 Consistency NFR: "Strong (PostgreSQL write)... no read-model/cache layer is stated for Shipping, unlike Product/Promotion"). **No MongoDB/Redis read model is designed here, and none is needed.** Every read this service's own domain requires — the pre-carrier-call existence check ("does this `orderId` already have a `Shipment`") and the eventual out-of-band worker's own lookup — is a single indexed point read/write against the one `shipments` row keyed on `order_id`; there is no fan-out, multi-aggregate, or cross-service read this schema needs to serve at CQRS-projection scale. The only possible read surface beyond that is the internal/administrative `/shipments` endpoint architecture.md leaves unconfirmed ("query and/or manual shipment creation... left to the API Design Agent") — nothing in requirement-spec, architecture.md, or design-decisions.md states a latency/volume budget for that endpoint distinct from an ops/admin tool's normal expectations, so building a denormalized projection for it now would be speculative. If the API Design Agent's own pass fixes that endpoint's shape as genuinely read-heavy (e.g., a paginated ops dashboard scanning thousands of shipments), that is the trigger to revisit this decision then — not a gap to pre-empt here.

## Write Model (PostgreSQL)

```sql
-- Shipment aggregate root (ddd-model.md)
CREATE TABLE shipments (
    id              UUID PRIMARY KEY,
    order_id        UUID NOT NULL,          -- OrderId value object; reference-only, owned by kart-order-service
    status          TEXT NOT NULL DEFAULT 'Pending'
                        CHECK (status IN ('Pending', 'Dispatched', 'Failed')),   -- ShipmentStatus
    carrier         TEXT NULL,              -- Carrier value object; set exactly once, only on transition to Dispatched
    tracking_id     TEXT NULL,              -- TrackingId value object; carrier-issued, set exactly once alongside carrier
    failure_reason  TEXT NULL,              -- FailureReason value object; set exactly once, only on transition to Failed
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

    UNIQUE (order_id),   -- Uniqueness invariant: at most one Shipment per Order (ddd-model.md;
                         -- requirement-spec §4 Domain Invariant #1). This is the DB-level half of
                         -- the idempotency mechanism design-decisions.md chose; the pre-carrier-call
                         -- existence check is a SELECT against this exact constraint.

    -- Domain Invariant #2 (ddd-model.md): Dispatched requires both carrier and tracking_id
    -- non-null; Failed requires failure_reason non-null and carrier/tracking_id still null
    -- (a shipment that never dispatched never acquires a carrier/tracking fact); Pending has
    -- none of the three set yet. Backstops the transition function at the DB layer so a coding
    -- bug can't persist a structurally invalid row (mirrors kart-payment-service's own
    -- CHECK+trigger pairing for PaymentIntentStatus).
    CONSTRAINT chk_shipment_status_shape CHECK (
        (status = 'Pending'    AND carrier IS NULL     AND tracking_id IS NULL     AND failure_reason IS NULL)
     OR (status = 'Dispatched' AND carrier IS NOT NULL AND tracking_id IS NOT NULL AND failure_reason IS NULL)
     OR (status = 'Failed'     AND carrier IS NULL     AND tracking_id IS NULL     AND failure_reason IS NOT NULL)
    )
);

-- Enforces ShipmentStatus's monotonic, terminal-transition invariant (ddd-model.md: "Pending ->
-- {Dispatched, Failed} only, and only once"; "a redelivered or duplicate resolution of the
-- out-of-band carrier call against an already-terminal Shipment is a no-op, never reapplied").
-- The application layer already treats this as a no-op at the pre-carrier-call existence check
-- and at write time; this trigger backstops it at the DB layer, mirroring
-- kart-payment-service/database-design.md's enforce_payment_intent_status_transition().
CREATE OR REPLACE FUNCTION enforce_shipment_status_transition() RETURNS trigger AS $$
BEGIN
    IF OLD.status IN ('Dispatched', 'Failed') AND NEW.status <> OLD.status THEN
        RAISE EXCEPTION 'illegal ShipmentStatus transition: % is terminal, cannot move to %', OLD.status, NEW.status;
    END IF;
    NEW.updated_at := now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_shipments_status_guard
    BEFORE UPDATE OF status ON shipments
    FOR EACH ROW EXECUTE FUNCTION enforce_shipment_status_transition();

-- Transactional Outbox (design-decisions.md's "Event Publish Atomicity & Carrier-Latency
-- Decoupling" decision). Generic technical infrastructure, not a domain entity — ddd-model.md
-- Modeling Decision #4 explicitly declines to model this as a domain-meaningful audit trail the
-- way kart-order-service's OrderEvent doubles as one; this table carries no such doubling.
--
-- One table, two distinct roles, distinguished by message_type:
--   'CarrierCallRequested'   — internal-only work marker, never published to RabbitMQ. Inserted
--                              in the SAME transaction as the shipments row above, immediately on
--                              consuming OrderConfirmed. This is what decouples the out-of-band
--                              carrier call from the write-path latency budget (requirement-spec
--                              §3: P95 < 300ms covers consume -> persist -> Outbox-insert only,
--                              not carrier label generation). A separate carrier-call worker polls
--                              for unprocessed rows of this type and performs the actual carrier
--                              API interaction (circuit-breaker/bulkhead per carrier,
--                              design-decisions.md's Resilience decision).
--   'ShipmentDispatched' /
--   'ShipmentCreationFailed' — the actual domain events, inserted by the carrier-call worker in
--                              the SAME transaction as the shipments row's terminal-state UPDATE,
--                              once the carrier interaction resolves (success or exhaustion). A
--                              separate event-relay poller reads these and publishes to
--                              RabbitMQ (ecommerce.events, kart-conventions.md), standard tier
--                              (3x retry, shipping.dlq — design-decisions.md's Retry/DLQ decision).
CREATE TABLE shipment_outbox (
    id            UUID PRIMARY KEY,
    shipment_id   UUID NOT NULL REFERENCES shipments(id),
    message_type  TEXT NOT NULL
                      CHECK (message_type IN ('CarrierCallRequested', 'ShipmentDispatched', 'ShipmentCreationFailed')),
    payload       JSONB NOT NULL,     -- CarrierCallRequested: {orderId, address} (see "Where Does
                                       -- the Destination Address Live?" below); ShipmentDispatched:
                                       -- {orderId, carrier, trackingId}; ShipmentCreationFailed:
                                       -- {orderId, reason} — exactly BRD §10's stated payloads
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    processed_at  TIMESTAMPTZ NULL    -- set by the carrier-call worker once it has attempted and
                                       -- resolved a CarrierCallRequested row (successfully or by
                                       -- exhaustion); set by the event-relay poller once it has
                                       -- successfully published a ShipmentDispatched/
                                       -- ShipmentCreationFailed row to RabbitMQ
);

CREATE INDEX idx_shipment_outbox_shipment ON shipment_outbox (shipment_id);

-- Carrier-call worker's poll query: "which shipment-intents are still awaiting a carrier
-- attempt." Scoped to its own message_type so it never scans domain-event rows meant for the
-- relay poller. Mirrors kart-order-service's idx_outbox_unpublished pattern.
CREATE INDEX idx_shipment_outbox_pending_carrier_calls ON shipment_outbox (created_at)
    WHERE message_type = 'CarrierCallRequested' AND processed_at IS NULL;

-- Event-relay poller's poll query: "which resolved domain events still need publishing to
-- RabbitMQ." Scoped the same way, in the other direction.
CREATE INDEX idx_shipment_outbox_pending_publish ON shipment_outbox (created_at)
    WHERE message_type IN ('ShipmentDispatched', 'ShipmentCreationFailed') AND processed_at IS NULL;
```

## Write Mechanics (implements design-decisions.md's Transactional Outbox + Idempotency decisions)

**1. Consuming `OrderConfirmed`** (the write-path step the P95 < 300ms budget covers):

```sql
BEGIN;
-- Pre-carrier-call existence check (design-decisions.md's Idempotency decision) — a single
-- indexed lookup against the same UNIQUE(order_id) constraint below, not a second ledger table
-- (ddd-model.md Modeling Decision #1). A hit here is a no-op: COMMIT/ROLLBACK immediately,
-- never reaching the INSERTs below, never calling the carrier.
SELECT 1 FROM shipments WHERE order_id = $order_id;
-- (no row) ->
INSERT INTO shipments (id, order_id) VALUES ($shipment_id, $order_id);  -- status defaults to 'Pending'
INSERT INTO shipment_outbox (id, shipment_id, message_type, payload)
VALUES ($marker_id, $shipment_id, 'CarrierCallRequested', jsonb_build_object('orderId', $order_id, 'address', $address));
COMMIT;
```

The `UNIQUE (order_id)` constraint is the backstop against a race between the existence-check read and this insert (two redelivered copies of the same `OrderConfirmed` processed concurrently) — the second transaction's `INSERT` fails on the constraint and is treated as the same no-op, not a 500.

**2. Carrier-call worker** (out-of-band, decoupled from the budget above): polls `idx_shipment_outbox_pending_carrier_calls` using `SELECT ... FOR UPDATE SKIP LOCKED` (standard concurrent-poller pattern — avoids needing a separate lease/claim column for what is otherwise a simple "has this been handled yet" flag), attempts the carrier call per `CarrierSelectionPolicy`'s configured priority list (circuit breaker + bulkhead per carrier, design-decisions.md), then commits the outcome atomically:

```sql
BEGIN;
UPDATE shipments SET status = 'Dispatched', carrier = $carrier, tracking_id = $tracking_id
WHERE id = $shipment_id AND status = 'Pending';
INSERT INTO shipment_outbox (id, shipment_id, message_type, payload)
VALUES ($event_id, $shipment_id, 'ShipmentDispatched', jsonb_build_object('orderId', $order_id, 'carrier', $carrier, 'trackingId', $tracking_id));
UPDATE shipment_outbox SET processed_at = now() WHERE id = $marker_id;
COMMIT;
```

(or the symmetric `Failed` / `ShipmentCreationFailed` path once every configured carrier option is exhausted, ADR-0015). If `UPDATE shipments ... WHERE status = 'Pending'` affects 0 rows, this marker is redundant against an already-terminal row (a duplicate/redelivered resolution) — `trg_shipments_status_guard` would reject it anyway; the worker simply marks the outbox row processed and does nothing else, matching ddd-model.md's "no-op, never reapplied" invariant.

**3. Event-relay poller** (standard Outbox relay, BRD §11): polls `idx_shipment_outbox_pending_publish`, publishes each row's `payload` to `ecommerce.events` under the appropriate routing key, sets `processed_at` on success. Identical shape to `kart-order-service`'s and `kart-inventory-service`'s own relays (design-decisions.md).

## Where Does the Destination Address Live? — Filling a Gap `ddd-model.md` Leaves Implicit

`ddd-model.md` lists no `Address` value object on `Shipment` at all — its stated value objects are `OrderId`, `Carrier`, `TrackingId`, `ShipmentStatus`, `FailureReason`, `CarrierSelectionPolicy`. Yet `OrderConfirmed`'s payload (`orderId, address`, BRD §10) is Shipping's only trigger, and the out-of-band carrier-call worker structurally needs that address to make the actual rate/label request — it cannot be silently dropped. This is a real implementation gap the DDD model doesn't close (unlike, say, `kart-delivery-tracking-service/ddd-model.md`'s explicit `LifecycleOrdinal` gap, which its own database-design.md fills) — filled here, not re-litigating `ddd-model.md`'s own value-object list.

**Decision:** the destination address is persisted only inside the `CarrierCallRequested` outbox row's `payload` (step 1 above), never as a column on `shipments` itself. Reasoning:
- `Shipment`'s own invariants (ddd-model.md) never inspect, validate, or branch on the address's structure — it is pure pass-through data the carrier call needs, not a fact this aggregate's transition function reasons about. It doesn't earn a place on the permanent aggregate row the same way `Carrier`/`TrackingId`/`FailureReason` do (each of those is itself produced by this aggregate's own transitions).
- It keeps `shipments` — the long-lived, permanent system-of-record row — free of directly-identifying PII entirely, the same conclusion `kart-payment-service/database-design.md` reaches for `payment_intents` (see GDPR section below): only `order_id`, `carrier` (a company name, not personal data), `tracking_id`, and `failure_reason` persist indefinitely.
- The `CarrierCallRequested` row carrying it is itself transient by construction — once `processed_at` is set (the carrier call has resolved, successfully or by exhaustion), nothing in this service's own domain ever reads that row's payload again. It is a candidate for routine operational pruning (e.g., a scheduled job deleting `shipment_outbox` rows where `processed_at < now() - interval '7 days'`, an ops/retention detail this doc recommends as a defensible default but does not fix with a hard number, since no requirement-spec/architecture NFR states one) rather than a permanent audit record — consistent with ddd-model.md Modeling Decision #4's "generic technical infrastructure, out of this DDD model's scope" framing.

## GDPR Erasure (ADR-0016) — Checked, One Gap Flagged (Non-Blocking)

`shipments` itself holds no directly-identifying PII once the design above is followed — same conclusion `kart-payment-service/database-design.md` reaches for `payment_intents`, and for the same reason (only opaque/referential fields persist indefinitely: `order_id`, `carrier`, `tracking_id`). ADR-0016 does not name `kart-shipping-service` as a service needing to consume `UserDataErased`, and on this schema there is no `user_id` column to key a redaction against even if it did.

**Flagged, not fixed here:** the destination address — genuinely PII — does transit through `shipment_outbox.payload` (the `CarrierCallRequested` row, per above) for as long as that row remains unpruned. `UserDataErased`'s payload (`userId`, `erasedAt`, ADR-0016) has no way to key against this table at all: `OrderConfirmed`'s stated payload (`orderId, address`, BRD §10) never carries `userId` through to Shipping, and `shipment_outbox` is keyed on `shipment_id`/`order_id` only. Two independent mitigations are already in place without needing Shipping to become a `UserDataErased` consumer: (1) the row is prunable/short-lived per the retention recommendation above, bounding exposure to a small operational window rather than indefinite retention; (2) `shipments`, the permanent record, never stores the address at all. Whether that bounded window is itself compliant enough, or whether Order's `OrderConfirmed` payload should instead carry `userId` so Shipping (and any future PII-bearing consumer) could key a proper redaction handler, is a cross-service contract question belonging to `kart-order-service`'s own event-contract ownership — recorded here explicitly so it isn't lost, the same way architecture.md already flags the `ShipmentCreationFailed`/Order reconciliation gap as "expected, deferred... not a gap in Shipping's docs to fix."

## Partitioning/Sharding

Neither `shipments` nor `shipment_outbox` is partitioned at launch. Shipment-creation volume tracks `OrderConfirmed`'s own rate 1:1 (one `Shipment` per confirmed order) — the same volume driver `kart-payment-service/database-design.md` already reasoned about for `payment_intents` (also a 1-per-order write), and that doc's conclusion applies identically here: the BRD's capacity plan gives no Shipping-specific write-volume figure distinct from the platform-wide order-confirmation rate, and requirement-spec/architecture.md never name `shipments`/`shipment_outbox` as partitioned tables the way `kart-order-service`'s BRD §6.1 explicitly names `orders`/`order_events`. Single-table PostgreSQL with the indexes above holds the stated write-path budget (P95 < 300ms, consume -> persist -> Outbox-insert) at that volume — revisit only if evidence of write-hotspotting or index bloat emerges at real production scale, not invented pre-emptively here.

## Indexing Rationale

| Index | Query it supports | Why needed |
|---|---|---|
| `shipments` `UNIQUE (order_id)` | Pre-carrier-call existence check ("does this `orderId` already have a `Shipment`?") on the `OrderConfirmed`-processing hot path; also the natural lookup for the internal/administrative `/shipments` endpoint if the API Design Agent builds a query-by-`orderId` path | Direct DB enforcement of the Uniqueness invariant (ddd-model.md; requirement-spec §4 Domain Invariant #1) — the exact mechanism design-decisions.md's Idempotency decision names, not just application-layer logic; a single indexed point lookup, bounded cost inside the 300ms write-path budget |
| `idx_shipment_outbox_shipment` | Resolving which `shipments` row a given outbox marker belongs to (carrier-call worker and event-relay poller both need this on every row they process) | Every downstream handling step starts from "which shipment does this marker belong to" — without it, a full-table scan per marker |
| `idx_shipment_outbox_pending_carrier_calls` (partial, `message_type = 'CarrierCallRequested' AND processed_at IS NULL`) | Carrier-call worker's poll query: shipment-intents still awaiting an out-of-band carrier attempt | Standard Outbox-poller index shape (BRD §11), scoped to this worker's own message type so it never scans domain-event rows meant for the relay poller — mirrors `kart-order-service`'s `idx_outbox_unpublished` |
| `idx_shipment_outbox_pending_publish` (partial, `message_type IN ('ShipmentDispatched','ShipmentCreationFailed') AND processed_at IS NULL`) | Event-relay poller's poll query: resolved domain events still needing publication to RabbitMQ | Same Outbox-poller pattern, scoped the other direction — the relay never scans internal-only `CarrierCallRequested` rows |

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner
- [x] Approved
