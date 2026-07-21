---
doc_type: adr
status: proposed
---

# ADR-0015: New `ShipmentCreationFailed` Event for Un-Shippable Orders, Consumed by Order as a Post-Confirmation Hold (Not a Saga Compensation)

## Status

Proposed (final ADR number assigned in a later pipeline pass)

## Context

`kart-requirements.md` §10's Event Catalog defines exactly one event for Shipping: `ShipmentDispatched` (the success case). Unlike Inventory (`InventoryReservationFailed`) and Payment (`PaymentFailed`), there is no counterpart failure event for Shipping — the BRD never states what should happen when the address on `OrderConfirmed` fails carrier-side validation, or when no integrated carrier services the destination at all. `kart-shipping-service/requirement-spec.md` (Open Question, this pass) and `edge-cases.md`'s "Address validation failure / no carrier services the destination" edge case both correctly flagged this as a genuine BRD gap and escalated rather than silently guessing.

This is cross-cutting in the same shape as ADR-0005 (`OrderDelivered`) and the ADR-0012 (`docs/adr/0012-payment-chargeback-handling.md`) decision (`ChargebackReceived`): it introduces a brand-new domain event not previously named anywhere in the BRD, with a required consumer in another service (`kart-order-service`) that must react to it. It is not a single-service internal engineering default, so it is recorded here rather than decided silently inside Shipping's own docs.

The reaction this event demands from Order is genuinely novel, not a re-use of the existing Saga compensation flow (§12.2): per ADR-0002, `OrderConfirmed` is published as soon as Payment clears, *before* Shipping does anything — Shipping only acts afterward, as an async consumer. That means a shipment-creation failure is, by construction, a **post-confirmation** failure. §12.2's compensation flow (release Inventory, mark `OrderCancelled`) only ever runs for **pre-confirmation** failures (Inventory reservation, Payment). It has no defined behavior for a failure that happens after the order is already confirmed and payment has already been captured — auto-cancelling and refunding a captured payment is a materially different, higher-stakes action than releasing an unconfirmed reservation, and is Order's own call to make, not something this ADR should silently decide on Order's behalf.

## Decision

1. **New event `ShipmentCreationFailed`**, published by Shipping, added to `kart-requirements.md` §10's Event Catalog, matching the naming/tiering pattern its sibling `ShipmentDispatched` and Inventory/Payment's failure events already establish:

   | Event | Publisher | Consumer(s) | Payload (key fields) | Retry | DLQ Strategy |
   |---|---|---|---|---|---|
   | `ShipmentCreationFailed` | Shipping | Order, Notification, Analytics | `orderId, reason` | 3x | `shipping.dlq` |

   Same retry/DLQ tier as `ShipmentDispatched` (standard tier, not the money-critical `Payment*` 5x/paged tier) — this is a fulfillment failure, not a financial one. Notification and Analytics are added under their already-resolved default rules (ADR-0003's `order.*`/`payment.*`-plus-named-intent scope does not cover this event by namespace, but "an operational failure the customer needs to hear about" is the same notification-intent reasoning ADR-0003 already applies to `WishlistPriceAlertTriggered`; Analytics per ADR-0004's full fan-in default, which needs no re-justification).

2. **Shipping-side handling**: exhausting all configured carrier options (per `edge-cases.md`'s existing circuit-breaker + secondary-carrier decision) without producing a valid label — including the address-validation-failure and no-carrier-services-destination cases — is what triggers publication of `ShipmentCreationFailed`. This does not happen on a single carrier's transient failure (that is retried/failed-over per the existing edge case); it happens only once the failure is terminal from Shipping's own perspective.

3. **Order-side handling** (functional expectation on `kart-order-service`, to be reflected in its own docs on its own pass, the same deferral pattern ADR-0012 (`docs/adr/0012-payment-chargeback-handling.md`) uses for Order's chargeback reaction): on consuming `ShipmentCreationFailed`, Order does **not** automatically run its existing pre-confirmation compensation flow (§12.2) — that flow's actions (release Inventory, mark `OrderCancelled`) were designed for reservations/charges that never completed, not for unwinding an order whose payment has already been captured. Instead, Order's minimal required reaction is to transition the order into a distinguishable "held / fulfillment-exception" status and stop silently treating it as progressing normally — whether that resolves into a manual ops workflow, an automatic refund-and-cancel, or a customer-facing address-correction retry is Order Service's own subsequent design decision, not one this ADR makes on Order's behalf.

## Consequences

- `kart-shipping-service/requirement-spec.md`'s Open Question on the missing failure event, and `edge-cases.md`'s "Address validation failure / no carrier services the destination" edge case, are both resolved by this decision.
- `kart-order-service`'s own docs will need `ShipmentCreationFailed` added to its Consumes list and a new post-confirmation "held / fulfillment-exception" order status the next time its own pipeline pass runs — this ADR states the expectation but does not edit that service's files directly (out of scope for this run).
- This does not design a full manual-ops resolution workflow (queueing, SLA, escalation) or decide whether a refund is ever auto-triggered from this path — only that the event exists, who is notified, and that Order's reaction is structurally different from its existing pre-confirmation Saga compensation. Fuller post-confirmation exception handling, if ever needed, is a separate, later decision.
- `kart-shipping-service`'s own Saga-compensation edge case ("must void/cancel an already-generated label") remains a **separate** question from this one: this ADR covers the case where a label was **never** successfully generated; it does not introduce a void/cancel action for a label that **was** generated and later needs unwinding (see ADR-0002's resolution of that question in Shipping's own docs — no reachable Saga step exists after `OrderConfirmed` that would trigger it).
