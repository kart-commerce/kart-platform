---
doc_type: architecture
service: kart-notification-service
status: pending-approval
generated_by: architecture-agent
source: docs/services/kart-notification-service/requirement-spec.md, docs/services/kart-notification-service/edge-cases.md, docs/services/kart-notification-service/design-decisions.md
---

# Architecture: kart-notification-service

## Boundary Rationale

`kart-notification-service` is the bounded context that answers "does the end user get told, on which channel, and did it work" — it owns channel selection, per-channel/per-category opt-out enforcement, send-attempt delivery, and the audit trail of every attempt. It does **not** own the business meaning of any triggering event (order state, payment state, price state) — it only reacts to those events' already-decided outcomes and is a pure translator from "something happened" to "the user was told."

Notification is architecturally unlike every other service profiled so far in two respects, both already established in the approved requirement-spec and carried forward here unchanged:

1. **No public API, consumer-only** (BRD §5.4; reaffirmed by `design-decisions.md`'s Communication Style decision). It has no inbound synchronous surface of any kind — everything it does is triggered by consuming an event off `ecommerce.events`.
2. **Broadest single fan-in consumer on its resolved scope** (ADR-0003): all `order.*`/`payment.*` routed events, plus `WishlistPriceAlertTriggered`, `UserRegistered`, `ShipmentDispatched`, and `DeliveryStatusUpdated`. This scope question was the requirement-spec's Q1 (blocking) and is fully closed by ADR-0003 — cited, not re-litigated, here.

Notification is **not** a participant in the Order Saga (BRD §12) — Order's saga only orchestrates Inventory, Payment, and Shipping as compensating steps. Nothing in the platform synchronously depends on Notification being up: it commits to the 99.9% secondary availability tier (requirement-spec §3/§6 Q5) precisely because of this absence, matching the same reasoning already applied to Offer and User. This is the defining boundary characteristic for its scaling/availability posture: Notification can degrade, queue up, or restart without blocking any other service's critical path, but a stalled Notification consumer does delay (never block) the user actually being told what happened.

## Dependencies

| Direction | Peer Service | Mechanism | Type | Notes |
|---|---|---|---|---|
| Inbound (consumed) | Order | `OrderCreated`, `OrderConfirmed`, `OrderCancelled`, `OrderCompensationTriggered`, `OrderDelivered` | **Async** | `order.*` wildcard binding (ADR-0003); `OrderDelivered` is Order's unified terminal event per [ADR-0005](../../adr/0005-unify-order-terminal-event.md); Tier 2 retry (3x, non-paged) per requirement-spec §3/§6 Q7 |
| Inbound (consumed) | Payment | `PaymentCompleted`, `PaymentFailed`, `RefundIssued` | **Async** | `payment.*` wildcard binding (ADR-0003); Tier 1 retry (5x + paged) — Notification's send-attempt retry budget inherits Payment's own money-moving criticality tier verbatim, not a Notification-invented scheme |
| Inbound (consumed) | Shipping | `ShipmentDispatched` | **Async** | Dedicated routing key outside the `order.*`/`payment.*` wildcard (ADR-0003 §2); Tier 2 retry |
| Inbound (consumed) | Delivery Tracking | `DeliveryStatusUpdated` | **Async** | Dedicated routing key (ADR-0003 §2); Tier 2 retry |
| Inbound (consumed) | Wishlist | `WishlistPriceAlertTriggered` | **Async** | Dedicated routing key (ADR-0003 §2); Tier 3 retry (2x, non-paged) |
| Inbound (consumed) | Identity | `UserRegistered` | **Async** | Dedicated routing key (ADR-0003 §2); Tier 2 retry; also consumed by User Service (see `kart-user-service` requirement-spec §5) — Notification and User both react to registration independently, no ordering dependency between them |
| Inbound (consumed) | User | `UserNotificationPreferenceUpdated` (new — see below) | **Async** | Resolves requirement-spec §6 Q3's explicitly-deferred "how populated" mechanism; Tier 3 retry (non-paged) — a lost/delayed preference-sync event risks a stale opt-out window (see Distributed-Monolith Risk), not a lost send |
| Outbound (published) | Analytics | `NotificationSent` (`userId`, `channel`, `status`) | **Async** | 1x, fire-and-forget audit-publish tier (BRD §10), unchanged and distinct from the tiered send-attempt retries above — this governs only the audit record, per requirement-spec §6 Q6 |

No synchronous inbound API and no synchronous outbound call to any other service. In particular, Notification does **not** synchronously call User Service to check opt-out preferences on every send (requirement-spec §6 Q3's explicit rejection of that design) — opt-out and channel-reachability data are read from Notification's own PostgreSQL store, kept current asynchronously (see below).

RabbitMQ topology (per `design-decisions.md`'s Communication Style decision): one topic-exchange consumer on `ecommerce.events`, bound to `order.*`, `payment.*`, plus dedicated routing keys for `wishlist.price-alert-triggered`, `identity.user-registered`, `shipping.shipment-dispatched`, `delivery-tracking.status-updated`, and `user.notification-preference-updated` (new binding needed for the event introduced below). This is the concrete topology-finalization the requirement-spec (§5) flagged as carried forward to this stage — now closed.

## Resolved Integration-Contract Question: Opt-Out / Channel-Reachability Data Sync (requirement-spec §6 Q3, deferred)

Requirement-spec §6 Q3 fixed the *what* (per-channel, per-category opt-out, owned and stored in Notification's own PostgreSQL store, checked before every send) and explicitly deferred the *how-it's-populated* mechanism to this stage: "a small dedicated Notification-owned API, vs. a new User→Notification sync event." A dedicated Notification-owned API is ruled out directly by this service's own no-public-API boundary (BRD §5.4; reaffirmed above) — adding one solely to receive preference writes would contradict the architectural property this spec and `design-decisions.md` both commit to elsewhere. That leaves the event option, which this doc resolves concretely:

- **Decision:** a new event, **`UserNotificationPreferenceUpdated`** (payload: `userId`, per-channel-per-category opt-out map, `appInstalled` boolean), published by **User Service** — preferences are User's bounded context (BRD §2.1 item 2, `kart-user-service` requirement-spec §2's `notificationOptIn` JSONB field) — and consumed by Notification to populate/refresh its own local opt-out and channel-reachability store. Naming follows the existing `UserAccountUpdated`/`UserProfileUpdated` convention (ADR-0006) rather than inventing a new verb pattern.
- **Why this also closes the channel-selection rule's open data-source question:** requirement-spec §6 Q2 (already resolved) selects `push` "whenever the recipient has an app-installed flag set on their profile," but never named where that flag lives. It is the same category of user-set signal as opt-out — both belong to User Service's profile/preference domain and both need to reach Notification asynchronously — so this doc carries the `appInstalled` flag on the same new event rather than inventing a second integration point for a structurally identical problem.
- **Boundary clarification (why this doesn't collide with User Service's existing `notificationOptIn`):** `kart-user-service`'s requirement-spec already models a coarser `notificationOptIn` per-channel boolean set as part of its own general "preferences" JSONB (BRD §2.1 item 2). That is User's own coarse-grained UI-facing toggle; Notification's per-channel-**per-category** opt-out (requirement-spec §6 Q3) is a finer-grained derived projection of it, owned by Notification for its own send-time decisions. `UserNotificationPreferenceUpdated` is the translation event between the two — User remains the single place a user actually sets a preference; Notification never treats its own copy as a second source of truth for what the user chose, only as the operational store it checks at send time (the same "denormalize what you need to decide" pattern ADR-0006 already applies to User's own copy of Identity's email/displayName).
- **Consequence for `kart-user-service`:** this is a new responsibility to add to `kart-user-service`'s own publish surface (parallel to how ADR-0006 required Identity to add `UserAccountUpdated`) — flagged here for that service's next docs pass, not silently assumed already in place.

## Distributed-Monolith Risk

**No synchronous coupling risk** — Notification has zero synchronous dependencies, inbound or outbound, on any other service, and nothing in the platform synchronously blocks on Notification. It can be deployed, scaled, restarted, or briefly down without stalling Order/Payment/Shipping's own critical paths.

Two risks worth naming explicitly rather than leaving implicit, both accepted trade-offs consistent with decisions already made upstream:

1. **Opt-out staleness window at the User→Notification boundary.** The domain invariant that opt-out "must never" be violated, "regardless of the triggering event's own criticality tier" (requirement-spec §4), is enforced against Notification's *local* copy of preference data, which is only as fresh as its last consumed `UserNotificationPreferenceUpdated` (this doc, above). A user who opts out and is sent a notification before that event is consumed and applied experiences a real (if narrow) violation of the stated invariant's intent — this is the identical trade-off `design-decisions.md`'s Caching Strategy decision already accepted for in-service staleness (why it rejected a cache with a TTL window), now recurring one hop further out at the cross-service sync boundary instead of inside a single process. **Accepted as-is**, on the same grounds already used for that decision (querying a synchronous source of truth on every send was explicitly rejected as a boundary violation in §6 Q3) — flagged here so it is a known, named trade-off rather than a silent gap, and so the DDD Agent sizes `UserNotificationPreferenceUpdated`'s consumption as Tier 3 (fast, non-paged, but not zero-latency).
2. **Broadest-fan-in operational risk, already mitigated, not newly introduced.** Notification's consumed scope (ADR-0003) makes it structurally the platform's highest-fan-in consumer; a spike in any one upstream producer's volume (a flash sale's `OrderCreated` burst, in particular) shares consumer capacity with every other event type unless isolated. This is not a *boundary* problem — it does not make Notification a distributed monolith with any other service — but it is a real scaling risk already fully addressed operationally (`edge-cases.md`: HPA autoscaling + per-criticality queue splitting; `design-decisions.md`: TTL-ladder retry per tier, per-channel bulkhead isolation). Restated here only to confirm the Architecture Agent finds no unmitigated version of this risk remaining, not to reopen it.

## Sign-off

- [ ] Reviewed by a human before the DDD Agent runs against this service
- [ ] Approved to proceed to DDD Agent
