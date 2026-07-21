---
doc_type: design-decisions
service: kart-payment-service
status: proposed
generated_by: design-decision-agent
source: docs/services/kart-payment-service/requirement-spec.md, docs/services/kart-payment-service/edge-cases.md
---

# Design Decisions: kart-payment-service

Scope: cross-cutting technology/design-pattern choices only (idempotency mechanism, concurrency control, resilience patterns) — not service boundaries, aggregates, or schema, which are the Architecture/DDD/Database Design Agents' job. Every decision below is grounded in a specific requirement-spec.md or edge-cases.md item; a decision not listed here (caching, gRPC, alternate serialization) was checked and skipped because nothing in this service's own spec or edge cases forces a choice on it.

## Decision: Idempotency Mechanism for Money-Moving POSTs (Charge & Refund)

- **Requirement driving this:** Domain Invariant #1 ("a charge must never be executed twice," BRD §2.2) and Domain Invariant #8 (key scoping/TTL), requirement-spec §2/§4/§5, Open Question #1 resolution; API Standards' platform-wide rule that `Idempotency-Key` is mandatory on every money-moving `POST`.
- **Options considered (3):** DB-level unique constraint on `idempotency_keys`, scoped `(idempotency_key, endpoint)`, checked before the gateway call, with a 24h TTL replay window and payload-hash comparison on reuse (edge-cases.md "Double-Charge Under Client Retry", requirement-spec's stated BRD §6.1 mechanism) · Two-phase authorize-then-capture with a synchronous reconciliation query against actual gateway state before any retry decision · Client-generated idempotency key forwarded end-to-end into the gateway call itself, relying solely on the gateway's own native idempotency support with no local constraint
- **Decision (3-5 bullets max):**
  - Chosen: DB unique constraint on `(idempotency_key, endpoint)`, 24h TTL replay window; identical-payload replay within the window returns the stored result with no second gateway call, mismatched-payload replay returns `409 Conflict`, key becomes reusable as a new logical attempt after TTL expiry; forward the same key to the gateway where native idempotency is supported, as a secondary safety net, not the primary control.
  - Why: matches the exact mechanism the BRD itself already names as guaranteeing "exactly-once charge attempt semantics" (§6.1) rather than introducing a reconciliation subsystem the BRD never mentions; the `(key, endpoint)` scope prevents a charge-key and a refund-key from colliding, and the 24h window is a defensible industry-standard default given the BRD states the mechanism but no number.
  - Trade-off accepted: this alone does not resolve the case where the *original* attempt is still unresolved at the gateway when a retry with the same key arrives — that half of double-charge risk is closed separately by the reconciliation-gating decision below, not by the unique constraint itself.

## Decision: Concurrency Control for `payment_intents` State Transitions (Webhook Confirmation Ordering)

- **Requirement driving this:** edge-cases.md "Gateway Webhook Arriving Out-of-Order or Duplicated"; Domain Invariant #2 (`payment_intents` is the sole authoritative record); BRD §13's platform-wide duplicate-message handling pattern; requirement-spec Open Question #3 resolution.
- **Options considered (3):** Idempotent-by-gateway-event-ID ingestion plus a monotonic state-ordering guard that rejects any transition older than the currently stored state · Deduplicate purely on gateway event ID with no ordering logic · Poll/reconcile gateway status directly instead of trusting push delivery
- **Decision (3-5 bullets max):**
  - Chosen: idempotent-by-gateway-event-ID ingestion combined with a monotonic state-ordering guard on `payment_intents` (backward transitions rejected).
  - Why: mirrors the platform's own stated duplicate-message handling (BRD §13) and requires no new infrastructure beyond the state machine `payment_intents` already needs; pure event-ID dedup alone would not stop a late "pending"/"failed" notification from overwriting an already-recorded "succeeded" state.
  - Trade-off accepted: defines a webhook contract/ordering semantics the BRD states none of — the concrete contract shape (headers, signature scheme, retry behavior on the gateway's side) is carried forward to the API Design Agent, not resolved here.

## Decision: Resilience Pattern for Payment Gateway Calls (Retry + Circuit Breaker, Decoupled from Event-Delivery Retry)

- **Requirement driving this:** requirement-spec §2, Open Question #9 resolution; Retry/DLQ NFR row (5x/`payment.dlq`/paged-on-call governs event redelivery only, not the gateway call); Domain Invariant #1 (never double-charge).
- **Options considered (3):** Bounded retry (max 3 attempts, exponential backoff) restricted to transient/network-classified errors only (timeouts, gateway 5xx), with a circuit breaker tripping after a threshold of consecutive transient failures; a definitive decline is terminal and never retried · Blanket retry-all-errors up to the same 5x budget used for event redelivery, conflating gateway-call retry with message-broker retry · No gateway-side retry at all — treat every failure as immediately terminal and let Saga compensation absorb it
- **Decision (3-5 bullets max):**
  - Chosen: bounded transient-only retry (3x, exponential backoff) plus a circuit breaker; declines are terminal immediately; the gateway-call retry policy is kept fully independent of the 5x RabbitMQ event-redelivery tier.
  - Why: retrying a definitive decline risks nothing but wasted calls, but retrying an already-ambiguous outcome risks a double charge — the two failure domains (gateway call vs. event delivery) need different policies, exactly the distinction Open Question #9 forces; a circuit breaker prevents hammering a degraded gateway during an incident.
  - Trade-off accepted: if the outcome is still ambiguous after retries are exhausted, the `payment_intent` is left `pending` rather than speculatively publishing `PaymentFailed` — resolution comes later via the webhook path or a background reconciliation poll, which can add latency to that specific order's Saga path; accepted because the "never double-charge" invariant outweighs speed here.

## Decision: Concurrency Control for Refund Issuance (Captured-Amount Ceiling & Dispute-Hold)

- **Requirement driving this:** Domain Invariant ("a refund amount must not exceed `captured_amount`," requirement-spec §4, Open Question #6 resolution); Domain Invariant ("a `disputed` `payment_intent` must reject any new refund attempt," Open Question #7 resolution, ADR-0012); edge-cases.md "Refund Racing a Chargeback/Dispute on the Same Charge."
- **Options considered (3):** Transactional check-then-insert: `SUM(refunds.amount WHERE status='succeeded') <= payment_intents.captured_amount` and a `disputed = false` gate, both enforced in the same DB transaction that inserts the new `refunds` row · Application-level optimistic locking (a version column on `payment_intents`, retry-on-conflict at the application layer) · Asynchronous ledger reconciliation — allow refunds and chargebacks to proceed independently and reconcile financially after the fact
- **Decision (3-5 bullets max):**
  - Chosen: DB-enforced transactional check (amount ceiling + dispute-hold) in the same transaction as the refund insert.
  - Why: guarantees both invariants atomically at the point of write with no race window between two concurrent refund requests, or between a refund and an incoming chargeback notification on the same intent — the async-reconciliation option was explicitly rejected in edge-cases.md as "letting two independent money movements race"; `payment_intents` is already the system of record (BRD §6.1), so gating on it directly is cheaper than adding an optimistic-locking retry loop.
  - Trade-off accepted: a transactional check-then-insert briefly row-locks `payment_intents` for the duration of the refund-insert transaction, adding minor write-path contention under concurrent refund attempts against the same intent — accepted because Payment's own NFR table already states correctness over raw write throughput as the deciding factor.

## Decision: Saga Compensation Gating — Reconciliation-to-Terminal-State Before Any Refund

- **Requirement driving this:** edge-cases.md "Saga Compensation Against a Pending/Unknown Gateway State"; Domain Invariant #1 (never double-charge) and #2 (`payment_intents` authoritative); requirement-spec Open Question #5 resolution (reconciliation wait deliberately left unbounded by the write-path NFR).
- **Options considered (3):** Compensation must resolve `payment_intent` to a terminal state via gateway reconciliation before issuing any refund; a refund against a still-pending intent is rejected/deferred, never fired unconditionally · Model "pending" as its own explicit Saga step requiring a timeout-and-reconcile before compensation can proceed · Issue a conditional/idempotent refund request that the gateway can safely no-op if no charge actually completed
- **Decision (3-5 bullets max):**
  - Chosen: compensation gates on `payment_intents` reaching a terminal state (via gateway reconciliation), never on saga-local assumptions about Payment's status; a refund against a pending intent is rejected/deferred.
  - Why: firing a refund against an unresolved charge is the direct double-money-movement risk BRD §2.2 exists to prevent; `payment_intents` is the one authoritative store to gate on (Domain Invariant #2), not the Order Saga's own local state.
  - Trade-off accepted: can stall an order's cancellation if the gateway is slow or unreachable; this stall is deliberately left unbounded by the write-path NFR (only the synchronous accept/enqueue of the refund request is bounded, per Open Question #5) — a correctness-over-latency trade the "never double-charge" invariant justifies, consistent with `kart-order-service`'s own reverse-order compensation decision that this same reconciliation gate must not be short-circuited when a chargeback (ADR-0012) is the trigger instead of an ordinary Saga failure.

## Sign-off

- [ ] Reviewed by: _pending human reviewer_
- [ ] Approved to proceed to Architecture Agent
