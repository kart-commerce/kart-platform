---
doc_type: edge-cases
service: kart-shipping-service
status: pending-approval
generated_by: edge-case-analyzer-agent
source: docs/services/kart-shipping-service/requirement-spec.md
---

# Edge Cases: kart-shipping-service

## Edge Case: Carrier API failure/timeout during label generation

- **What happens:** The external carrier API call needed to select a rate and generate a label times out, errors, or is simply unavailable mid `POST /shipments` handling, leaving the order with no label and no `ShipmentDispatched`.
- **Why it happens:** requirement-spec's Carrier Selection & Label Generation FR (§2) depends on a synchronous call to a third-party carrier API with no BRD-stated SLA; the Fault Tolerance NFR (§3, "circuit breakers on all outbound calls") names this exact class of failure as expected.
- **Solutions available (3):** Circuit breaker + retry with backoff against the primary carrier, falling back to a secondary carrier on trip · Queue the shipment-creation request and process it asynchronously via the platform's TTL retry-ladder pattern (BRD §8.1) · Fail fast with no fallback carrier, surface the error immediately.
- **Decision (3-5 bullets max):**
  - Chosen: Circuit breaker + retry against the primary carrier, falling back to a secondary carrier on trip.
  - Why: matches the platform-wide Fault Tolerance NFR directly, and a fallback carrier keeps this saga step from stalling on a single vendor's outage.
  - Trade-off accepted: requires integrating at least two carrier APIs, a cost the BRD's single "carrier selection" line item doesn't scope — ties to requirement-spec Open Question 3 (multi-carrier failover unspecified).

## Edge Case: Duplicate `ShipmentDispatched` on consumer/request retry

- **What happens:** `OrderConfirmed` redelivery (or a retried `POST /shipments` call after a client-side timeout) causes Shipping to create a second shipment and publish a second `ShipmentDispatched` for the same order — potentially generating and paying for two carrier labels.
- **Why it happens:** the platform's Reliability NFR ("at-least-once delivery + idempotent consumers," requirement-spec §3) guarantees redelivery is possible; requirement-spec's domain invariant that a shipment must never be created twice for the same order (§4) has nothing enforcing it unless Shipping's write path is explicitly idempotent.
- **Solutions available (3):** Unique constraint on `order_id` in the shipment write table, reject/no-op on conflict · Idempotency-key check (keyed on `orderId`) performed before ever calling the carrier API · Outbox-level event de-duplication only, with no guard before the carrier call.
- **Decision (3-5 bullets max):**
  - Chosen: Unique constraint on `order_id` plus a pre-carrier-call existence check.
  - Why: matches the platform's Outbox + idempotent-consumer pattern (BRD §11), and unlike outbox-only de-dup, prevents the costly side effect (an actual duplicate carrier label) rather than just a duplicate event.
  - Trade-off accepted: an extra read-before-write existence check on the hot path — a small latency cost versus catching duplicates only after the fact.

## Edge Case: Address validation failure / no carrier services the destination

- **What happens:** The address delivered on `OrderConfirmed` fails carrier-side validation, or no integrated carrier services the destination at all — Shipping can neither generate a label nor publish `ShipmentDispatched`, and nothing in the BRD's Event Catalog represents this outcome.
- **Why it happens:** the BRD's Event Catalog (§10) defines only `ShipmentDispatched` (success) for Shipping — no `ShipmentFailed`/`ShipmentCreationFailed` counterpart exists, unlike Inventory's `InventoryReservationFailed` or Payment's `PaymentFailed`. requirement-spec Open Question 4 already names this as a BRD gap.
- **Solutions available (3):** Introduce a `ShipmentCreationFailed` event (mirroring Inventory/Payment's pattern) that Order consumes to drive saga compensation · Route unresolvable shipments to a manual ops queue instead of failing the saga automatically · Retry indefinitely on the standard DLQ ladder with no dedicated failure signal.
- **Decision (3-5 bullets max):**
  - Chosen: Escalated — no default chosen.
  - Why: this is exactly the shape of gap the BRD leaves unresolved for Shipping; picking one silently would invent a requirement the BRD never states, which the Requirement and Edge-Case Agent contracts both prohibit.
  - Trade-off accepted: none — deferred to requirement-spec Open Question 4 for resolution at the Event Design Agent stage.

## Edge Case: Saga compensation must void/cancel an already-generated label

- **What happens:** A shipment label is already generated (carrier-side, external state) when a later step in the order flow needs to unwind — but there is no defined action to cancel or void that label.
- **Why it happens:** BRD §12.2's compensation flow diagram only shows Inventory and Payment as compensating participants; Shipping never appears in it despite appearing in the success flow (§12.1). requirement-spec's domain invariant (§4) that `ShipmentDispatched` represents an external, carrier-side fact makes this state hard to simply overwrite once true.
- **Solutions available (2):** Publish/consume a compensating `ShipmentCancelled`/`ShipmentVoided` event that calls the carrier's void-label API · Structurally prevent the scenario by making shipment creation the terminal saga step, so no later step can trigger compensation against it.
- **Decision (3-5 bullets max):**
  - Chosen: Escalated — no default chosen.
  - Why: whether this scenario is even reachable depends entirely on resolving requirement-spec Open Question 1 (does shipment creation happen before or after `OrderConfirmed`?); deciding a compensation mechanism before that ordering is settled would be arguing a trade-off space the spec itself hasn't fixed yet.
  - Trade-off accepted: none — deferred to requirement-spec Open Questions 1 and 5, both carried to the Architecture Agent stage.

## Edge Case: Carrier API latency blowing the write-path latency budget

- **What happens:** A synchronous third-party carrier call inside shipment creation routinely exceeds the platform's stated write-path latency target.
- **Why it happens:** requirement-spec's Latency NFR (§3) inherits the BRD's generic write-path budget ("P95 < 300ms, includes Outbox insert," BRD §3), a target set for internal DB+Outbox writes — the BRD carves out no exception for a request chained through an external carrier API outside Shipping's control.
- **Solutions available (3):** Decouple the carrier call from the request path — accept `POST /shipments` synchronously (persist intent only), call the carrier out-of-band, publish `ShipmentDispatched` once the carrier confirms · Enforce a short per-call timeout tight enough to stay in budget, treating any overrun as an immediate failure (feeding the address/carrier-failure edge case above) · Exempt Shipping's write path from the platform-wide 300ms NFR as a documented, service-specific exception.
- **Decision (3-5 bullets max):**
  - Chosen: Decouple — accept the request fast, call the carrier out-of-band, publish `ShipmentDispatched` on carrier confirmation.
  - Why: preserves the platform-wide write-path NFR without a service-specific carve-out, and mirrors the Outbox-style async-completion pattern the platform already uses elsewhere (BRD §11).
  - Trade-off accepted: `POST /shipments` returning "accepted" is no longer a guarantee a label exists yet — callers must treat shipment creation as eventually consistent, which reopens rather than resolves requirement-spec Open Question 1's ordering ambiguity.
