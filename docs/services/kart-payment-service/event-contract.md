---
doc_type: event-contract
service: kart-payment-service
status: approved
generated_by: event-design-agent
source: docs/services/kart-payment-service/ddd-model.md, docs/services/kart-payment-service/api-contract.yaml, docs/adr/0012-payment-chargeback-handling.md
---

# Event Contract: kart-payment-service

Exchange: `ecommerce.events` (per [kart-conventions.md](../../standards/kart-conventions.md)). Every consumer queue below gets its own DLQ per the reusable event standard (`event-standards.md`: "never a shared/global DLQ") — BRD §10's simplified shared `payment.dlq` label is expanded into one DLQ per event below, the same override `kart-offer-service/event-contract.md` already applied for its own BRD-simplified DLQ labels.

| Event | Routing Key | Published/Consumed | Key Fields | Retry | DLQ | Criticality Justification |
|---|---|---|---|---|---|---|
| `PaymentCompleted` | `payment.intent.completed` | Published (Order, Notification, Analytics) | `orderId`, `txnId` | 5x exponential | `payment.intent-completed.dlq`, paged on-call | Money-critical (BRD §10 footnote) — Order's Saga cannot correctly advance to `Confirmed` without eventually seeing this; a silently dropped `PaymentCompleted` leaves an order stuck indefinitely despite money having actually moved, the platform's worst class of silent failure |
| `PaymentFailed` | `payment.intent.failed` | Published (Order, Notification, Analytics) | `orderId`, `reason` | 5x exponential | `payment.intent-failed.dlq`, paged on-call | Same tier as `PaymentCompleted` — this is Order's Saga compensation *trigger* (BRD §12.2); a lost `PaymentFailed` leaves Order believing a charge is still in flight when it has already terminally failed, stalling compensation (Inventory release) indefinitely |
| `RefundIssued` | `payment.refund.issued` | Published (Order, Notification, Analytics) | `orderId`, `refundId`, `amount` | 5x exponential | `payment.refund-issued.dlq`, paged on-call | Money-critical per BRD §10 (gap closed by ADR-0007) — a lost `RefundIssued` means a customer was actually refunded but no downstream system (Order's state machine, Notification's customer-facing confirmation, Analytics' financial reporting) ever learns of it |
| `ChargebackReceived` | `payment.chargeback.received` | Published (Order, Notification, Analytics) | `orderId`, `paymentIntentId`, `chargebackId`, `amount`, `reason` | 5x exponential | `payment.chargeback-received.dlq`, paged on-call | **New** (ADR-0012) — same money-critical tier as its siblings above, deliberately: a lost `ChargebackReceived` means Order never holds/cancels the order or releases inventory for a charge the bank has already reversed, leaving Payment and Order's books permanently inconsistent with no automatic recovery path |
| `OrderCreated` | `order.order.created` | Consumed (from Order) | `orderId`, `userId`, `items`, `total` | — (consumer side) | — | N/A — Order owns retry/DLQ for its own publication (3x exponential, `order.dlq`, per BRD §10); Payment's own consumer-side idempotency (deriving `Idempotency-Key` from `(orderId, "charge")`, `ddd-model.md`) is what makes redelivery of this event safe regardless of Order's retry policy |

No new events beyond what requirement-spec.md/architecture.md already specified — unlike `kart-offer-service`'s DDD pass, this service's event set was already fully closed by the time Architecture/DDD ran (`ChargebackReceived` was the one new addition, already resolved via ADR-0012 before this stage began), so there is no additional catalogue gap to close here.

## Naming Convention Compliance

Every event name is `<Entity><PastTenseVerb>` (`event-standards.md`): `PaymentCompleted`, `PaymentFailed`, `RefundIssued`, `ChargebackReceived` all comply. Routing keys follow `service.entity.action` (`payment.intent.completed`, `payment.intent.failed`, `payment.refund.issued`, `payment.chargeback.received`) — `intent`/`refund`/`chargeback` as the entity segment, matching `ddd-model.md`'s aggregate/entity names (`PaymentIntent`, `Refund`, `ChargebackRecord`) rather than a generic `payment.*` catch-all, so routing keys stay self-describing as more Payment-owned entities are ever added.

## Retry Tier Justification (Why Every Event Here Is 5x/Paged, Not a Lower Tier)

Unlike `kart-offer-service`'s Coupon events (which stayed at the BRD's original 2x/no-paging tier — the actual double-charge/oversell guard lives in Order/Payment's own idempotency, not Coupon's, per that service's `event-contract.md`), every event Payment itself publishes sits at the platform's highest tier by design, not by default inheritance: each one is either the direct signal Order's Saga blocks on (`PaymentCompleted`/`PaymentFailed`) or a record of money that has already, irreversibly moved (`RefundIssued`, `ChargebackReceived`). There is no lower-criticality event in this service's own domain to contrast against — Payment has no equivalent of Offer's "just an Analytics-visibility signal" event, because everything it publishes is itself the money-moving fact, not a side-effect of one.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner
- [x] Approved
