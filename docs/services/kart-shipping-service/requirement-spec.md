---
doc_type: requirement-spec
service: kart-shipping-service
status: approved
generated_by: requirement-agent
source: docs/requirements/kart-requirements.md
---

# Requirement Spec: kart-shipping-service

## 1. Scope

Covers the single BRD service **Shipping Service** (BRD §2.1 item 16): "Carrier selection, label generation." No service-merge ADR applies (unlike Offer's ADR-0001) — but `docs/adr/0002-order-shipping-async-integration.md` directly governs this service's integration style with Order, and is cited throughout this spec.

The BRD's treatment of Shipping is minimal relative to other services: one condensed API/DB/event row (§5.4), one Event Catalog entry as originally written (§10, `ShipmentDispatched` — a second, `ShipmentCreationFailed`, is added by this pass' PENDING ADR), one appearance in the Order Saga success-flow diagram (§12.1), and no dedicated deep-dive section (unlike Order/Inventory/Payment at §5.1–5.3). This spec does not invent functional or architectural detail the BRD doesn't state — genuine BRD gaps are resolved via ADR or engineering default per this platform's standard closure process, and only carried to Open Questions where the decision legitimately belongs to a later pipeline stage.

## 2. Functional Requirements

- Select a carrier and generate a shipping label for a confirmed order (BRD §2.1 item 16). The BRD states this responsibility by name only — it gives no selection criteria (cheapest / fastest / contracted-rate), no carrier count, and no fallback behavior. See Open Questions (carried forward, non-blocking).
- Consume `OrderConfirmed` (payload: `orderId`, `address` — BRD §10) as the sole trigger for shipment creation (BRD §5.4, §10). Per `docs/adr/0002-order-shipping-async-integration.md`, this consumption is fully asynchronous: Shipping has no synchronous inbound endpoint invoked directly by Order, and `OrderConfirmed` is published by Order as soon as Payment clears — not after a shipment exists. Shipment creation happens strictly *after* order confirmation, not before it.
- `/shipments` (BRD §5.4) is Shipping's API surface, but per ADR-0002 it is not a synchronously-invoked step in the Order Saga. If it exists as an inbound endpoint at all, it is internal/administrative (e.g., an ops query or manual-shipment-creation path), not the Order-triggered creation path — the real trigger is the `OrderConfirmed` consumer above. Whether a `POST /shipments` write endpoint is needed at all beyond that internal use is left to the API Design Agent.
- Publish `ShipmentDispatched` (payload: `orderId`, `carrier`, `trackingId` — BRD §10) once a shipment/label is durably created, consumed by Order, Notification, Delivery Tracking, and Analytics (BRD §10).
- Publish `ShipmentCreationFailed` (payload: `orderId`, `reason`) once all configured carrier options are exhausted without producing a valid label — see ADR-0015 (`docs/adr/0015-shipping-shipment-creation-failed-event.md`). This closes the BRD's previously-unaddressed gap for un-shippable orders (no failure counterpart existed for Shipping, unlike Inventory/Payment).
- Participate in the Order Saga's success flow as the (async, post-confirmation) shipment-creation step (BRD §12.1, as clarified by ADR-0002); Order Service's own row lists Shipping as an async dependency (BRD §5.1: "Shipping Service (async)").

**Resolved — ordering.** BRD §12.1's sequence diagram, read literally, showed Order synchronously invoking Shipping ("Create shipment") and marking `OrderConfirmed` only *after* receiving `ShipmentDispatched` back — apparently contradicting §5.4/§10's reading (`OrderConfirmed` as the trigger Shipping consumes, `ShipmentDispatched` as the async result). `docs/adr/0002-order-shipping-async-integration.md` resolves this: Order↔Shipping is async end-to-end, `OrderConfirmed` is published as soon as Payment clears, and the §12.1 diagram's request/reply-style arrow notation never carried sync/async meaning — it's shared with the equally-async Payment step. `kart-requirements.md` §12.1 now carries a clarifying prose note recording this. This was the spec's only blocking ambiguity; it is closed, not carried forward.

## 3. Non-Functional Requirements

Pulled from the BRD's global NFR table (§3), scoped to this service:

| Attribute | Target | Applies here because |
|---|---|---|
| Availability | 99.9% (secondary tier), not 99.99% (order path) | Resolved by ADR-0002: Order publishes `OrderConfirmed` as soon as Payment clears, without waiting on Shipping — Shipping sits *off* Order's critical confirmation path by construction, so it takes the platform's secondary-tier target, not the order-path tier. |
| Latency | P95 < 300ms applies to Shipping's own internal write path (consume `OrderConfirmed` → persist shipment intent → Outbox insert), not to carrier label generation | BRD's generic write-path budget (§3) was set for internal DB+Outbox writes. `edge-cases.md`'s "Carrier API latency" decision decouples the external carrier call from this budget entirely — carrier confirmation happens out-of-band, and `ShipmentDispatched` is published once it completes, so the 300ms target is never chained through a third-party SLA. |
| Consistency | Strong (PostgreSQL write) | BRD §5.4 states Shipping's DB as PostgreSQL only — no read-model/cache layer is stated for Shipping (unlike Product/Promotion), so no eventual-consistency angle applies to Shipping's own store |
| Reliability | At-least-once delivery + idempotent consumers | Applies to `OrderConfirmed` consumption and `ShipmentDispatched`/`ShipmentCreationFailed` publication — redelivery must not create a second shipment/label for the same order |
| Retry/DLQ | `ShipmentDispatched` and `ShipmentCreationFailed`: 3x retry, `shipping.dlq` (BRD §10; `ShipmentCreationFailed` per ADR-0015 (`docs/adr/0015-shipping-shipment-creation-failed-event.md`)) | Standard tier, not the `Payment*` 5x/paged tier — consistent with Shipping not being flagged as money-moving |
| Fault Tolerance | Circuit breakers on all outbound calls (BRD §3) | Directly applies: carrier label-generation is Shipping's only external, third-party outbound call — see `edge-cases.md`'s circuit-breaker + secondary-carrier decision |

## 4. Domain Invariants

- A shipment/label must never be created twice for the same order (no duplicate carrier label) — inferred from the platform's "at-least-once delivery + idempotent consumers" NFR (§3); the BRD does not state this for Shipping explicitly, but the same reasoning the BRD applies to Inventory-oversell and Payment-double-charge (§2.2) applies here to duplicate label generation/cost.
- `ShipmentDispatched` must only be published once a shipment record is durably persisted (PostgreSQL, §5.4) and carries a valid, non-empty `carrier` and `trackingId` — the event's own stated payload fields (§10) are the only signal the BRD gives for what "dispatched" means.
- Once published, `ShipmentDispatched` represents an external, carrier-side fact (a label exists) — reversing it is not a simple state overwrite. **Resolved:** per ADR-0002, shipment creation happens strictly after `OrderConfirmed`, and the BRD's own Saga compensation flow (§12.2) only ever compensates *pre-confirmation* failures (Inventory reservation, Payment) — it never reaches a step this far downstream. No reachable Saga step exists after `OrderConfirmed` that would trigger a compensating "void the label" action, so no such action is required by the BRD's stated Saga design. (A logically separate scenario — a customer cancelling an already-confirmed, already-shipped order through Order's own `POST /orders/{id}/cancel` — is not a Saga-compensation matter and is not addressed anywhere in the BRD for any service; it is Order Service's own scope to define if/when it arises, not a gap in this spec.)
- A shipment that can never be created for a given order (address fails carrier validation, or no carrier services the destination) must still produce a terminal signal rather than being silently dropped — `ShipmentCreationFailed`, per ADR-0015 (`docs/adr/0015-shipping-shipment-creation-failed-event.md`).

## 5. API Surface (from BRD, starting point only)

| Endpoint/Event | Direction | Notes |
|---|---|---|
| `/shipments` | Inbound API (internal/administrative only) | BRD §5.4. Per ADR-0002, this is **not** the Order-triggered creation path — Order never invokes Shipping synchronously. If a write endpoint exists here at all, it's for internal/ops use (e.g. manual shipment creation or query); final shape is the API Design Agent's job. |
| `OrderConfirmed` | Consumed | Published by Order (BRD §5.4, §10) as soon as Payment clears (ADR-0002). This is Shipping's sole shipment-creation trigger, consumed fully asynchronously — no synchronous inbound call from Order. |
| `ShipmentDispatched` | Published | Consumed by Order, Notification, Delivery Tracking, Analytics (BRD §10) |
| `ShipmentCreationFailed` | Published | New event — Consumed by Order, Notification, Analytics. See ADR-0015 (`docs/adr/0015-shipping-shipment-creation-failed-event.md`). |

Final contract is the API Design Agent's job, not this spec's.

## 6. Open Questions / Flagged Ambiguities

**Blocking:** none remain. All items below are either resolved (with citation) or explicitly non-blocking carry-forwards to a later pipeline stage.

**Resolved:**

1. **`OrderConfirmed` / `ShipmentDispatched` sequence contradiction — RESOLVED.** BRD §12.1's diagram appeared to show shipment creation preceding `OrderConfirmed` via a synchronous-looking call, contradicting §5.4/§10's async-consumer reading. Resolved by `docs/adr/0002-order-shipping-async-integration.md`: Order↔Shipping is fully async end-to-end; `OrderConfirmed` is published as soon as Payment clears; Shipping has no synchronous inbound endpoint from Order; `ShipmentDispatched` flows back purely as an informational status update. `kart-requirements.md` §12.1 now carries a clarifying prose note recording this. This was the spec's only blocking item — it is closed.
2. **No failure event exists for un-shippable orders — RESOLVED.** BRD's Event Catalog (§10) defined only `ShipmentDispatched` (success) for Shipping, with no `InventoryReservationFailed`/`PaymentFailed`-equivalent counterpart. Resolved by a new PENDING ADR: ADR-0015 (`docs/adr/0015-shipping-shipment-creation-failed-event.md`) introduces `ShipmentCreationFailed` (Publisher: Shipping; Consumers: Order, Notification, Analytics; 3x retry, `shipping.dlq`), published once all configured carrier options are exhausted (address validation failure or no carrier services the destination). The ADR also records that Order's reaction to this event is a distinguishable post-confirmation "held / fulfillment-exception" state, not a re-run of the pre-confirmation Saga compensation flow — full design of that reaction is Order Service's own docs' job on their own pass.
3. **No Saga compensation path for Shipping — RESOLVED (not applicable).** BRD §12.2's compensation flow only shows Inventory and Payment as compensating participants. Now that Q1 is resolved (ADR-0002: shipment creation happens strictly *after* `OrderConfirmed`), this is explained rather than open: §12.2's compensation flow only ever runs for *pre-confirmation* failures (Inventory reservation, Payment) — by the time Shipping acts, the order is already confirmed and the Saga (in the BRD's own defined sense) has already succeeded. No reachable Saga step exists after `OrderConfirmed` that would trigger a "void the label" compensation, so none is required by the BRD's stated design. See Domain Invariants (§4) for the corresponding invariant update, including a note that customer-initiated cancellation of an already-shipped order is a separate, not-yet-BRD-scoped concern belonging to Order Service, not a Shipping-side gap.

**Carried forward (non-blocking — legitimate handoffs to a later pipeline stage, not gaps):**

4. **Carrier selection criteria unspecified.** BRD §2.1 item 16 states only "carrier selection" — no basis is given (cheapest, fastest, contracted-rate, or some blend). This is an implementation-strategy choice, not a BRD contradiction or cross-service concern — carried to the **Architecture/DDD Agent** stages as normal downstream design work.
5. **Multi-carrier support / failover — partially informed, final count still downstream.** `edge-cases.md`'s "Carrier API failure/timeout" decision already establishes the *pattern* (circuit breaker against a primary carrier, falling back to a secondary on trip), which requires at least two carrier integrations. The exact carrier count/roster and per-carrier contractual details are carried to the **Architecture Agent** stage as normal downstream scoping, not a blocking gap.

## Sign-off

- [x] Blocking open questions resolved (Q1)
- [x] Reviewed by: Automated architecture pipeline — see docs/adr and this run's decision log
- [x] Approved to proceed to Architecture Agent
