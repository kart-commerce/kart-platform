---
doc_type: requirement-spec
service: kart-shipping-service
status: approved
generated_by: requirement-agent
source: docs/requirements/kart-requirements.md
---

# Requirement Spec: kart-shipping-service

## 1. Scope

Covers the single BRD service **Shipping Service** (BRD §2.1 item 16): "Carrier selection, label generation." No merge — no ADR applies.

The BRD's treatment of Shipping is minimal relative to other services: one condensed API/DB/event row (§5.4), two Event Catalog entries (§10), one appearance in the Order Saga success-flow diagram (§12.1), and no dedicated deep-dive section (unlike Order/Inventory/Payment at §5.1–5.3). This spec does not invent functional or architectural detail the BRD doesn't state — gaps are named in Open Questions rather than filled in.

## 2. Functional Requirements

- Select a carrier and generate a shipping label for a confirmed order (BRD §2.1 item 16). The BRD states this responsibility by name only — it gives no selection criteria (cheapest / fastest / contracted-rate), no carrier count, and no fallback behavior. See Open Questions.
- Expose `POST /shipments` to create a shipment (BRD §5.4).
- Consume `OrderConfirmed` (payload: `orderId`, `address` — BRD §10) as the trigger for shipment creation (BRD §5.4).
- Publish `ShipmentDispatched` (payload: `orderId`, `carrier`, `trackingId` — BRD §10) once a shipment/label is created, consumed by Order, Notification, and Delivery Tracking (BRD §10).
- Participate in the Order Saga as the shipment-creation step (BRD §12.1); Order Service's own row lists Shipping as an async dependency (BRD §5.1: "Shipping Service (async)").

**Note on ordering:** BRD §12.1's sequence diagram shows Order synchronously invoking Shipping ("Create shipment") and marking `OrderConfirmed` only *after* receiving `ShipmentDispatched` back — i.e., shipment creation precedes order confirmation. This directly contradicts the reading above (drawn from §5.4/§10), where `OrderConfirmed` is the trigger Shipping consumes and `ShipmentDispatched` is the result — i.e., order confirmation precedes shipment creation. Both are stated verbatim in the BRD and cannot both be true. See Open Questions Q1 — this is the spec's single blocking ambiguity.

## 3. Non-Functional Requirements

Pulled from the BRD's global NFR table (§3), scoped to this service:

| Attribute | Target | Applies here because |
|---|---|---|
| Availability | Unclear — 99.99% (order path) vs. 99.9% (secondary) | BRD §3 only names "order path" generically; whether Shipping sits on that critical path or off it depends entirely on which reading of Q1 holds. Not resolved here — see Open Questions. |
| Latency | P95 < 300ms (write path, includes Outbox insert) — as stated, but see Open Questions | `POST /shipments` is a write, but BRD's write-path budget was set for internal DB+Outbox writes, not a request chained through an external carrier API with no BRD-stated SLA of its own |
| Consistency | Strong (PostgreSQL write) | BRD §5.4 states Shipping's DB as PostgreSQL only — no read-model/cache layer is stated for Shipping (unlike Product/Promotion), so no eventual-consistency angle applies to Shipping's own store |
| Reliability | At-least-once delivery + idempotent consumers | Applies to `OrderConfirmed` consumption and `ShipmentDispatched` publication — redelivery must not create a second shipment/label for the same order |
| Retry/DLQ | `ShipmentDispatched`: 3x retry, `shipping.dlq` (BRD §10) | Standard tier, not the `Payment*` 5x/paged tier — consistent with Shipping not being flagged as money-moving |
| Fault Tolerance | Circuit breakers on all outbound calls (BRD §3) | Directly applies: carrier label-generation is Shipping's only external, third-party outbound call |

## 4. Domain Invariants

- A shipment/label must never be created twice for the same order (no duplicate carrier label) — inferred from the platform's "at-least-once delivery + idempotent consumers" NFR (§3); the BRD does not state this for Shipping explicitly, but the same reasoning the BRD applies to Inventory-oversell and Payment-double-charge (§2.2) applies here to duplicate label generation/cost.
- `ShipmentDispatched` must only be published once a shipment record is durably persisted (PostgreSQL, §5.4) and carries a valid, non-empty `carrier` and `trackingId` — the event's own stated payload fields (§10) are the only signal the BRD gives for what "dispatched" means.
- Once published, `ShipmentDispatched` represents an external, carrier-side fact (a label exists) — reversing it is not a simple state overwrite; it requires an explicit compensating action if one is ever needed (BRD gives no such action — see Open Questions Q5).

## 5. API Surface (from BRD, starting point only)

| Endpoint/Event | Direction | Notes |
|---|---|---|
| `POST /shipments` | Inbound API | BRD §5.4. Trigger is ambiguous — see Open Questions Q1: either directly invoked by Order Service (per §12.1's diagram) or invoked internally by Shipping's own `OrderConfirmed` consumer (per §5.4/§10) |
| `OrderConfirmed` | Consumed | Published by Order (BRD §5.4, §10). Ordering relative to shipment creation disputed — see Open Questions Q1 |
| `ShipmentDispatched` | Published | Consumed by Order, Notification, Delivery Tracking (BRD §10) |

Final contract is the API Design Agent's job, not this spec's.

## 6. Open Questions / Flagged Ambiguities

**Blocking:**

1. **`OrderConfirmed` / `ShipmentDispatched` sequence contradiction.** BRD §12.1 (Saga success-flow diagram) shows: `Order->>Shipping: Create shipment` → `Shipping-->>Order: ShipmentDispatched` → `Order->>Order: Mark OrderConfirmed`. This means shipment creation happens *before* `OrderConfirmed` exists, via what the diagram draws as a direct (synchronous-looking) call. But BRD §5.4's condensed service table and §10's Event Catalog both state Shipping's Key Events Consumed is `OrderConfirmed` and Key Events Published is `ShipmentDispatched` — meaning `OrderConfirmed` must already exist and be published by Order *before* Shipping acts, asynchronously, via the message bus. These are mutually exclusive sequences (and mutually exclusive integration styles — synchronous request/reply vs. async pub/sub). BRD §5.5's boundary diagram adds a third, only-partially-consistent data point: it draws `Order --> Shipping` as a direct/solid edge (like `Order --> Inventory`, `Order --> Payment`) separately from `Shipping -. events .-> Bus`, but shows no edge from `Bus` back into Shipping for `OrderConfirmed` at all — so the diagram doesn't fully support either reading on its own. BRD §5.1's Order Service row calling Shipping an "async" dependency leans toward the event-catalog reading, but is not conclusive. Not resolved here — this determines Shipping's actual trigger, its availability/latency NFR tier, and whether a Saga-compensation path is even reachable (Q5). Carried to the **Architecture Agent** stage, since resolving sync-vs-async integration style is explicitly that agent's job per its charter — not a Requirement Agent call.

**Carried forward (non-blocking — resolved by a later pipeline stage, not here):**

2. **Carrier selection criteria unspecified.** BRD §2.1 item 16 states only "carrier selection" — no basis is given (cheapest, fastest, contracted-rate, or some blend). Carried to the **Architecture/DDD Agent** stages.
3. **Multi-carrier support / failover unspecified.** The BRD implies at least carrier selection exists (i.e., more than one option), but never states how many carrier integrations are required or what happens if the chosen carrier's API is unavailable. Carried to the **Architecture Agent** stage.
4. **No failure event exists for un-shippable orders.** BRD's Event Catalog (§10) defines only `ShipmentDispatched` (success) for Shipping — unlike Inventory's `InventoryReservationFailed` or Payment's `PaymentFailed`, there is no `ShipmentCreationFailed`/`ShipmentFailed` counterpart. The BRD does not say what Shipping should do if `OrderConfirmed`'s address fails carrier validation, or no carrier services the destination at all. Carried to the **Event Design Agent** stage.
5. **No Saga compensation path for Shipping.** BRD §12.2 (Saga failure/compensation flow) only shows Inventory and Payment as compensating participants — Shipping never appears, even though §12.1 places Shipping in the success flow. Whether a compensating "void/cancel shipment" action is needed at all depends on resolving Q1 first (if shipment creation happens last, right before `OrderConfirmed`, there may be no later step left to fail against it; if it happens first per an alternate saga ordering, a compensation path is required and currently undefined). Carried to the **Architecture Agent** stage, contingent on Q1.

## Sign-off

- [ ] Blocking open questions resolved (Q1)
- [ ] Reviewed by:
- [ ] Approved to proceed to Architecture Agent
