---
doc_type: adr
status: accepted
---

# ADR-0003: Notification's Consumed-Event Scope

## Status

Accepted

## Context

`kart-requirements.md` §5.4 described Notification as consuming "almost every event in catalog," while §10's Event Catalog only listed it as a consumer on 3 rows (`OrderConfirmed`, `ShipmentDispatched`, `DeliveryStatusUpdated`). This materially changes Notification's load profile and RabbitMQ bindings, and `docs/services/README.md` tracked it as an open cross-service contradiction. `kart-notification-service`'s own docs correctly flagged this as a blocking open question (and were approved on that basis) — but the underlying BRD ambiguity itself was never resolved, only correctly not-silently-guessed.

## Decision

Notification consumes:

1. **All `order.*` and `payment.*` routed events** — this is the concrete, already-specified mechanism (§9's example RabbitMQ manifest binds `notification.queue` to exactly these two wildcard patterns), so it's used as the authoritative scope definition rather than the vaguer "almost every event" prose in §5.4. Concretely: `OrderCreated`, `OrderConfirmed`, `OrderCancelled`, `OrderCompensationTriggered`, `OrderDelivered`, `PaymentCompleted`, `PaymentFailed`, `RefundIssued`.
2. **Events whose own name states a customer-notification intent**, even outside those two namespaces: `WishlistPriceAlertTriggered` (the entire point of the event is to alert the user), `UserRegistered` (welcome email).
3. **`ShipmentDispatched` and `DeliveryStatusUpdated`**, already correctly named in §10 (shipping/tracking notifications).

Not in scope: `ReviewSubmitted`, `CouponRedeemed`, catalog/search events, admin/analytics-internal events — none of these are named with notification intent, and none fall under the `order.*`/`payment.*` wildcard. §10's Event Catalog in `kart-requirements.md` now lists Notification as a consumer on exactly the rows above; §5.4's Notification row was rewritten to state this resolved scope instead of "almost every event."

## Consequences

- Notification's RabbitMQ topology can be sized and load-tested against a concrete, enumerable event set instead of an open-ended one.
- If the org later wants Notification on `CouponRedeemed` or `ReviewSubmitted` too (e.g., "your coupon was used" or "thanks for your review" emails), that's a new, explicit product decision — not a re-reading of this ADR's scope.
- `kart-notification-service`'s `requirement-spec.md` should update its open question to cite this ADR as resolved, rather than leaving it as an escalated blocker.
