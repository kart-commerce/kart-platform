---
doc_type: event-contract
service: kart-order-service
status: approved
generated_by: event-design-agent
source: docs/services/kart-order-service/ddd-model.md, docs/services/kart-order-service/api-contract.yaml
---

# Event Contract: kart-order-service

Exchange: `ecommerce.events` (per [kart-conventions.md](../../standards/kart-conventions.md)). Every consumer queue gets its own DLQ per the reusable event standard — never shared, superseding BRD §10's simplified shared `order.dlq` label the same way `kart-offer-service/event-contract.md` already did for its own events.

## Published

| Event | Routing Key | Consumer(s) | Key Fields | Retry | DLQ | Criticality Justification |
|---|---|---|---|---|---|---|
| `OrderCreated` | `order.order.created` | Payment, Notification, Review, Analytics | `orderId`, `userId`, `items`, `total` | 5x exponential, paged on-call | `order.order-created.dlq` | Elevated from BRD §10's original 3x/manual-replay tier (requirement-spec Open Questions resolution #7) — a stuck `OrderCreated` blocks Payment from ever being invoked, at least as severe as a stuck `PaymentCompleted`, and Order is BRD §3's named 99.99%-tier subject. Notification added to the Consumers column (previously omitted despite ADR-0003/`kart-notification-service`'s own approved docs already scoping it in) once ADR-0020 made the omission load-bearing — `OrderCreated` seeds Notification's `order_user_index`, the `userId`-resolution mechanism seven other Order/Payment/Shipping events depend on. Review added the same way once [ADR-0021](../../adr/0021-review-verified-purchase-order-created-dependency.md) made its own omission load-bearing — `OrderCreated` seeds `kart-review-service`'s `VerifiedPurchaseRecord.userId`/`skus` fields, since `OrderDelivered` (below) carries neither. |
| `OrderConfirmed` | `order.order.confirmed` | Shipping, Notification, Analytics | `orderId`, `address` | 5x exponential, paged on-call | `order.order-confirmed.dlq` | Same elevation rationale — a stuck `OrderConfirmed` stalls Shipping from ever starting fulfillment on an already-paid order |
| `OrderCancelled` | `order.order.cancelled` | Inventory, Offer, Notification, Analytics | `orderId`, `reason` | 5x exponential, paged on-call | `order.order-cancelled.dlq` | Same elevation rationale — a stuck `OrderCancelled` leaves Inventory's reservation un-released and Offer's coupon redemption un-voided |
| `OrderCompensationTriggered` | `order.order.compensation-triggered` | Inventory, Notification, Analytics | `orderId`, `reason` | 5x exponential, paged on-call | `order.order-compensation-triggered.dlq` | Same elevation rationale (ADR-0007 originally assigned 3x/`order.dlq`; requirement-spec resolution #7 elevates it alongside its sibling Order lifecycle events, since it is the signal that actually triggers Inventory's release) |
| `OrderDelivered` | `order.order.delivered` | Recommendation, Review, Notification, Analytics | `orderId`, `deliveredAt` | 5x exponential, paged on-call | `order.order-delivered.dlq` | Same elevation rationale — unifies the BRD's phantom `OrderCompleted`/`OrderDelivered` naming (ADR-0005); a stuck delivery signal blocks Review's verified-purchase gate and Recommendation's training signal indefinitely |

No new published events were introduced by this pass — `ddd-model.md`'s Modeling Decision #4 confirms `ChargebackReceived` and `ShipmentCreationFailed` (both newly consumed) do not require a new Order-published counterpart, since Notification/Analytics are already reached directly from Payment's/Shipping's own publication of those events.

## Consumed

| Event | Publisher | Own Retry/DLQ (owned by publisher, listed for traceability only) | Order's Reaction |
|---|---|---|---|
| `InventoryReserved` | Inventory | 2x, `inventory.dlq` | `Created → Reserved` |
| `InventoryReservationFailed` | Inventory | 2x, `inventory.dlq` | No order persists past the synchronous reserve call (api-contract.yaml `409`) — this event is the async saga-advancement signal for that same call (ADR-0009), not a separate compensation trigger |
| `PaymentCompleted` | Payment | 5x, `payment.dlq`, paged | `Reserved → Paid`; publishes `OrderConfirmed` |
| `PaymentFailed` | Payment | 5x, `payment.dlq`, paged | Pre-confirmation compensation: release Inventory (`OrderCompensationTriggered`), then `→ Cancelled` (`OrderCancelled`) |
| `ShipmentDispatched` | Shipping | 3x, `shipping.dlq` | `Paid → Shipped`; informational only, does not gate `OrderConfirmed` (ADR-0002) |
| `ShipmentCreationFailed` | Shipping | 3x, `shipping.dlq` | `Paid → FulfillmentException` (new, ADR-0015) |
| `DeliveryStatusUpdated` | Delivery Tracking | 3x, `tracking.dlq` | `Shipped → Delivered` on terminal value only; publishes `OrderDelivered` (ADR-0005) |
| `ChargebackReceived` | Payment | 5x, `payment.dlq`, paged | Direct `→ Refunded` from any state `Paid` through `Delivered` (new, ADR-0012); releases Inventory reservation if still held (`OrderCompensationTriggered`), never calls Payment's refund endpoint |

## Naming Convention Compliance

Every published event name is `<Entity><PastTenseVerb>` (`event-standards.md`): `OrderCreated`, `OrderConfirmed`, `OrderCancelled`, `OrderDelivered` comply directly; `OrderCompensationTriggered` is inherited BRD naming (a compound past-tense verb phrase, "CompensationTriggered") — not renamed here, since it is an existing cross-service-agreed contract (ADR-0007) and renaming it now would be a breaking change to Inventory's/Notification's/Analytics' already-approved consumer docs for a purely cosmetic gain. Routing keys follow `service.entity.action` (`order.order.created`, etc.) — `order` as the entity segment for every event, matching this service's single-aggregate model (ddd-model.md), rather than a generic catch-all.

## Retry Tier Justification (Why Every Order-Published Event Is 5x/Paged, Not a Lower Tier)

Unlike `kart-offer-service`'s Coupon events (which stayed at a lower 2x/no-paging tier because the actual double-charge/oversell guard lives elsewhere) or `kart-shipping-service`'s `ShipmentDispatched`/`ShipmentCreationFailed` (standard 3x tier — a fulfillment failure, not a financial one), every event Order itself publishes sits at the platform's highest tier by design: each is either the trigger that advances the Saga to its next money- or stock-adjacent step (`OrderCreated` → Payment charges; `OrderConfirmed` → Shipping fulfills) or the terminal record of a Saga outcome that other services' own state depends on completing (`OrderCancelled`/`OrderCompensationTriggered` → Inventory/Offer must unwind; `OrderDelivered` → Review/Recommendation gate on it). This matches `kart-payment-service/event-contract.md`'s own reasoning for why its events have no lower-criticality contrast to draw against — Order, as the Saga orchestrator, has the same property: there is no "just an Analytics-visibility signal" event in its own published set to contrast against, because a stuck signal anywhere in this list stalls the entire downstream Saga, not just one service's internal bookkeeping.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner
- [x] Approved
