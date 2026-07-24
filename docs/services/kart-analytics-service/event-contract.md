---
doc_type: event-contract
service: kart-analytics-service
status: approved
generated_by: event-design-agent
source: docs/services/kart-analytics-service/requirement-spec.md, docs/services/kart-analytics-service/edge-cases.md, docs/services/kart-analytics-service/design-decisions.md, docs/services/kart-analytics-service/architecture.md, docs/services/kart-analytics-service/database-design.md, docs/adr/0004-analytics-full-fanin-ingestion.md, docs/adr/0007-event-catalog-completeness.md, docs/adr/0008-event-catalog-completeness-round-2.md, docs/adr/0012-payment-chargeback-handling.md, docs/adr/0015-shipping-shipment-creation-failed-event.md, docs/adr/0016-user-gdpr-erasure-policy.md, docs/services/kart-offer-service/event-contract.md, docs/services/kart-admin-service/event-contract.md, docs/services/kart-cart-service/event-contract.md, docs/services/kart-category-service/event-contract.md, docs/services/kart-identity-service/event-contract.md, docs/services/kart-delivery-tracking-service/event-contract.md, docs/requirements/kart-requirements.md
---

# Event Contract: kart-analytics-service

## Pipeline Note (read before reviewing the tables below)

**Superseded note (corrected on this pass):** this section previously read "No `ddd-model.md` exists for this service," citing the same precedent recorded in `kart-admin-service/database-design.md`. `docs/services/kart-analytics-service/ddd-model.md` has since been authored (its own "Pipeline-order note" explicitly flags that this prose was stale) — corrected in place, the same way `database-design.md` already corrected its own identical stale note. `ddd-model.md` formalizes Analytics' shape as four aggregate roots (`IngestedEvent`, `DeadLetteredEvent`, `ReconciliationRun`, `PiiRedactionRecord`), fully consistent with the event catalog below — no rework was needed to reconcile the two documents.

`design-decisions.md`, `architecture.md`, `ddd-model.md`, and `database-design.md` are all now `status: approved`, internally consistent with the already-closed (`status: approved`) `requirement-spec.md`/`edge-cases.md`, with no open question left to re-litigate. This contract is derived directly from their already-decided content — full fan-in (ADR-0004), the D2 schema-registry/versioning scheme, the D5 retry/DLQ tier for Analytics' own write failures, and the concrete `analytics_dlq_events`/`analytics_raw_events` schema already built in `database-design.md` — rather than re-deciding anything.

Exchange/transport note: Analytics' own ingestion transport is **Kafka, consumer-only** (`design-decisions.md`, "Ingestion Transport & Communication Style" — Analytics was the first service migrated off RabbitMQ per BRD §15). Every event below is still *published* by its originating service primarily onto the platform's RabbitMQ topic exchange (`ecommerce.events`, per [kart-conventions.md](../../standards/kart-conventions.md)) during the strangler migration window, dual-published onto Kafka (`kart.analytics.<entity>` topics, per `kart-conventions.md`'s own naming example) for Analytics to consume (`event-standards.md`'s Kafka section: "dual-publish from the Outbox during transition"). The per-event **Retry / Delivery-to-Analytics DLQ** column below names each event's own broker-level tier as documented in `kart-requirements.md` §10 (as extended by ADR-0007/0008/0012/0015) or, where more authoritative, that event's own publishing service's already-authored `event-contract.md` — it is **each publisher's own contract to own and finalize**, not this document's; this document does not re-decide any of it. What genuinely *is* this document's own job — because no publisher's contract covers it — is Analytics' own **post-ingestion** write-failure handling (D5), covered in its own section below.

## Published Events

**None.** Analytics publishes zero events to the bus — `requirement-spec.md` §2/§5 and `architecture.md`'s Boundary Rationale both state this, verified against every Publisher column in `kart-requirements.md` §10's Event Catalog (Analytics never appears there). This is a deliberate consequence of Analytics' Generic-Subdomain boundary (read/reporting sink only, zero write authority over any other service's state, Domain Invariant #4) — not an oversight to fill in later.

## Consumed Events — Full Fan-In (ADR-0004)

**Resolved:** the requirement-spec's own former Open Question 1 (the "all events" vs. Event Catalog scope contradiction) is closed by [ADR-0004](../../adr/0004-analytics-full-fanin-ingestion.md) — Analytics consumes **every** published platform event, full fan-in, not a subset; `kart-requirements.md` §10 has since been corrected to list Analytics as a consumer on every row, and "every future new event automatically has Analytics as a consumer by default" (ADR-0004's own stated consequence). The table below is grouped by publishing bounded context and reproduces `architecture.md`'s own Dependencies table (audited fresh against every other service's own `architecture.md`/ADR during that stage) with payload/retry/DLQ detail added from `kart-requirements.md` §10 and the ADRs that extended it — restated here (not just cross-referenced) because per-event schema/retry/DLQ detail is this stage's actual deliverable, but sourced from the same audited list rather than re-derived independently, to avoid reintroducing the drift ADR-0004/0007/0008 already closed.

**Re-checked this pass against every publisher's own now-authored `event-contract.md`:** since this document was last drafted, three more publishers have authored their own approved-or-pending `event-contract.md` — [`kart-category-service`](../kart-category-service/event-contract.md), [`kart-identity-service`](../kart-identity-service/event-contract.md), and [`kart-delivery-tracking-service`](../kart-delivery-tracking-service/event-contract.md) — joining Offer/Admin/Cart as more-authoritative, later sources than the coarser BRD §10/ADR listing for the events they each publish. Per this document's own stated rule ("where a publisher has already authored its own `event-contract.md`, that document's value is treated as authoritative over the coarser BRD §10 / ADR listing"), `CategoryUpdated`, `UserRegistered`, `SessionCreated`, and `UserAccountUpdated` below have been updated to match those services' own contracts (expanded payload, per-event DLQ instead of a shared label); `DeliveryStatusUpdated`'s payload/retry/DLQ were independently re-confirmed unchanged against `kart-delivery-tracking-service`'s own contract.

### Order

**Correction against this document's earlier draft, applied the same way `kart-review-service/event-contract.md` already flagged for its own consumers:** all five Order lifecycle events below were previously listed at BRD §10's original 3x/shared-`order.dlq` tier. `kart-order-service/event-contract.md` (built after this table was last drafted) has since elevated all five to **5x exponential, paged on-call**, with a per-event DLQ (requirement-spec resolution #7 — "a stuck `OrderCreated`/`OrderConfirmed`/etc. blocks a downstream Saga step or correctness gate indefinitely, at least as severe as a stuck `PaymentCompleted`"). This table now cites that later, authoritative source rather than the superseded BRD figure.

| Event | Payload (key fields) | Retry / Delivery-to-Analytics DLQ | Source of truth |
|---|---|---|---|
| `OrderCreated` | `orderId, userId, items, total` | 5x exponential, paged on-call, `order.order-created.dlq` | `kart-order-service/event-contract.md` (approved) |
| `OrderConfirmed` | `orderId, address` | 5x exponential, paged on-call, `order.order-confirmed.dlq` | `kart-order-service/event-contract.md` (approved) |
| `OrderCancelled` | `orderId, reason` | 5x exponential, paged on-call, `order.order-cancelled.dlq` | `kart-order-service/event-contract.md` (approved) |
| `OrderCompensationTriggered` | `orderId, reason` | 5x exponential, paged on-call, `order.order-compensation-triggered.dlq` | `kart-order-service/event-contract.md` (approved) — supersedes ADR-0007's original 3x/shared-`order.dlq` assignment |
| `OrderDelivered` | `orderId, deliveredAt` | 5x exponential, paged on-call, `order.order-delivered.dlq` | `kart-order-service/event-contract.md` (approved; event introduced by ADR-0005) |

### Inventory

| Event | Payload (key fields) | Retry / Delivery-to-Analytics DLQ | Source of truth |
|---|---|---|---|
| `InventoryReserved` | `orderId, sku, qty` | 2x, `inventory.dlq` | BRD §10 |
| `InventoryReservationFailed` | `orderId, sku` | 2x, `inventory.dlq` | BRD §10 |
| `InventoryReleased` | `orderId, sku, qty` | 2x, `inventory.dlq` | ADR-0007 |
| `InventoryReplenished` | `sku, qtyAdded, warehouseId` | 2x, `inventory.dlq` | ADR-0007 |

### Payment

| Event | Payload (key fields) | Retry / Delivery-to-Analytics DLQ | Source of truth |
|---|---|---|---|
| `PaymentCompleted` | `orderId, txnId` | 5x (money-critical), `payment.dlq`, paged on-call | BRD §10 |
| `PaymentFailed` | `orderId, reason` | 5x, `payment.dlq`, paged on-call | BRD §10 |
| `RefundIssued` | `orderId, refundId, amount` | 5x, `payment.dlq`, paged on-call | ADR-0007 |
| `ChargebackReceived` | `orderId, paymentIntentId, chargebackId, amount, reason` | 5x, paged on-call, `payment.chargeback-received.dlq` | [ADR-0012](../../adr/0012-payment-chargeback-handling.md) — **status: accepted** (finalized during `kart-payment-service`'s own pipeline completion pass, which also finalized this event's concrete per-event DLQ name as `payment.chargeback-received.dlq` per that service's `event-contract.md`, superseding this table's earlier simplified BRD-style shared `payment.dlq` label) |

### Shipping / Delivery Tracking

| Event | Payload (key fields) | Retry / Delivery-to-Analytics DLQ | Source of truth |
|---|---|---|---|
| `ShipmentDispatched` | `orderId, carrier, trackingId` | 3x, `shipping.dlq` | BRD §10 |
| `ShipmentCreationFailed` | `orderId, reason` | 3x, `shipping.dlq` | [ADR-0015](../../adr/0015-shipping-shipment-creation-failed-event.md) — **status: accepted** |
| `DeliveryStatusUpdated` | `trackingId, status` | 3x, `tracking.dlq` | BRD §10, re-confirmed unchanged by [`kart-delivery-tracking-service/event-contract.md`](../kart-delivery-tracking-service/event-contract.md) (approved) — that service deliberately declined to expand this payload beyond `{trackingId, status}` (its own "Payload Resolution" section), so no change is needed here |

### Product / Review / Category

| Event | Payload (key fields) | Retry / Delivery-to-Analytics DLQ | Source of truth |
|---|---|---|---|
| `ProductCreated` | `sku, name, description, categoryId, brand, price, status, attributes` (grown from the original `sku, attributes` by [ADR-0018](../../adr/0018-search-catalog-signal-sourcing.md) once `kart-search-service` confirmed a need for the full snapshot; additive, Analytics' own consumption unaffected) | 3x, `catalog.dlq` (Analytics' own delivery queue; `kart-product-service/event-contract.md` now names this `analytics.product-created.dlq` per-consumer-group, not the shared label) | BRD §10; [ADR-0018](../../adr/0018-search-catalog-signal-sourcing.md) |
| `ProductPriceChanged` | `sku, oldPrice, newPrice` | 3x, `catalog.dlq` | BRD §10 (publisher corrected Pricing→Product by ADR-0008) |
| `ProductUpdated` | `sku, changedFields, occurredAt, name, description, categoryId, brand, status, attributes` (grown by [ADR-0018](../../adr/0018-search-catalog-signal-sourcing.md) alongside `ProductCreated`, for `kart-search-service`'s benefit; Analytics continues to read only `changedFields`/`occurredAt`) | Now specified: 3x, `analytics.product-updated.dlq` | `kart-product-service/event-contract.md`; [ADR-0018](../../adr/0018-search-catalog-signal-sourcing.md) |
| `ReviewSubmitted` | `orderId, sku, rating, reviewId, userId` (grown from BRD §10's original `orderId, sku, rating`; matches `kart-review-service/event-contract.md`'s own approved schema — Analytics' prior subset was a strict subset of the real payload, no wire-format conflict, just an unread superset of fields now added for completeness) | 2x, `review.review-submitted.dlq` | `kart-review-service/event-contract.md` (approved) — supersedes BRD §10's simplified shared `review.dlq` label |
| `ReviewUpdated` | `orderId, sku, oldRating, newRating` | **Confirmed** (no longer provisional): 2x, no paging, `review.review-updated.dlq` | `kart-review-service/event-contract.md` (approved) — that service's own event-contract.md explicitly flagged this row's earlier "Not yet specified"/provisional state as stale in Analytics' table and confirmed no actual incompatibility; this row now reflects the finalized tier and schema directly |
| `CategoryUpdated` | `categoryId, name, parentId, path, operation, occurredAt` | 3x, `category.category-updated.dlq` | [`kart-category-service/event-contract.md`](../kart-category-service/event-contract.md) (approved) — supersedes ADR-0008's coarser `categoryId, name` payload (Category's own "Payload Resolution" section grows it to describe subtree moves per its already-locked edge-case decision) and splits the shared `catalog.dlq` label into its own per-event queue |

### Offer

| Event | Payload (key fields) | Retry / Delivery-to-Analytics DLQ | Source of truth |
|---|---|---|---|
| `CouponRedeemed` | `code, orderId` | 2x, `offer.coupon-redeemed.dlq` | [`kart-offer-service/event-contract.md`](../kart-offer-service/event-contract.md) (**approved**) — supersedes BRD §10's simplified shared `coupon.dlq` label |
| `PriceQuoteIssued` | `quoteId, total, expiresAt` | 2x, `offer.quote-issued.dlq` | `kart-offer-service/event-contract.md` (approved). **Note:** the payload fields here (`quoteId, total, expiresAt`) supersede BRD §10's coarser `quoteId, sku, finalPrice` listing — Offer's own approved contract is the more authoritative, later source, not a contradiction to flag as blocking |
| `PromotionActivated` | `campaignId, window` | 2x, `offer.promotion-activated.dlq` | `kart-offer-service/event-contract.md` (approved). Same payload-field supersession note as `PriceQuoteIssued` above (BRD §10 listed `campaignId, sku, discount`) |
| `PromotionDeactivated` | `campaignId` | 2x, `offer.promotion-deactivated.dlq` | `kart-offer-service/event-contract.md` (approved) — not in BRD §10 at all; symmetric counterpart to `PromotionActivated` |

### User / Identity

| Event | Payload (key fields) | Retry / Delivery-to-Analytics DLQ | Source of truth |
|---|---|---|---|
| `UserProfileUpdated` | `userId, changedFields` | 2x, `user.dlq` | ADR-0008 |
| `UserDataErased` | `userId, erasedAt` | 5x exponential backoff, paged on final DLQ landing (compliance-critical tier), `analytics.user-data-erased.dlq` | [ADR-0016](../../adr/0016-user-gdpr-erasure-policy.md) item 7 — **status: accepted**. `kart-user-service/event-contract.md` (approved) has since finalized the per-consumer DLQ name — Analytics gets its own dedicated `analytics.user-data-erased.dlq`, never a shared queue with the other six consumers of this event (`event-standards.md`'s "never shared" rule) |
| `UserRegistered` | `userId, email` | 3x, `identity.user-registered.dlq` | [`kart-identity-service/event-contract.md`](../kart-identity-service/event-contract.md) (approved) — supersedes ADR-0007's shared `identity.dlq` label with a per-event queue; payload unchanged |
| `SessionCreated` | `userId, sessionId` | 2x, `identity.session-created.dlq` | `kart-identity-service/event-contract.md` (approved) — supersedes ADR-0007's shared `identity.dlq` label with a per-event queue; payload unchanged |
| `UserAccountUpdated` | `userId, email, displayName, updatedAt` | 2x, `identity.user-account-updated.dlq` | `kart-identity-service/event-contract.md` (approved) — supersedes ADR-0006/ADR-0008: adds the `updatedAt` field (Identity's own "Schema Finalization" decision, enabling last-write-wins ordering) and splits the shared `identity.dlq` label into its own per-event queue |

### Notification / Cart / Wishlist / Admin

| Event | Payload (key fields) | Retry / Delivery-to-Analytics DLQ | Source of truth |
|---|---|---|---|
| `NotificationSent` | `userId, channel, status` | 1x (fire-and-forget audit), `notification.dlq` | BRD §10 |
| `CartCheckedOut` | `cartId, userId, items` | 2x, `cart.dlq` | [`kart-cart-service/event-contract.md`](../kart-cart-service/event-contract.md) (approved) — confirms, does not change, BRD §10/ADR-0007's value |
| `WishlistPriceAlertTriggered` | `userId, sku, oldPrice, newPrice` | 2x, `wishlist.dlq` | ADR-0007 |
| `AdminActionPerformed` | `adminId, action, entityId` | 1x (fire-and-forget audit), `admin.admin-action-performed.dlq` | [`kart-admin-service/event-contract.md`](../kart-admin-service/event-contract.md) (pending-approval) — supersedes ADR-0007's simplified shared `admin.dlq` label, per that service's own "never shared" correction |

**Deliberately excluded (no phantom edge):** `UserNotificationPreferenceUpdated` (User → Notification, per `kart-notification-service/architecture.md`) is **not** listed above. Neither that document, `kart-user-service/architecture.md`, nor any ADR names Analytics as a confirmed consumer of it yet — `architecture.md`'s own "Full Fan-In Completeness Check" already declined to add it as a confirmed edge for the same reason. If a future pass on either of those services' docs confirms Analytics as a consumer, this table should pick it up then, not before.

## Naming-Convention Compliance

Every event name above follows the `<Entity><PastTenseVerb>` convention (`event-standards.md`) — no anomaly found across all 35 rows (e.g. `OrderCompensationTriggered` = Entity `OrderCompensation` + `Triggered`; `ShipmentCreationFailed` = Entity `ShipmentCreation` + `Failed`; `UserDataErased` = Entity `UserData` + `Erased`). This check is Analytics' own responsibility to *confirm* as a consumer, not to *enforce* — each event's naming compliance is actually owned by its publisher's own event-contract.md; no collision with any name already registered in this repo's other `event-contract.md` files was found.

Routing keys (`service.entity.action`) and DLQ names above are each publisher's own to define; where a publisher has already authored its own `event-contract.md` (Offer, Admin, Cart), that document's value is treated as authoritative over the coarser BRD §10 / ADR listing, per the notes in the tables above.

## Analytics' Own Consumer-Side Retry/DLQ — Post-Ingestion Write-Failure Handling (D5)

This is the one genuinely new retry/DLQ contract this document is responsible for defining, because no publisher's own contract covers what happens *after* Analytics has already successfully received an event and then fails to persist it.

| Failure point | Retry | Park mechanism (DLQ) | Criticality tier |
|---|---|---|---|
| Any consumed event (all 35 above, uniformly) fails to write to `analytics_raw_events` (warehouse-layer persistence failure), **or** fails schema-registry validation / tolerant-reader parsing (`edge-cases.md`, "Schema Evolution") | 3x exponential backoff | `analytics.dlq` (backed by the `analytics_dlq_events` table, `database-design.md`) | Standard business-event tier — not `Payment*`'s 5x/paged, not `NotificationSent`'s 1x/fire-and-forget |

- **Why this tier, not a higher or lower one (restated from requirement-spec §6 D5 / `design-decisions.md`, not re-derived):** a warehouse write failure is not money-critical the way `PaymentCompleted` is — nothing else on the platform blocks synchronously on it, and Domain Invariant #4 guarantees it can never stall or backpressure any upstream publisher. But it is not pure fire-and-forget audit either: every one of D4a's ten enumerated dashboards/funnels ultimately depends on the write eventually landing. 3x-then-park matches the platform's existing "standard business event" tier (`OrderCreated`, `ProductCreated`), rather than either extreme.
- **Uniform across every event type, including the two compliance/money-adjacent ones above.** `architecture.md`'s "Non-Functional Targets Proposed by This Stage" section already settles this explicitly for `UserDataErased`: its *upstream* publish-side tier is compliance-critical (5x, paged — see the table above), but that governs redelivery *to* Analytics, not what Analytics does once it already has the event; Analytics' own D5 handling stays uniform. The same reasoning applies symmetrically to `ChargebackReceived`/`RefundIssued`/`PaymentCompleted`: their money-critical *upstream* tier is a delivery-to-Analytics concern, not Analytics' own post-ingestion write-failure tier.
- **Consumer offset/commit semantics:** the offset for a Kafka-delivered event is only committed after a successful `analytics_raw_events` write **or** a successful hand-off to `analytics.dlq` — never left uncommitted (Domain Invariant #4). A scheduled reprocessor drains `analytics.dlq` using the same replay tooling as the BRD's own 30-day reprocessing scenario (§14).

### Naming-convention and "never-shared" compliance for `analytics.dlq`

- **Naming:** `analytics.dlq` follows the same per-domain, dot-suffix `.dlq` naming convention already used platform-wide (`order.dlq`, `catalog.dlq`, `admin.admin-action-performed.dlq`) — compliant, not a departure.
- **Does a single DLQ for all 35 consumed event types violate `event-standards.md`'s "every consumer queue has its own DLQ — never a shared/global DLQ" rule?** No, for two reasons specific to what this DLQ actually is:
  1. That rule sits under `event-standards.md`'s `## RabbitMQ (default)` section, governing RabbitMQ *consumer queue* topology — it exists to stop two different *consuming services'* redelivery failures from comingling in one queue (exactly the violation `kart-admin-service`'s and `kart-offer-service`'s own event-contracts corrected, where a single shared BRD-assigned DLQ label spanned *multiple event types published by the same service*, consumed by potentially different downstream services). `analytics.dlq` has exactly **one** consumer — Analytics itself — for exactly **one** failure category — "this service's own attempt to persist an already-received event failed." There is no second consuming service whose failures could ever land in `analytics.dlq`; the sharing the standard forbids (comingling across different consumers) cannot occur here by construction.
  2. `analytics.dlq` is not a broker-level redelivery queue at all — per `database-design.md`, it is the `analytics_dlq_events` **application/database table** downstream of Analytics' own Kafka consumer group, carrying an `event_type` column that already gives full per-event-type triage visibility without needing 34 separate physical DLQs. Splitting it by event type would not change the remediation path (the same scheduled reprocessor drains all of it) and would only fragment an already-homogeneous failure mode (warehouse write failure / unparseable payload) across 34 tables for no operational benefit — the opposite of the offer/admin precedent, where the *publishers'* per-event DLQs genuinely did need separating because they served materially different criticality tiers and, in Cart's/Offer's case, different downstream consumers.
- This is a resolved design point, not an escalation: it does not contradict `requirement-spec.md` §6 D5, `design-decisions.md`'s Resilience Pattern decision, or `database-design.md`'s already-built single-table schema — all three remain correct as written.

## Schema Versioning / Compliance Check (D2 — cited, not re-decided)

The requirement-spec's former Open Question 2 (schema versioning/evolution policy) and the Schema Evolution edge case's escalated sub-item (concrete registry/serialization format) are both already closed by requirement-spec.md §6 D2 / `design-decisions.md`'s "Serialization Format & Schema Governance" decision: a Confluent-compatible schema registry, Avro payloads, `BACKWARD` compatibility mode as the enforcement gate at publish time, the registry-assigned schema ID as the wire-format version pointer (no separate hand-maintained version field), and a human-readable `MAJOR.MINOR` label in registry subject metadata (`MINOR` = additive-only, compatible in place; `MAJOR` = breaking, new topic/namespace + dual-publish window). This document does not re-decide any of that; the only thing worth stating here, as this stage's own responsibility, is that **naming-convention/schema compliance for every event above is a registry-enforced platform concern, not a per-event manual check this contract needs to repeat row-by-row** — a publisher's schema change is rejected at publish time if it isn't `BACKWARD`-compatible, before it ever reaches Analytics' consumer.

## PII / Redaction Cross-Reference

`database-design.md` already closes `architecture.md`'s carried-forward gap on `UserDataErased` (redact-in-place on `analytics_raw_events`, not hard-delete or tag-only) — no event-contract impact: `UserDataErased`'s own delivery-to-Analytics retry/DLQ tier (table above) and Analytics' own D5 write-failure handling are both unaffected by how the redaction sweep itself is implemented downstream of a successful ingest.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner
- [x] Approved
