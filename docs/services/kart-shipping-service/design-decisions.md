---
doc_type: design-decisions
service: kart-shipping-service
status: pending-approval
generated_by: design-decision-agent
source: docs/services/kart-shipping-service/requirement-spec.md, docs/services/kart-shipping-service/edge-cases.md
---

# Design Decisions: kart-shipping-service

Cross-cutting technology/design-pattern choices this service's requirement-spec and edge-cases force. Service boundaries, aggregates/domain model, and schema/table design are out of scope here — those belong to the Architecture, DDD, and Database Design Agents respectively. A decision not listed here (caching, gRPC, alternate serialization) was checked and skipped because nothing in this service's own spec or edge cases forces a choice on it — e.g. no read-heavy endpoint is stated for Shipping beyond an internal/administrative query the API Design Agent still has to shape.

## Decision: Communication Style for the Order → Shipping Trigger

- **Requirement driving this:** `docs/adr/0002-order-shipping-async-integration.md` (Order↔Shipping integration is fully async, end to end); requirement-spec §2/§5 (Shipping consumes `OrderConfirmed` asynchronously; `/shipments` is not the Order-triggered creation path).
- **Options considered (3):** asynchronous pub/sub consumption of `OrderConfirmed` as the sole shipment-creation trigger, no synchronous inbound endpoint from Order · synchronous REST/RPC endpoint invoked directly by Order as part of its saga step · hybrid — synchronous acknowledgment call from Order, with the actual label generation completing asynchronously afterward.
- **Decision:**
  - Chosen: asynchronous pub/sub consumption of `OrderConfirmed`; Shipping exposes no synchronous inbound endpoint that Order calls to create a shipment.
  - Why: ADR-0002 already settles this for the platform — Order publishes `OrderConfirmed` as soon as Payment clears, before Shipping does anything, so there is no request/reply exchange to design a synchronous contract for; a hybrid sync-ack option would reintroduce exactly the coupling ADR-0002 exists to remove.
  - Trade-off accepted: Shipping's fulfillment state is only known to Order and downstream consumers once `ShipmentDispatched`/`ShipmentCreationFailed` is published — an eventually-consistent view, not an immediate one — which is the deliberate, already-accepted cost of ADR-0002's decoupling, not a new complication introduced here.
  - Out of scope here: whether `/shipments` needs a write endpoint at all for internal/administrative use, and its shape, is left to the API Design Agent per requirement-spec §5 — this decision only fixes that such an endpoint (if built) is not the Order-triggered creation path.

## Decision: Resilience Pattern for Carrier API Calls

- **Requirement driving this:** NFR Fault Tolerance row (requirement-spec §3, "circuit breakers on all outbound calls"); edge-cases.md's "Carrier API failure/timeout during label generation," which already chose the pattern at the business-decision level but left the concrete resilience-library shape open.
- **Options considered (3):** per-carrier circuit breaker + bounded retry-with-backoff against the primary carrier, with bulkhead isolation so the primary carrier's open circuit never consumes the capacity needed to attempt the secondary carrier · a single shared circuit breaker across both carriers (one open state trips fallback for both) · retry-with-backoff only, no breaker state, relying purely on per-call timeouts.
- **Decision:**
  - Chosen: per-carrier circuit breaker + bounded retry-with-backoff, isolated per carrier (bulkhead), falling back from primary to secondary on trip — generalizing edge-cases.md's chosen pattern into a concrete resilience shape.
  - Why: a shared breaker would let the primary carrier's own outage state block or throttle calls to the secondary carrier too, defeating the fallback's purpose; per-carrier isolation mirrors the same bulkhead reasoning `kart-delivery-tracking-service`'s design-decisions.md already applies to its own multi-carrier polling client, keeping the platform's carrier-integration pattern consistent across the two services that both call carrier APIs directly.
  - Trade-off accepted: two independently-tunable breaker configurations (failure threshold, half-open probe interval) to operate instead of one, with no real per-carrier reliability data yet to tune them against — carried forward alongside requirement-spec Open Question 5 (multi-carrier roster/count) to the Architecture Agent rather than fixed with invented numbers here.

## Decision: Idempotency & Duplicate-Shipment Prevention Mechanism

- **Requirement driving this:** Domain Invariant (requirement-spec §4): a shipment/label must never be created twice for the same order; Reliability NFR (§3: at-least-once delivery + idempotent consumers); edge-cases.md's "Duplicate `ShipmentDispatched` on consumer/request retry," which already chose the mechanism at the business-decision level.
- **Options considered (3):** unique constraint on `order_id` in the shipment write table (reject/no-op on conflict) plus a pre-carrier-call existence check keyed on `orderId` · Outbox-level event de-duplication only, with no guard before the carrier call · a separate dedicated idempotency-key tracking table, checked before both the DB write and the carrier call.
- **Decision:**
  - Chosen: unique constraint on `order_id` plus a pre-carrier-call existence check, exactly as edge-cases.md resolved.
  - Why: prevents the costly side effect — an actual duplicate, billable carrier label — rather than only de-duplicating the outbox event after the fact; reuses the platform's existing Outbox + idempotent-consumer pattern (BRD §11) instead of standing up a second, separate dedup table for no added protection the unique constraint doesn't already give.
  - Trade-off accepted: an extra read-before-write existence check sits on the `OrderConfirmed`-processing hot path, a small latency cost versus the Outbox-only option — acceptable because it is bounded to a single indexed lookup on `order_id`, not a call to the carrier itself.

## Decision: Event Publish Atomicity & Carrier-Latency Decoupling — Transactional Outbox

- **Requirement driving this:** Domain Invariant (requirement-spec §4): `ShipmentDispatched` must only be published once a shipment record is durably persisted; Latency NFR (§3): the P95 < 300ms write-path budget applies to consume→persist→Outbox-insert only, not to carrier label generation; edge-cases.md's "Carrier API latency blowing the write-path latency budget," which already chose the decouple-and-complete-out-of-band pattern.
- **Options considered (3):** Transactional Outbox — persist a shipment-intent row and insert an Outbox marker in the same transaction as `OrderConfirmed` processing, call the carrier out-of-band via a separate worker, publish `ShipmentDispatched` (or `ShipmentCreationFailed`) once the carrier call resolves · direct dual-write — call the carrier synchronously inside `OrderConfirmed` processing, then write and publish afterward · CDC-based outbox (e.g. a WAL-tail relay) instead of an application-level poller.
- **Decision:**
  - Chosen: Transactional Outbox, matching the platform's already-established Outbox pattern (BRD §11) and the same shape `kart-order-service` and `kart-inventory-service` already use for their own published events.
  - Why: this is the only option that satisfies "publish only after durable persistence" without chaining the write-path latency budget through an uncontrolled third-party carrier SLA; direct dual-write would re-couple the carrier round-trip into the exact 300ms budget edge-cases.md's decision exists to protect; CDC adds new relay infrastructure the platform doesn't otherwise run for this purpose.
  - Trade-off accepted: `ShipmentDispatched`/`ShipmentCreationFailed` publish latency trails the internal write's commit by however long the out-of-band carrier interaction takes — already the accepted, eventually-consistent cost of ADR-0002's fully-async integration, not a new complication this decision introduces.

## Decision: Retry/DLQ Tiering for Published Events — Standard Tier Confirmed

- **Requirement driving this:** NFR Retry/DLQ row (requirement-spec §3: `ShipmentDispatched`/`ShipmentCreationFailed` — 3x retry, `shipping.dlq`); `docs/standards/kart-conventions.md`'s Money-Moving Criticality rule (`Payment*` events get the highest retry count and paging; other events use the standard tier); ADR-0015 (`ShipmentCreationFailed`'s stated retry/DLQ tier).
- **Options considered (2):** standard platform tier — 3x retry to `shipping.dlq`, no mandatory human paging on final failure · Payment's heavier tier — 5x retry + paged on-call, as `kart-order-service` applies to its own lifecycle events.
- **Decision:**
  - Chosen: standard 3x-retry/`shipping.dlq` tier for both `ShipmentDispatched` and `ShipmentCreationFailed` — not elevated to Payment's tier.
  - Why: `kart-conventions.md`'s stated rule ties the elevated tier to money-moving events specifically; Shipping's own NFR table and ADR-0015 both already fix the standard tier for these two events, and neither event gates order confirmation (ADR-0002) the way a stuck Order-lifecycle event would — a stuck `ShipmentDispatched`/`ShipmentCreationFailed` delays fulfillment visibility, not payment capture or order confirmation.
  - Trade-off accepted: a DLQ'd Shipping event can sit unprocessed longer before a human notices than a paged Payment event would — accepted because Shipping is the platform's secondary-availability tier (requirement-spec §3) by ADR-0002's own construction, not a corner case invented here.

## Sign-off

- [ ] Reviewed by a human before this service proceeds to the Architecture Agent
- [ ] Chosen technologies/patterns approved as-is, or corrections requested
