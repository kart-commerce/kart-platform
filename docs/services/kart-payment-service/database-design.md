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
    created_by          TEXT NOT NULL,
                        -- BRD §24.3 — 'system:order-saga-payment-consumer' for the OrderCreated-
                        -- triggered charge (the near-universal case; charge is not a direct
                        -- customer-facing call, requirement-spec §2)
    updated_by          TEXT NOT NULL,
                        -- BRD §24.3 — the Support Agent principal id for a manual refund write
                        -- (ddd-model.md's CanRead/CanWrite/CanDelete invariant), 'system:order-
                        -- saga-payment-consumer' for Order's Saga-compensation refund call, or
                        -- 'system:payment-gateway-webhook-consumer' for a webhook-driven
                        -- completed/failed/disputed transition
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
    requested_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
                        -- this table's created_at under BRD §24.3, in the domain's own refund
                        -- vocabulary
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),   -- BRD §24.3; bumped when status resolves to succeeded/failed
    created_by          TEXT NOT NULL,
                        -- BRD §24.3 — the Support Agent principal id for a manual refund, or
                        -- 'system:order-saga-payment-consumer' for Order's Saga-compensation
                        -- refund call (ddd-model.md's CanRead/CanWrite/CanDelete invariant)
    updated_by          TEXT NOT NULL DEFAULT 'system:payment-gateway-webhook-consumer'
                        -- BRD §24.3 — the webhook ingestion path is the only process that ever
                        -- resolves a refund's status after its initial insert
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
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),   -- BRD §24.3; bumped when stored_response is set
    created_by          TEXT NOT NULL,
                        -- BRD §24.3 — the same acting principal reserving this key: a Support
                        -- Agent's principal id (refund endpoint) or 'system:order-saga-payment-
                        -- consumer' (charge endpoint, whether client- or OrderCreated-triggered)
    updated_by          TEXT NOT NULL,
                        -- BRD §24.3 — same value as created_by; this record has exactly one
                        -- writer across its reserve-then-confirm lifecycle (ddd-model.md's
                        -- Cross-Aggregate Interaction), never a second, different actor
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
                        -- this table's created_at under BRD §24.3, in the domain's own webhook
                        -- vocabulary
    processed_at        TIMESTAMPTZ NULL,
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),   -- BRD §24.3; bumped when processed_at is set
    created_by          TEXT NOT NULL DEFAULT 'system:payment-gateway-webhook-consumer',
                        -- BRD §24.3 — every row here originates from the gateway webhook
                        -- ingestion path; no human/API caller ever inserts one directly
    updated_by          TEXT NOT NULL DEFAULT 'system:payment-gateway-webhook-consumer'
                        -- BRD §24.3 — same process is the sole writer across this row's lifecycle
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

## Row-Level Security Policy (BRD §24.1.4)

Per BRD §24.1.4, the service whose database physically holds a row decides and enforces that row's row-level security — never a shared, central component. Payment's write model is entirely PostgreSQL (`payment_intents`, `refunds`, `idempotency_keys`, `gateway_webhook_events`), which is the precondition for native RLS to even be the candidate mechanism — but BRD §24.1.4 itself names this exact table as its own worked carve-out example: *"Payment's `payment_intents` (per `database-design.md`) never stores `user_id` directly — it keys only on the opaque `order_id`, so a `user_id`-shaped row-level policy would not even apply."*

**None of Payment's four tables has a per-row end-user ownership column, so a native ownership-predicate RLS policy is not applicable to any of them** — verified directly against the schema above, the same verification the "GDPR Erasure" section immediately above already performed for the identical reason (no `user_id`/PII column exists anywhere in this service's schema):

- `payment_intents` / `refunds` key on `order_id` (opaque, Order-owned) and `payment_intent_id` respectively — never `user_id`. There is no end-user JWT claim (`sub`) that maps directly onto a row here the way `carts.user_id` or `orders.user_id` does elsewhere on this platform; the callers that legitimately reach these tables are Order's own Saga-step consumers (system context), the `OrderCreated` consumer (system context), and a Support Agent acting under the §24.1.2 inline refund-cap business rule (a coarse-role + data-dependent check, not a per-row ownership comparison) — none of which RLS's ownership-predicate model is designed to express.
- `idempotency_keys` keys on `(idempotency_key, endpoint)` — a caller-supplied deduplication token, not an ownership column; the same reasoning applies.
- `gateway_webhook_events` keys on `gateway_event_id` — a gateway-assigned identifier with no end-user relationship at all; this table is never read or written by any end-user-facing request path (only the webhook ingestion consumer and internal support/on-call triage touch it, per the Indexing Rationale table above).
- This is the same "no per-row end-user ownership concept" carve-out `kart-identity-service/database-design.md` and `kart-cart-service/database-design.md` both already document for their own operator-managed/internal-only tables (`idp_group_role_mappings`, `cart_outbox_events`) — Payment's carve-out simply spans its entire schema, because none of Payment's tables was ever designed around end-user row ownership in the first place (BRD §5.3's own boundary rationale: Payment's callers are Order, the gateway, and Support Agent tooling, never a customer directly).

**What still protects these tables:** access control here lives entirely at §24.1.2's tier (the Support Agent refund-cap inline business rule, plus restricting `CanWrite` on charge to Order's own system-context triggers) and at the database-credential/connection-role boundary (only Payment's own application service role, plus the narrow internal support-tooling/webhook-consumer contexts, ever hold a connection at all) — not at a per-row predicate, because there is no per-row ownership dimension for a predicate to key on. This is additive reasoning, not a weaker posture: BRD §24.1.3's three-check enforcement flow still applies in full via its first two checks (Gateway coarse role, Payment's own inline CanWrite rule); only the third check (§24.1.4's row-level layer) has no row-ownership shape to attach to here, exactly as the BRD's own worked example anticipates.

## Sensitive / PII Column Classification (BRD §24.1.5)

Column-level security answers a narrower question than row-level security: of the columns in a row a caller already has `CanRead` on (BRD §24.1.2), which does that caller's own coarse role actually see — full value, masked, or nothing. **Payment is the exact worked example BRD §24.1.5 itself names**, so this classification grounds directly in that stated conclusion rather than deriving one from scratch: *"No — Payment Service: no unmasked PCI data exists to protect in the first place — payment credentials are tokenized at the gateway and never stored."*

Verified against the actual schema above: `payment_intents.gateway_token` is an opaque, gateway-issued reference (ddd-model.md's `GatewayToken` value object) — never raw card/PAN data — so there is no plaintext sensitive column to mask in the first place; masking a token that is already non-identifying and useless outside Payment's own gateway integration would add no protection. `refunds`/`idempotency_keys`/`gateway_webhook_events` hold only amounts, statuses, hashes, and gateway-assigned identifiers — none of it PII or PCI data. This is a **stronger** control than role-based masking, not a weaker one: there is no unmasked form of this data to accidentally over-expose to a caller who passed the row-level/§24.1.2 checks, the same reasoning `kart-identity-service/database-design.md` applies to its own never-serialized credential-hash columns (a narrower, stronger control than masking).

**Enforcement point:** not applicable in the primary API-response-shaping sense §24.1.5 describes, since there is no sensitive value to differentially shape per role. The only column meriting any caution at all is `gateway_token` itself, and that caution is already fully met by never returning it in any API response regardless of caller role (it has no legitimate external consumer — the gateway adapter is the only code that ever dereferences it) — the same "never-serialized rather than merely role-masked" pattern Identity applies to its own credential material.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner
- [x] Approved (write-model schema)
