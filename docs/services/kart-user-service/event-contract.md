---
doc_type: event-contract
service: kart-user-service
status: approved
generated_by: event-design-agent
source: docs/services/kart-user-service/ddd-model.md, docs/services/kart-user-service/design-decisions.md, docs/services/kart-user-service/architecture.md, docs/services/kart-user-service/database-design.md, docs/services/kart-user-service/api-contract.yaml, docs/adr/0006-identity-user-profile-sync-event.md, docs/adr/0016-user-gdpr-erasure-policy.md, docs/services/kart-identity-service/event-contract.md, docs/services/kart-notification-service/architecture.md
---

# Event Contract: kart-user-service

Exchange: `ecommerce.events` (RabbitMQ topic exchange, per [kart-conventions.md](../../standards/kart-conventions.md)). Every consumer queue gets its own DLQ per the reusable event standard (`event-standards.md`) — **never shared** across different event types or different consumer services.

## Published Events

| Event | Routing Key | Consumers | Payload (key fields) | Retry | DLQ (per consumer group) | Criticality Justification |
|---|---|---|---|---|---|---|
| `UserProfileUpdated` | `user.profile-updated` | Analytics | `userId` | 2x | `analytics.user-profile-updated.dlq` | Standard tier (BRD §10, ADR-0007/ADR-0008) — see below |
| `UserNotificationPreferenceUpdated` | `user.notification-preference-updated` | Notification | `userId`, `notificationOptIn` (per-channel), `appInstalled` | 2x | `notification.user-notification-preference-updated.dlq` | Tier 3 (standard, non-paged) — matches `kart-notification-service/architecture.md`'s own already-committed consumer-side tier exactly |
| `UserDataErased` | `user.data-erased` | Order, Notification, Analytics, Review, Recommendation, Wishlist, Identity | `userId`, `erasedAt` | 5x, exponential backoff, on-call paging on final DLQ landing | `order.user-data-erased.dlq`, `notification.user-data-erased.dlq`, `analytics.user-data-erased.dlq`, `review.user-data-erased.dlq`, `recommendation.user-data-erased.dlq`, `wishlist.user-data-erased.dlq`, `identity.user-data-erased.dlq` | **Compliance-critical tier** (ADR-0016 item 7) — see below |

### Retry-Tier Justification

- **`UserProfileUpdated` — 2x, no paging.** Matches BRD §10's own row (as completed by ADR-0007/ADR-0008). Analytics is the sole consumer, for reporting only — a lost delivery costs a stale metric, not a correctness gap anywhere else; `user_profiles`/`addresses` remain the durable source of truth regardless of delivery.
- **`UserNotificationPreferenceUpdated` — 2x, no paging.** Restated against actual risk, not copied blindly: a lost delivery leaves Notification's local opt-out copy stale, which `kart-notification-service/architecture.md` itself already names and accepts as a known trade-off ("Opt-out staleness window at the User→Notification boundary... accepted as-is") — this service's own retry tier is set to match, not to independently invent a different number Notification's own risk analysis didn't ask for.
- **`UserDataErased` — 5x, exponential backoff, paged on final DLQ landing.** Per ADR-0016 item 7's own explicit policy: "the same high-retry-budget/human-paging tier the platform already reserves for money-critical events... an erasure event silently swallowed by DLQ is a compliance failure, not a tolerable staleness window." Matches the exact tier `kart-identity-service/event-contract.md` (approved) already committed to on its own consumer side for this same event — this contract's publish-side retry count is set to the identical number rather than inventing a different one for the same event.

### Bulkhead Isolation — Per-Consumer-Group DLQs

`UserDataErased` fans out to seven independent consumer services (per ADR-0016's Consequences section, including Identity — added there when Identity's own Architecture stage surfaced its own PII gap). Each gets its own dedicated DLQ, never a shared `user.dlq` label, per `event-standards.md`'s "never shared" rule and the identical correction already made for other high-fan-out events in this platform (`kart-product-service/event-contract.md`'s per-consumer-group DLQs for `ProductCreated`/`ProductPriceChanged`). A DLQ failure for one consumer's compliance-critical redaction (e.g. Wishlist never implementing its handler) must page independently of whether every other consumer succeeded — a shared queue would conflate these.

## Consumed Events

| Event | Routing Key | Publisher | Payload (key fields) | Retry (this service's own consumer queue) | DLQ (this service's own consumer queue) | Notes |
|---|---|---|---|---|---|---|
| `UserRegistered` | `identity.user.registered` | `kart-identity-service` | `userId`, `email` | 3x | `user.user-registered.dlq` | Aggregate-creation trigger for `UserProfile` (ddd-model.md) — a permanently-lost delivery leaves no profile record for a real, registered account, matching `kart-identity-service/event-contract.md`'s own stated reasoning for why this event sits above the standard 2x tier. Retry count matches Identity's own publish-side tier exactly. |
| `UserAccountUpdated` | `identity.user-account.updated` | `kart-identity-service` | `userId`, `email`, `displayName`, `updatedAt` | 2x | `user.user-account-updated.dlq` | Reconciles `contactCopy`, apply-if-newer via `updatedAt` (ADR-0006; `kart-identity-service/event-contract.md`'s confirmed schema addition). Retry count matches Identity's own publish-side tier exactly. |

Both consumed events use upsert-by-`userId` as their idempotency mechanism (edge-cases.md "Duplicate/out-of-order `UserRegistered` delivery"; design-decisions.md's generalization of it to both events) — no separate dedup table.

## Naming-Convention Compliance

All three published events follow the `<Entity><PastTenseVerb>` convention (`event-standards.md`): `UserProfileUpdated`, `UserNotificationPreferenceUpdated`, `UserDataErased`. Routing keys use `user` as this service's own domain word, in the `<domain>.<event-kebab>` shape `kart-notification-service/architecture.md` already fixed exactly for `user.notification-preference-updated` — matched here rather than re-decided, and applied consistently to this service's other two published events (`user.profile-updated`, `user.data-erased`). No collision found against any event name already registered in this repo's other `event-contract.md` files (`kart-identity-service`, `kart-offer-service`, `kart-admin-service`, `kart-cart-service`, `kart-category-service`, `kart-analytics-service`, `kart-delivery-tracking-service`, `kart-product-service`).

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner
- [x] Approved
