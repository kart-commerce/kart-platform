---
doc_type: event-contract
service: kart-shipping-service
status: approved
generated_by: event-design-agent
source: docs/services/kart-shipping-service/ddd-model.md, docs/services/kart-shipping-service/design-decisions.md, docs/adr/0015-shipping-shipment-creation-failed-event.md, docs/architecture/container-diagram.md
---

# Event Contract: kart-shipping-service

Exchange: `ecommerce.events` (per [kart-conventions.md](../../standards/kart-conventions.md)). Every consumer queue below gets its own DLQ per the reusable event standard (`event-standards.md`: "never a shared/global DLQ") — BRD §10/requirement-spec §3's simplified shared `shipping.dlq` label is expanded into one DLQ per event below, the same override `kart-payment-service/event-contract.md` and `kart-order-service/event-contract.md` already applied for their own BRD-simplified DLQ labels.

## Published

| Event | Routing Key | Consumer(s) | Key Fields | Retry | DLQ | Criticality Justification |
|---|---|---|---|---|---|---|
| `ShipmentDispatched` | `shipping.shipment.dispatched` | Order, Delivery Tracking, Analytics, Notification | `orderId`, `carrier`, `trackingId` | 3x | `shipping.shipment-dispatched.dlq` | Standard tier, not Payment's elevated tier — already fixed by `design-decisions.md`'s "Retry/DLQ Tiering for Published Events" decision, not re-derived here: this is a fulfillment-visibility signal, not a money-moving one (`kart-conventions.md`'s Money-Moving Criticality rule scopes the elevated tier to `Payment*` events specifically), and it does not gate Order's own Saga — `OrderConfirmed` has already published before Shipping does anything (ADR-0002), so a delayed/DLQ'd `ShipmentDispatched` delays fulfillment visibility (tracking, customer notification, analytics), not payment capture or order confirmation |
| `ShipmentCreationFailed` | `shipping.shipment.creation-failed` | Order, Analytics, Notification | `orderId`, `reason` | 3x | `shipping.shipment-creation-failed.dlq` | Same standard tier as its sibling `ShipmentDispatched`, already fixed by ADR-0015's own event-catalog table and confirmed (not re-derived) by `design-decisions.md`'s tiering decision: this is a fulfillment failure, not a financial one — ADR-0015 §"Context" explicitly distinguishes it from a Saga-compensation trigger like `PaymentFailed`, since it fires strictly post-confirmation, after payment has already been captured |

No new events beyond what `ddd-model.md`'s "Domain events (published)" section and ADR-0015 already specify. Both events were already named and tiered before this stage ran — `ShipmentDispatched` per BRD §10, `ShipmentCreationFailed` per ADR-0015 — so there is no additional catalogue gap for this pass to close, matching `kart-payment-service/event-contract.md`'s own note for its analogous BRD-closed event set.

## Consumed

| Event | Publisher | Own Retry/DLQ (owned by publisher, listed for traceability only) | Shipping's Reaction |
|---|---|---|---|
| `OrderConfirmed` | Order | 5x exponential, paged on-call, `order.order-confirmed.dlq` (`kart-order-service/event-contract.md`) | Sole shipment-creation trigger (ADR-0002); idempotent consumption — a duplicate delivery for an `orderId` that already has a `Shipment` row is a no-op at the pre-carrier-call existence check (`ddd-model.md`'s Idempotent event consumption invariant), never a second carrier call or re-publication |

## Consumer Cross-Check Against `container-diagram.md`

Consumer sets above match the platform's already-wired dependency graph exactly, not a re-derived or invented set:
- `ShipmentDispatched` → Order, Delivery Tracking, Analytics, Notification (`container-diagram.md` lines 85-87, 126).
- `ShipmentCreationFailed` → Order, Analytics, Notification (`container-diagram.md` lines 88-89, 127).

Both sets are also independently confirmed by `ddd-model.md`'s "Domain events (published)" section and ADR-0015's own event-catalog table (`Order, Notification, Analytics`) — all three sources agree, so no consumer-set conflict exists to escalate.

## Naming Convention Compliance

`event-standards.md`: event name is `<Entity><PastTenseVerb>`. `ShipmentDispatched` (`Shipment` + `Dispatched`) complies directly. `ShipmentCreationFailed` (`Shipment` + compound past-tense phrase `CreationFailed`) complies in the same sense `kart-order-service/event-contract.md` already accepts for its own `OrderCompensationTriggered` — a compound past-tense verb phrase describing something that already happened (all configured carrier options exhausted), not a re-derivable simpler verb, and it is ADR-0015's own already-accepted name, not renamed here. Routing keys follow `service.entity.action` (`shipping.shipment.dispatched`, `shipping.shipment.creation-failed`) — `shipment` as the entity segment, matching `ddd-model.md`'s single aggregate (`Shipment`), consistent with `kart-payment-service`'s and `kart-order-service`'s own entity-scoped (not generic catch-all) routing-key segments.

No naming collision found against any other service's existing event contract: `ShipmentDispatched`/`ShipmentCreationFailed` already appear, unchanged, in `kart-order-service/event-contract.md`'s own Consumed table (both listed there at the same `3x`, `shipping.dlq`-sourced tier this contract now formalizes per-event) — this pass's routing keys and DLQ names are new expansions of that same already-agreed tier, not a conflicting redefinition.

## Retry Tier Justification (Why Both Events Stay at the Standard 3x Tier, Not Payment's)

Both events published here sit at the platform's standard tier, deliberately not elevated — the direct opposite conclusion from `kart-payment-service/event-contract.md`'s and `kart-order-service/event-contract.md`'s own events, and that contrast is the justification, not an oversight. `design-decisions.md`'s "Retry/DLQ Tiering for Published Events" decision already settled this by citing `kart-conventions.md`'s Money-Moving Criticality rule (elevated tier scoped to `Payment*` events) and ADR-0002's construction of Shipping as the platform's secondary-availability tier: neither `ShipmentDispatched` nor `ShipmentCreationFailed` gates order confirmation or payment capture — `OrderConfirmed` has already published by the time either event is even produced. A stuck/DLQ'd event here delays fulfillment visibility (tracking updates, customer notification, analytics) and, for `ShipmentCreationFailed`, delays Order's transition into its `FulfillmentException` hold state (ADR-0015) — real but strictly lower-stakes than a stuck `PaymentCompleted`/`PaymentFailed` or a stuck Order-lifecycle event that stalls the Saga itself. This pass does not re-derive that tiering decision; it only re-confirms it (`design-decisions.md`'s own decision, cited above) and expresses it as per-event DLQ names instead of the BRD's originally shared `shipping.dlq` label.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner
- [x] Approved
