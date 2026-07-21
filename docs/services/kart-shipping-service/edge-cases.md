---
doc_type: edge-cases
service: kart-shipping-service
status: approved
generated_by: edge-case-analyzer-agent
source: docs/services/kart-shipping-service/requirement-spec.md
---

# Edge Cases: kart-shipping-service

## Edge Case: Carrier API failure/timeout during label generation

- **What happens:** The external carrier API call needed to select a rate and generate a label times out, errors, or is simply unavailable mid shipment-creation processing (triggered by consuming `OrderConfirmed`, per ADR-0002), leaving the order with no label and no `ShipmentDispatched`.
- **Why it happens:** requirement-spec's Carrier Selection & Label Generation FR (§2) depends on a synchronous call to a third-party carrier API with no BRD-stated SLA; the Fault Tolerance NFR (§3, "circuit breakers on all outbound calls") names this exact class of failure as expected.
- **Solutions available (3):** Circuit breaker + retry with backoff against the primary carrier, falling back to a secondary carrier on trip · Queue the shipment-creation request and process it asynchronously via the platform's TTL retry-ladder pattern (BRD §8.1) · Fail fast with no fallback carrier, surface the error immediately.
- **Decision (3-5 bullets max):**
  - Chosen: Circuit breaker + retry against the primary carrier, falling back to a secondary carrier on trip.
  - Why: matches the platform-wide Fault Tolerance NFR directly, and a fallback carrier keeps this saga step from stalling on a single vendor's outage.
  - Trade-off accepted: requires integrating at least two carrier APIs, a cost the BRD's single "carrier selection" line item doesn't scope — ties to requirement-spec Open Question 5 (multi-carrier failover, carried forward non-blocking to the Architecture Agent).
  - Exhausting both the primary and the fallback carrier without a valid label is what triggers `ShipmentCreationFailed` — see the "Address validation failure" edge case below and ADR-0015 (`docs/adr/0015-shipping-shipment-creation-failed-event.md`).

## Edge Case: Duplicate `ShipmentDispatched` on consumer/request retry

- **What happens:** `OrderConfirmed` redelivery (the platform's at-least-once delivery guarantee, not a client retry — per ADR-0002, Shipping has no synchronous inbound endpoint from Order) causes Shipping to create a second shipment and publish a second `ShipmentDispatched` for the same order — potentially generating and paying for two carrier labels.
- **Why it happens:** the platform's Reliability NFR ("at-least-once delivery + idempotent consumers," requirement-spec §3) guarantees redelivery is possible; requirement-spec's domain invariant that a shipment must never be created twice for the same order (§4) has nothing enforcing it unless Shipping's write path is explicitly idempotent.
- **Solutions available (3):** Unique constraint on `order_id` in the shipment write table, reject/no-op on conflict · Idempotency-key check (keyed on `orderId`) performed before ever calling the carrier API · Outbox-level event de-duplication only, with no guard before the carrier call.
- **Decision (3-5 bullets max):**
  - Chosen: Unique constraint on `order_id` plus a pre-carrier-call existence check.
  - Why: matches the platform's Outbox + idempotent-consumer pattern (BRD §11), and unlike outbox-only de-dup, prevents the costly side effect (an actual duplicate carrier label) rather than just a duplicate event.
  - Trade-off accepted: an extra read-before-write existence check on the hot path — a small latency cost versus catching duplicates only after the fact.

## Edge Case: Address validation failure / no carrier services the destination

- **What happens:** The address delivered on `OrderConfirmed` fails carrier-side validation, or no integrated carrier services the destination at all — Shipping can neither generate a label nor publish `ShipmentDispatched`, and nothing in the BRD's Event Catalog represents this outcome.
- **Why it happens:** the BRD's Event Catalog (§10) defines only `ShipmentDispatched` (success) for Shipping — no `ShipmentFailed`/`ShipmentCreationFailed` counterpart exists, unlike Inventory's `InventoryReservationFailed` or Payment's `PaymentFailed`.
- **Solutions available (3):** Introduce a `ShipmentCreationFailed` event (mirroring Inventory/Payment's pattern) that Order consumes to drive a reaction · Route unresolvable shipments to a manual ops queue instead of failing the saga automatically · Retry indefinitely on the standard DLQ ladder with no dedicated failure signal.
- **Decision (3-5 bullets max):**
  - Chosen: Introduce `ShipmentCreationFailed` (Publisher: Shipping; Consumers: Order, Notification, Analytics; payload `orderId, reason`; 3x retry, `shipping.dlq`) — see ADR-0015 (`docs/adr/0015-shipping-shipment-creation-failed-event.md`). This is a cross-cutting decision, not a single-service default, because Order must gain a new consumer and reaction — so it's recorded as an ADR rather than decided silently here.
  - Why: mirrors the exact pattern already established for Inventory/Payment failures, giving un-shippable orders a terminal signal instead of silently stalling; a manual-ops-only queue with no event would leave Order permanently unaware anything went wrong.
  - Trade-off accepted: because shipment creation happens strictly *after* `OrderConfirmed` (ADR-0002), this is a **post-confirmation** failure — Order cannot simply re-run its existing pre-confirmation Saga compensation (§12.2) against it. The PENDING ADR only commits Order to entering a distinguishable "held / fulfillment-exception" state on this event; the full resolution workflow (manual ops vs. auto-refund vs. address-correction retry) is Order Service's own design call, made on its own docs pass, not resolved here.
  - No longer escalated: previously blocked on resolving the sync/async ordering question — that question is now closed (ADR-0002), and the missing-event gap itself is closed by the PENDING ADR above, so nothing about this edge case remains open.

## Edge Case: Saga compensation must void/cancel an already-generated label

- **What happens:** A shipment label is already generated (carrier-side, external state) when a later step in the order flow needs to unwind — but there is no defined action to cancel or void that label.
- **Why it happens:** BRD §12.2's compensation flow diagram only shows Inventory and Payment as compensating participants; Shipping never appears in it despite appearing in the success flow (§12.1). requirement-spec's domain invariant (§4) that `ShipmentDispatched` represents an external, carrier-side fact makes this state hard to simply overwrite once true.
- **Solutions available (2):** Publish/consume a compensating `ShipmentCancelled`/`ShipmentVoided` event that calls the carrier's void-label API · Structurally prevent the scenario by making shipment creation the terminal saga step, so no later step can trigger compensation against it.
- **Decision (3-5 bullets max):**
  - Chosen: Structurally prevented — no compensation mechanism is built, because none is reachable. Per `docs/adr/0002-order-shipping-async-integration.md`, shipment creation happens strictly *after* `OrderConfirmed`; §12.2's compensation flow (release Inventory, mark `OrderCancelled`) only ever runs for *pre-confirmation* failures (Inventory reservation, Payment) and never extends to a step this far downstream. By the time Shipping acts, the BRD's own Saga has already reached its successful terminal state.
  - Why: the BRD's Saga design (§12.1/§12.2), once ADR-0002's ordering resolution is applied, structurally never places Shipping inside the compensation window — building a `ShipmentCancelled`/void-label mechanism against a Saga step that can never fail-and-roll-back would be speculative engineering the BRD doesn't call for.
  - Trade-off accepted: if the platform later adds a genuinely new capability — a customer cancelling an already-confirmed, already-shipped order outside the Saga's own compensation flow (via Order's `POST /orders/{id}/cancel`) — that would need its own new decision (e.g. a real `ShipmentCancelled`/void-label event) at that time. Nothing in the current BRD names or requires that capability for any service, so it is not built speculatively here; if it's ever needed it is Order Service's scope to raise first, since it owns the cancel API.
  - No longer escalated: this was blocked only on resolving requirement-spec Open Question 1 (shipment-creation ordering) — that question is now closed via ADR-0002, which resolves this edge case as "not applicable" rather than leaving a mechanism undecided.

## Edge Case: Carrier API latency blowing the write-path latency budget

- **What happens:** A synchronous third-party carrier call inside shipment creation routinely exceeds the platform's stated write-path latency target.
- **Why it happens:** requirement-spec's Latency NFR (§3) inherits the BRD's generic write-path budget ("P95 < 300ms, includes Outbox insert," BRD §3), a target set for internal DB+Outbox writes — the BRD carves out no exception for a request chained through an external carrier API outside Shipping's control. Per ADR-0002, Shipping's trigger is consuming `OrderConfirmed` (not a synchronous inbound call from Order), but the same latency-mismatch problem exists either way: the internal event-processing step (consume → persist → Outbox insert) must not itself block on the carrier round trip.
- **Solutions available (3):** Decouple the carrier call from the `OrderConfirmed`-processing path — persist a shipment-intent row (and Outbox-insert an internal marker) immediately on consuming `OrderConfirmed`, call the carrier out-of-band, publish `ShipmentDispatched` once the carrier confirms · Enforce a short per-call timeout tight enough to stay in budget, treating any overrun as an immediate failure (feeding the address/carrier-failure edge case above) · Exempt Shipping's write path from the platform-wide 300ms NFR as a documented, service-specific exception.
- **Decision (3-5 bullets max):**
  - Chosen: Decouple — process `OrderConfirmed` and persist the shipment intent fast, call the carrier out-of-band, publish `ShipmentDispatched` (or `ShipmentCreationFailed`, per the edge case above) once the carrier interaction resolves.
  - Why: preserves the platform-wide write-path NFR without a service-specific carve-out, and mirrors the Outbox-style async-completion pattern the platform already uses elsewhere (BRD §11).
  - Trade-off accepted: `ShipmentDispatched` (and downstream consumers relying on it — Order, Notification, Tracking) must treat shipment creation as eventually consistent relative to `OrderConfirmed` — this is already the platform's chosen design under ADR-0002's fully-async integration, not a new complication introduced by this decision.
