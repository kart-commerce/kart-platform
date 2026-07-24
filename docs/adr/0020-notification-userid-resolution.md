---
doc_type: adr
status: accepted
---

# ADR-0020: Notification's `userId` Resolution for `orderId`/`trackingId`-Keyed Events

## Status

Accepted

## Context

`kart-notification-service`'s approved `ddd-model.md` requires `userId` as a field on every `NotificationAttempt` row, populated at creation from the triggering event — needed both to route the physical delivery (email/SMS/push address lookup) and to key the opt-out check against `NotificationPreference` (`userId`-keyed).

`event-design-agent`'s pass over this service's event-contract.md, cross-checked directly against each publisher's own already-approved `event-contract.md` payload shape (not invented independently), found that of the 13 events in this service's consumed scope (ADR-0003), only four carry `userId` directly: `OrderCreated`, `WishlistPriceAlertTriggered`, `UserRegistered`, `UserNotificationPreferenceUpdated`. The remaining nine carry no `userId` at all:

- `OrderConfirmed`, `OrderCancelled`, `OrderCompensationTriggered`, `OrderDelivered` (`kart-order-service`) — `orderId`-keyed only.
- `PaymentCompleted`, `PaymentFailed`, `RefundIssued` (`kart-payment-service`) — `orderId`-keyed only.
- `ShipmentDispatched` (`kart-shipping-service`) — `orderId`-keyed only.
- `DeliveryStatusUpdated` (`kart-delivery-tracking-service`) — `trackingId`-keyed only, no `orderId` at all.

None of `requirement-spec.md`, `edge-cases.md`, `architecture.md`, `ddd-model.md`, or `database-design.md` named a resolution mechanism for this before now — it was surfaced, not silently papered over, per this stage's escalation mandate.

Two options were considered:

1. **Add `userId` to every affected publisher's payload.** Rejected — this would be a breaking change to eight already-approved, signed-off `event-contract.md` files across four different services (`kart-order-service`, `kart-payment-service`, `kart-shipping-service`, `kart-delivery-tracking-service`), each of which would need to re-open its own closed design pass for a field none of *their* own domains need to publish. It also duplicates `userId` onto events whose own aggregates (a `PaymentIntent`, a `Shipment`) do not need it for their own domain logic.
2. **Notification maintains its own locally-denormalized `orderId -> userId` (and `trackingId -> orderId`) index, built from events it already consumes.** Chosen — this is the same "each service denormalizes what it needs to make its own decisions" pattern already established for this exact service (`architecture.md`'s Resolved Integration-Contract Question for `UserNotificationPreferenceUpdated`, itself citing ADR-0006's identical precedent for User Service's own denormalized Identity fields).

## Decision

`kart-notification-service` maintains a local, non-aggregate lookup projection — **`OrderUserIndex`** (`orderId -> userId`) — populated solely from consuming `OrderCreated` (which already carries both fields, and which Notification already consumes in its Tier 2 scope per ADR-0003).

Every `orderId`-keyed triggering event (`OrderConfirmed`, `OrderCancelled`, `OrderCompensationTriggered`, `OrderDelivered`, `PaymentCompleted`, `PaymentFailed`, `RefundIssued`, `ShipmentDispatched`) resolves `userId` via a lookup against `OrderUserIndex` before creating its `NotificationAttempt` row(s), instead of reading `userId` from its own payload.

`DeliveryStatusUpdated` (`trackingId`-keyed, no `orderId`) is resolved one hop further: Notification also maintains **`TrackingOrderIndex`** (`trackingId -> orderId`), populated from consuming `ShipmentDispatched` (which already carries both `orderId` and `trackingId`). `DeliveryStatusUpdated` resolves `orderId` via `TrackingOrderIndex`, then `userId` via `OrderUserIndex`, chaining both lookups.

**Ordering-race handling (no new mechanism invented):** RabbitMQ does not guarantee cross-routing-key delivery ordering, so a dependent event (e.g. `OrderConfirmed`) can in principle be consumed before the `OrderCreated` that seeds its `OrderUserIndex` row. This is treated as a transient condition, not a permanent failure: a lookup miss requeues the message onto that event's own already-modeled TTL-ladder retry (its existing `CriticalityTier` budget — no new retry mechanism), on the expectation `OrderCreated` will have been consumed by the time it is redelivered. If `OrderCreated` itself is permanently lost (exhausts its own retry budget and lands in its DLQ), every event depending on its `OrderUserIndex` row will, in turn, exhaust their own retry budgets and land `Failed` — a correct, already-modeled cascade surfaced through the existing DLQ/audit tooling (`database-design.md`'s `idx_notification_attempts_failed`), not a silent drop.

`OrderCreated`'s consumer-side retry tier is elevated from Tier 2 to **Tier 1 (5x, paged)** in `event-contract.md`, reflecting its new role as the resolution linchpin for eight of the thirteen consumed events, not only its own welcome/order-confirmation notification — losing it durably would cascade into lost notifications for every other event tied to that order, which is a materially different blast radius than losing any one order-lifecycle notification on its own.

## Consequences

- `ddd-model.md`, `database-design.md`, and `event-contract.md` for `kart-notification-service` are updated to add `OrderUserIndex`/`TrackingOrderIndex` as non-aggregate lookup projections (not new aggregate roots — neither has its own invariants or lifecycle beyond upsert-on-consume) and to route `userId` resolution through them for the eight/nine affected events.
- No other service's already-approved `event-contract.md`, `ddd-model.md`, or payload shape changes. `kart-order-service`, `kart-payment-service`, `kart-shipping-service`, and `kart-delivery-tracking-service` are unaffected.
- `OrderCreated`'s row in `kart-order-service/event-contract.md` should also be updated to list `kart-notification-service` as a consumer (a separate, already-flagged asymmetry this ADR's resolution now makes unambiguously blocking — see `docs/services/kart-notification-service/event-contract.md`'s own flagged note).
- `OrderUserIndex` and `TrackingOrderIndex` rows are retained for the same unbounded audit-trail lifetime as `notification_attempts` (no stated retention window exists upstream to prune them against) — consistent with this service's existing no-TTL, no-deletion posture for its write-side data.
