---
doc_type: database-design
service: kart-payment-service
status: approved
generated_by: database-design-agent
source: docs/services/kart-payment-service/ddd-model.md, docs/services/kart-payment-service/design-decisions.md, docs/services/kart-payment-service/architecture.md
---

# Database Design: kart-payment-service

Write model is PostgreSQL, the sole source of truth (requirement-spec NFR: "Correctness > raw read speed → PostgreSQL is source of truth," BRD §6.1). No MongoDB/Redis read-model projection exists or is needed — every read this service serves (a single `PaymentIntent`'s current state, its `Refund`s, whether it's disputed) is a single-row-by-primary-key lookup, already within the P95 < 150ms / P99 < 400ms read-path NFR on a plain indexed PostgreSQL read; introducing a denormalized read model here would trade away the strong-consistency guarantee this service exists to provide for no latency benefit CQRS is meant to buy elsewhere on the platform.

## Write Model (PostgreSQL)

```sql
-- PaymentIntent aggregate (ddd-model.md)
CREATE TABLE payment_intents (
    id                  UUID PRIMARY KEY,
    order_id            TEXT NOT NULL,
    gateway_token       TEXT NOT NULL,          -- GatewayToken value object; opaque, gateway-issued, never raw card data
    txn_id              TEXT NULL,              -- GatewayTransactionId value object; set exactly once on transition to 'completed' — the PaymentCompleted event's txnId field (BRD §10)
    captured_amount     NUMERIC(12,2) NOT NULL,
    currency            TEXT NOT NULL,
    status              TEXT NOT NULL DEFAULT 'pending'
                            CHECK (status IN ('pending', 'completed', 'failed', 'disputed')),
    -- ChargebackRecord value object (nullable — set only once a chargeback is ingested, ADR-0012):
    chargeback_id       TEXT NULL,
    chargeback_amount   NUMERIC(12,2) NULL,
    chargeback_reason   TEXT NULL,
    chargeback_received_at TIMESTAMPTZ NULL,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (order_id)   -- exactly one PaymentIntent per order (requirement-spec: charge is idempotent per order;
                        -- a retried OrderCreated delivery resolves via idempotency_keys before ever reaching a second insert here)
);

-- Enforces PaymentIntentStatus's monotonic transition rule (ddd-model.md Invariant, edge-cases.md
-- "Gateway Webhook Arriving Out-of-Order or Duplicated"): Completed -> Disputed is the only legal
-- transition out of a terminal state; every other transition attempt out of a terminal state is a
-- no-op at the application layer, backstopped here so a coding bug can't silently violate it.
CREATE OR REPLACE FUNCTION enforce_payment_intent_status_transition() RETURNS trigger AS $$
BEGIN
    IF OLD.status IN ('completed', 'failed') AND NEW.status NOT IN (OLD.status, 'disputed') THEN
        RAISE EXCEPTION 'illegal PaymentIntentStatus transition: % -> %', OLD.status, NEW.status;
    END IF;
    IF OLD.status = 'disputed' AND NEW.status <> 'disputed' THEN
        RAISE EXCEPTION 'illegal PaymentIntentStatus transition: disputed is terminal for this minimal (ADR-0012) scope';
    END IF;
    IF NEW.status = 'disputed' AND OLD.status <> 'completed' THEN
        RAISE EXCEPTION 'disputed is only reachable from completed (a charge that never completed cannot be charged back)';
    END IF;
    NEW.updated_at := now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_payment_intents_status_guard
    BEFORE UPDATE OF status ON payment_intents
    FOR EACH ROW EXECUTE FUNCTION enforce_payment_intent_status_transition();

-- Refund child entity (ddd-model.md: same aggregate/transaction boundary as PaymentIntent)
CREATE TABLE refunds (
    id                  UUID PRIMARY KEY,
    payment_intent_id   UUID NOT NULL REFERENCES payment_intents(id),
    amount              NUMERIC(12,2) NOT NULL,
    status              TEXT NOT NULL DEFAULT 'pending'
                            CHECK (status IN ('pending', 'succeeded', 'failed')),
    requested_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_refunds_intent_succeeded ON refunds (payment_intent_id)
    WHERE status = 'succeeded';   -- supports the SUM(...) <= captured_amount ceiling check on every insert

-- IdempotencyRecord aggregate (ddd-model.md) — requirement-spec Open Question #1 resolution
CREATE TABLE idempotency_keys (
    idempotency_key     TEXT NOT NULL,
    endpoint            TEXT NOT NULL CHECK (endpoint IN ('charge', 'refund')),
    request_payload_hash TEXT NOT NULL,
    stored_response     JSONB NULL,             -- set once the gateway call / refund write resolves
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at          TIMESTAMPTZ NOT NULL,   -- created_at + 24h (requirement-spec's stated TTL default)
    PRIMARY KEY (idempotency_key, endpoint)     -- the (key, endpoint) scoping requirement-spec Open Question #1 resolved
);

CREATE INDEX idx_idempotency_keys_expiry ON idempotency_keys (expires_at);

-- GatewayWebhookEvent aggregate (ddd-model.md) — requirement-spec Open Question #3 resolution
CREATE TABLE gateway_webhook_events (
    gateway_event_id    TEXT PRIMARY KEY,       -- gateway-assigned, never generated by Payment
    gateway             TEXT NOT NULL,
    payment_intent_id   UUID NOT NULL REFERENCES payment_intents(id),
    event_type          TEXT NOT NULL,          -- GatewayEventType value object (adapter-specific enumeration)
    applied_transition  TEXT NULL,              -- which PaymentIntentStatus transition (if any) this event actually caused
    received_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    processed_at        TIMESTAMPTZ NULL
);

CREATE INDEX idx_gateway_webhook_events_intent ON gateway_webhook_events (payment_intent_id, received_at);
```

## TTL Cleanup & Partitioning

`idempotency_keys` is the one table here with a hard, stated TTL (24h, requirement-spec Open Question #1 resolution) and the platform's highest write volume of the four tables (one row per charge/refund attempt, inheriting the same peak/flash-sale multiplier as `POST /payments/charge` itself, requirement-spec NFR table). Range-partitioning it by `created_at` (daily partitions) is adopted so TTL cleanup is an efficient partition-drop (`DROP TABLE idempotency_keys_2026_07_20`) once every row in a given day's partition is past its 24h `expires_at`, rather than a scanning `DELETE ... WHERE expires_at < now()` competing for I/O with the checkout-path write traffic hitting the current partition. `idx_idempotency_keys_expiry` exists to support a fallback batch-delete path (e.g., a partition still holding a handful of not-yet-expired rows near a boundary), not as the primary cleanup mechanism.

`payment_intents`, `refunds`, and `gateway_webhook_events` are **not partitioned at launch** — the BRD's capacity plan (§4.3) gives no Payment-specific write-volume number distinct from the platform-wide figures every order's single charge attempt already inherits, and single-table PostgreSQL with the indexes above holds the stated latency budget at that volume. `payment_intents` is also the permanent system of record (never pruned, unlike `idempotency_keys`), so there is no TTL-driven reason to partition it now; revisit only if evidence of write-hotspotting or index bloat emerges at actual production scale, the same "single-table sufficient until evidence says otherwise" default `kart-offer-service/database-design.md` already applies.

## Indexing Rationale

| Index | Query it supports | Why needed |
|---|---|---|
| `payment_intents (order_id)` UNIQUE | "Does this order already have a `PaymentIntent`?" — the charge-idempotency-per-order invariant | Direct DB enforcement, not just application logic; also the lookup Order's Saga-compensation refund call and the `OrderCreated` consumer both need |
| `idempotency_keys (idempotency_key, endpoint)` PRIMARY KEY | Replay lookup before every charge/refund gateway call | This *is* the mechanism BRD §6.1 names ("unique constraint... guarantees exactly-once charge attempt semantics") — must be an index, not incidental |
| `idx_idempotency_keys_expiry` | TTL fallback cleanup sweep | Supports pruning rows a partition-drop didn't already remove (boundary cases) without a full-table scan |
| `idx_refunds_intent_succeeded` (partial, `status = 'succeeded'`) | `SUM(refunds.amount) <= captured_amount` ceiling check on every refund insert | On the write path of every refund request (charge P95 < 300ms budget applies to the synchronous accept/enqueue step) — must be an index-only aggregate, not a full scan of a `PaymentIntent`'s refund history |
| `gateway_webhook_events (payment_intent_id, received_at)` | "What webhook history led to this `PaymentIntent`'s current state" (operational/support debugging), and detecting out-of-order delivery | Supports the monotonic-ordering guard's need to reason about prior events for a given intent, and Support Agent/on-call triage during an incident |

## GDPR Erasure (ADR-0016) — Checked, No Action Needed

ADR-0016 names "Payment's transaction records" as an example of financial history that must be retained-but-anonymized (`userId` kept as an opaque referential key, directly-identifying fields tombstoned) rather than hard-deleted on `UserDataErased`. Checked against the actual schema above and found to already satisfy this trivially, not to require a new consumer: `payment_intents` never stores `userId` at all (only `order_id`, itself opaque) and holds no directly-identifying field (`name`, `email`, `address`) anywhere in this service's schema — `gateway_token` is itself an opaque, non-identifying PCI-tokenized reference, not PII. There is nothing here to redact, and therefore no reason for `kart-payment-service` to consume `UserDataErased` — recorded explicitly so a future reader of ADR-0016 doesn't have to re-derive this or mistakenly add a redaction handler for fields that don't exist.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner
- [x] Approved (write-model schema)
