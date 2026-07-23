---
doc_type: event-contract
service: kart-notification-service
status: approved
generated_by: event-design-agent
source: docs/services/kart-notification-service/requirement-spec.md, docs/services/kart-notification-service/edge-cases.md, docs/services/kart-notification-service/design-decisions.md, docs/services/kart-notification-service/architecture.md, docs/services/kart-notification-service/ddd-model.md, docs/services/kart-notification-service/database-design.md, docs/adr/0003-notification-consumed-event-scope.md, docs/adr/0020-notification-userid-resolution.md, docs/services/kart-order-service/event-contract.md, docs/services/kart-payment-service/event-contract.md, docs/services/kart-shipping-service/event-contract.md, docs/services/kart-delivery-tracking-service/event-contract.md, docs/services/kart-wishlist-service/event-contract.md, docs/services/kart-identity-service/event-contract.md, docs/services/kart-user-service/event-contract.md
---

# Event Contract: kart-notification-service

Exchange: `ecommerce.events` (RabbitMQ topic exchange, per [kart-conventions.md](../../standards/kart-conventions.md)). This is the platform's broadest single fan-in consumer (ADR-0003, `architecture.md` Boundary Rationale item 2) — one topic-exchange consumer bound to `order.*`, `payment.*`, plus dedicated routing keys for `WishlistPriceAlertTriggered`, `UserRegistered`, `ShipmentDispatched`, `DeliveryStatusUpdated`, and `UserNotificationPreferenceUpdated` (`design-decisions.md`'s Communication Style decision; `architecture.md` Dependencies table). Every consumer queue below gets its own DLQ per the reusable event standard (`event-standards.md`: "never a shared/global DLQ") — `design-decisions.md`'s TTL-ladder decision names a single `notification.dlq` label for send-attempt terminal failures; that label is expanded here into one DLQ per consumed event, the same expansion `kart-shipping-service/event-contract.md`, `kart-payment-service/event-contract.md`, and `kart-order-service/event-contract.md` already applied to their own BRD-simplified shared DLQ labels.

The retry counts below are **Notification's own consumer-side send-attempt retry**, tiered by criticality per `ddd-model.md`'s `CriticalityTier` value object and `design-decisions.md`'s TTL-ladder decision (Tier 1: 5x + paged; Tier 2: 3x, non-paged; Tier 3: 2x, non-paged) — inherited verbatim from each triggering event's own already-catalogued tier (requirement-spec §6 Q7), not independently re-derived per event here. This is a materially different policy from each publisher's own publish-side retry/DLQ (listed below for traceability only, per the same convention `kart-shipping-service/event-contract.md` uses for `OrderConfirmed`'s consumption).

## Consumed — Tier 1 (Money-Moving, 5x + Paged)

| Event | Routing Key (per publisher's own approved event-contract.md) | Publisher | Payload (key fields) | Notification's Consumer Retry | Notification's Consumer DLQ | Publisher's Own Retry/DLQ (traceability only) |
|---|---|---|---|---|---|---|
| `PaymentCompleted` | `payment.intent.completed` | `kart-payment-service` | `orderId`, `txnId` | 5x + paged on-call | `notification.payment-completed.dlq` | 5x exponential, paged, `payment.intent-completed.dlq` |
| `PaymentFailed` | `payment.intent.failed` | `kart-payment-service` | `orderId`, `reason` | 5x + paged on-call | `notification.payment-failed.dlq` | 5x exponential, paged, `payment.intent-failed.dlq` |
| `RefundIssued` | `payment.refund.issued` | `kart-payment-service` | `orderId`, `refundId`, `amount` | 5x + paged on-call | `notification.refund-issued.dlq` | 5x exponential, paged, `payment.refund-issued.dlq` |
| `OrderCreated` | `order.order.created` | `kart-order-service` | `orderId`, `userId`, `items`, `total` | 5x + paged on-call (elevated from Tier 2, ADR-0020) | `notification.order-created.dlq` | 5x exponential, paged, `order.order-created.dlq` |

**Justification:** these are the platform's money-moving events (`kart-conventions.md`'s Money-Moving Criticality rule; `kart-payment-service/event-contract.md`'s own retry-tier justification: "everything it publishes is itself the money-moving fact"). Notification's send-attempt retry budget inherits Payment's own tier verbatim (requirement-spec §6 Q7) — a customer who paid, was refused, or was refunded is owed a timely notice of that fact; losing this send silently is a worse failure than losing an informational one, hence paging on final failure even though the underlying financial record (Payment's own `payment_intents`/`refunds` tables) remains correct regardless of whether the notification itself ever lands.

`OrderCreated` is elevated here from its BRD-inherited Tier 2 to Tier 1, **not** because its own welcome/order-received notification became more money-critical, but because ADR-0020 makes it the sole seed for `order_user_index` — the `userId`-resolution linchpin seven other consumed events (`OrderConfirmed`, `OrderCancelled`, `OrderCompensationTriggered`, `OrderDelivered`, `PaymentCompleted`, `PaymentFailed`, `RefundIssued`) depend on. Losing it durably (exhausting even Tier 2's 3x budget) would cascade into unresolvable `userId` lookups — and therefore lost notifications — for every other event tied to that order, a materially larger blast radius than losing any single order-lifecycle notification on its own.

## Consumed — Tier 2 (Order/Identity/Fulfillment Lifecycle, 3x, Non-Paged)

| Event | Routing Key (per publisher's own approved event-contract.md) | Publisher | Payload (key fields) | Notification's Consumer Retry | Notification's Consumer DLQ | Publisher's Own Retry/DLQ (traceability only) |
|---|---|---|---|---|---|---|
| `OrderConfirmed` | `order.order.confirmed` | `kart-order-service` | `orderId`, `address` | 3x | `notification.order-confirmed.dlq` | 5x exponential, paged, `order.order-confirmed.dlq` |
| `OrderCancelled` | `order.order.cancelled` | `kart-order-service` | `orderId`, `reason` | 3x | `notification.order-cancelled.dlq` | 5x exponential, paged, `order.order-cancelled.dlq` |
| `OrderCompensationTriggered` | `order.order.compensation-triggered` | `kart-order-service` | `orderId`, `reason` | 3x | `notification.order-compensation-triggered.dlq` | 5x exponential, paged, `order.order-compensation-triggered.dlq` |
| `OrderDelivered` | `order.order.delivered` | `kart-order-service` | `orderId`, `deliveredAt` | 3x | `notification.order-delivered.dlq` | 5x exponential, paged, `order.order-delivered.dlq` |
| `ShipmentDispatched` | `shipping.shipment.dispatched` | `kart-shipping-service` | `orderId`, `carrier`, `trackingId` | 3x | `notification.shipment-dispatched.dlq` | 3x, `shipping.shipment-dispatched.dlq` |
| `DeliveryStatusUpdated` | `tracking.delivery-status.updated` | `kart-delivery-tracking-service` | `trackingId`, `status` | 3x | `notification.delivery-status-updated.dlq` | 3x, `tracking.dlq` |
| `UserRegistered` | `identity.user.registered` | `kart-identity-service` | `userId`, `email` | 3x | `notification.user-registered.dlq` | 3x, `identity.user-registered.dlq` |

**Justification:** none of these gate Order's Saga from Notification's own perspective (they are consumed only to *tell* the user something already decided elsewhere), so Notification's own send-attempt retry does not need to match Order's/Payment's elevated 5x-paged publish-side tier for its own events — it reuses the platform's standard business-event tier (requirement-spec §6 Q7's Tier 2), consistent with how `kart-shipping-service/event-contract.md` reasons about its own standard-tier events. A lost send here delays a customer-facing notice (order confirmation, cancellation, shipment/tracking update, welcome email) — real, but recoverable via DLQ inspection/replay (`notification_attempts` still records `Failed`, per `database-design.md`), not a financial or oversell risk.

## Consumed — Tier 3 (Catalog/Preference-Sync, 2x, Non-Paged)

| Event | Routing Key (per publisher's own approved event-contract.md) | Publisher | Payload (key fields) | Notification's Consumer Retry | Notification's Consumer DLQ | Publisher's Own Retry/DLQ (traceability only) |
|---|---|---|---|---|---|---|
| `WishlistPriceAlertTriggered` | `wishlist.price-alert.triggered` | `kart-wishlist-service` | `userId`, `sku`, `oldPrice`, `newPrice` | 2x | `notification.wishlist-price-alert-triggered.dlq` | 2x, `notification.wishlist-price-alert-triggered.dlq` (already fixed by `kart-wishlist-service/event-contract.md`'s own per-consumer-group DLQ split — matched here, not renamed) |
| `UserNotificationPreferenceUpdated` | `user.notification-preference-updated` | `kart-user-service` | `userId`, `notificationOptIn` (per-channel), `appInstalled` | 2x | `notification.user-notification-preference-updated.dlq` | 2x, `notification.user-notification-preference-updated.dlq` (already fixed by `kart-user-service/event-contract.md`'s own per-consumer-group DLQ split — matched here, not renamed) |

**Justification:** lowest-stakes tier — a lost `WishlistPriceAlertTriggered` send costs one missed price-drop notice (a UX/engagement miss, per `kart-wishlist-service/event-contract.md`'s own retry-tier reasoning), and a lost `UserNotificationPreferenceUpdated` consumption leaves Notification's local `NotificationPreference` projection stale until the next successful publish — an already-named, accepted trade-off (`architecture.md`'s Distributed-Monolith Risk #1: "Opt-out staleness window... accepted as-is"), not a new risk this contract introduces. `kart-user-service/event-contract.md` independently confirms this exact 2x/non-paged tier and DLQ name on its own publish side, so no cross-document renumbering was needed for this row.

## Consumer Cross-Check Against Each Publisher's Own `event-contract.md`

Twelve of the thirteen consumed events above are confirmed, both directions, against the owning service's own already-approved `event-contract.md` Consumers column: `OrderConfirmed`, `OrderCancelled`, `OrderCompensationTriggered`, `OrderDelivered` (`kart-order-service`), `PaymentCompleted`/`PaymentFailed`/`RefundIssued` (`kart-payment-service`), `ShipmentDispatched` (`kart-shipping-service`), `DeliveryStatusUpdated` (`kart-delivery-tracking-service`), `WishlistPriceAlertTriggered` (`kart-wishlist-service`), `UserRegistered` (`kart-identity-service`), and `UserNotificationPreferenceUpdated` (`kart-user-service`) all list Notification by name.

**One asymmetry found — fixed directly, not left as a follow-up.** `kart-order-service/event-contract.md`'s `OrderCreated` row listed its Consumers as "Payment, Analytics" only — Notification was not named there, even though ADR-0003 (the authoritative resolution of Notification's consumed-event scope), this service's own `requirement-spec.md` §2/§5, `architecture.md`'s Dependencies table, and `ddd-model.md`'s "Domain events (consumed)" list all independently and consistently include `OrderCreated` in Notification's scope. ADR-0020 makes this omission unambiguously load-bearing (not cosmetic) — `OrderCreated` is now the sole seed for `order_user_index`, the `userId`-resolution mechanism seven other consumed events depend on — so, unlike the precedent `kart-wishlist-service/event-contract.md` sets for its own analogous (genuinely cosmetic) `ProductDiscontinued`-consumer-list asymmetry against `kart-product-service`, this asymmetry is corrected directly in `kart-order-service/event-contract.md` as part of this same pass, not deferred.

## Resolved: `userId` Absent From Most Consumed Events' Payloads (ADR-0020)

Checked directly against each payload's actual, publisher-approved shape (not invented independently, per this stage's mandate): `ddd-model.md`'s `NotificationAttempt` aggregate requires `userId` as a field, populated at creation from the triggering event. Of the 13 consumed events, only four carry `userId` directly in their payload as published (`OrderCreated`, `WishlistPriceAlertTriggered`, `UserRegistered`, `UserNotificationPreferenceUpdated`). The remaining nine — `OrderConfirmed`, `OrderCancelled`, `OrderCompensationTriggered`, `OrderDelivered` (`orderId`/`reason`/`deliveredAt` only), `PaymentCompleted`, `PaymentFailed`, `RefundIssued` (`orderId`-keyed only), `ShipmentDispatched` (`orderId`-keyed), and `DeliveryStatusUpdated` (`trackingId`-keyed, no `orderId` at all) — carry no `userId` field at all in their publisher-approved payload.

This was a genuine, not-previously-surfaced cross-document gap when first found in this pass. **Resolved by ADR-0020**, not by adding `userId` to any of the eight other services' already-approved payloads: Notification maintains its own `order_user_index` (`orderId -> userId`, seeded from `OrderCreated`) and `tracking_order_index` (`trackingId -> orderId`, seeded from `ShipmentDispatched`), both added to `ddd-model.md` (Lookup Projections section) and `database-design.md` this same pass. `OrderCreated`'s own consumer-side tier is elevated to Tier 1 above as a direct consequence (it is now the resolution linchpin, not just its own notification trigger). This does not change any other event's routing key, retry count, or DLQ name — only how `userId` is populated at `NotificationAttempt` creation time.

## Routing-Key Correction Against `architecture.md`'s Pre-Publisher-Stage Guesses

`architecture.md`'s Dependencies table and RabbitMQ topology paragraph name provisional dedicated routing keys — `wishlist.price-alert-triggered`, `identity.user-registered`, `shipping.shipment-dispatched`, `delivery-tracking.status-updated` — written before four of those five publishers had run their own Event Design stage. Their own now-approved `event-contract.md` files are the authoritative source for the actual wire routing key, and three of the four differ in shape from `architecture.md`'s guess (all use the `service.entity.action` three-segment convention, not the two-segment `domain.event-kebab` shape `architecture.md` guessed):

- `wishlist.price-alert.triggered` (not `wishlist.price-alert-triggered`) — per `kart-wishlist-service/event-contract.md`.
- `identity.user.registered` (not `identity.user-registered`) — per `kart-identity-service/event-contract.md`.
- `shipping.shipment.dispatched` (not `shipping.shipment-dispatched`) — per `kart-shipping-service/event-contract.md`.
- `tracking.delivery-status.updated` (not `delivery-tracking.status-updated`) — per `kart-delivery-tracking-service/event-contract.md`, which also uses `tracking` (not `delivery-tracking`) as its own domain word.

The fifth, `user.notification-preference-updated`, matches `architecture.md`'s guess exactly and is independently confirmed unchanged by `kart-user-service/event-contract.md`'s own text ("the `<domain>.<event-kebab>` shape `kart-notification-service/architecture.md` already fixed exactly ... matched here, not re-decided"). This contract's RabbitMQ bindings use the four corrected keys above plus the fifth as originally specified — `architecture.md` itself is not edited (out of this stage's remit), but its routing-key guesses are superseded here by each publisher's own authoritative, later-finalized contract, the same precedent `kart-delivery-tracking-service/event-contract.md` sets for its own `ShipmentDispatched`-consumption DLQ correction.

## Published

| Event | Routing Key | Consumer(s) | Key Fields | Retry | DLQ | Criticality Justification |
|---|---|---|---|---|---|---|
| `NotificationSent` | `notification.notification.sent` | Analytics | `userId`, `channel`, `status` | 1x, fire-and-forget | None (no DLQ) | Already decided, not re-litigated (requirement-spec §6 Q6, `architecture.md`, `database-design.md`'s "No Transactional Outbox" section): this event publishes only the audit record *after* a send attempt has already concluded via one of the tiered consumer paths above — the durable, correct outcome is `notification_attempts.status`, committed to PostgreSQL directly, regardless of whether this publish ever succeeds. Losing it delays Analytics' visibility into an already-resolved outcome, never the user-facing delivery itself, so no retry/DLQ machinery is warranted for this one outbound event. |

Routing key follows `service.entity.action` (`kart-conventions.md`), using `notification` as both domain word and entity segment — matching `kart-order-service/event-contract.md`'s and `kart-payment-service/event-contract.md`'s own precedent of a same-name entity segment for a service's principal self-owned event (`order.order.created`, `payment.intent.completed`).

No new events beyond what `ddd-model.md`'s "Domain events (published)" section already names — `ddd-model.md` itself confirms no additional internal-only event was required (`NotificationSent`'s own `status` field already carries the outcome distinction a separate suppressed/failed event would otherwise exist to communicate).

## Naming Convention Compliance

`event-standards.md`: event name is `<Entity><PastTenseVerb>`. `NotificationSent` (`Notification` + `Sent`) complies directly — this is the BRD-fixed name (§10), unchanged here. All 13 consumed events are owned and named by their respective publishers, checked for compliance in each publisher's own `event-contract.md` (already confirmed there, not re-derived here): `OrderCreated`/`OrderConfirmed`/`OrderCancelled`/`OrderDelivered`, `PaymentCompleted`/`PaymentFailed`, `RefundIssued`, `ShipmentDispatched`, `DeliveryStatusUpdated`, `WishlistPriceAlertTriggered`, `UserRegistered`, `UserNotificationPreferenceUpdated` all comply; `OrderCompensationTriggered` is the one inherited compound-verb-phrase exception already accepted at `kart-order-service/event-contract.md`'s own naming-compliance section, not re-litigated here.

No naming collision found against any event name already registered in this repo's other `event-contract.md` files (`kart-order-service`, `kart-payment-service`, `kart-shipping-service`, `kart-delivery-tracking-service`, `kart-wishlist-service`, `kart-identity-service`, `kart-user-service`, `kart-offer-service`, `kart-admin-service`, `kart-cart-service`, `kart-category-service`, `kart-product-service`, `kart-analytics-service`) — `NotificationSent` is the only event this service itself publishes, and it appears nowhere else in the catalog as a name owned by another service.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner
- [x] Approved
