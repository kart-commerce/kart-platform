---
doc_type: requirement-spec
service: kart-notification-service
status: approved
generated_by: requirement-agent
source: docs/requirements/kart-requirements.md
---

# Requirement Spec: kart-notification-service

## 1. Scope

Covers the single BRD service **Notification Service** (BRD §2.1 item 15): "Email/SMS/push fan-out." No service merge; ADR-0003 applies (it resolves this service's consumed-event scope — see §2 and §6 Q1).

Like Identity, Notification gets no dedicated deep-dive section (§5.1–5.3 only cover Order/Inventory/Payment) — it appears as one condensed row in §5.4, plus scattered mentions in the Service Boundary Diagram (§5.5), the RabbitMQ topology example (§9), the Event Catalog (§10), RabbitMQ Limitations (§14), and the Kafka Migration section (§15).

Notification is architecturally distinct from every other service profiled so far: it has **no public API** (§5.4: "consumer only, no public API") and is one of the platform's highest-fan-in consumers — its consumed-event scope was a BRD self-contradiction at the time of the first pass of this spec (§5.4 said "almost every event in catalog" while §10 named only 3 rows); this was resolved by **ADR-0003** (`docs/adr/0003-notification-consumed-event-scope.md`) and the BRD's own §5.4/§10 text was subsequently updated to state the resolved scope directly. This spec now draws on that resolved scope rather than the original ambiguous prose.

## 2. Functional Requirements

- Consume domain events published across the platform and fan them out to end users via email, SMS, and push (BRD §2.1 item 15: "Email/SMS/push fan-out").
- Persist an audit record of each notification attempt in PostgreSQL (BRD §5.4: "Notification | ... | PostgreSQL (audit) | ...").
- Publish `NotificationSent` (userId, channel, status) after processing an inbound event and attempting delivery (BRD §10).
- Expose no inbound public API — Notification is consumer-only (BRD §5.4); it is driven entirely by the message bus, not by direct client or service calls.
- Consume the resolved event set per **ADR-0003** and BRD §5.4/§10 (current text):
  - All `order.*` and `payment.*` routed events: `OrderCreated`, `OrderConfirmed`, `OrderCancelled`, `OrderCompensationTriggered`, `OrderDelivered`, `PaymentCompleted`, `PaymentFailed`, `RefundIssued`.
  - Events whose own name states a customer-notification intent: `WishlistPriceAlertTriggered` (price-drop alert), `UserRegistered` (welcome email).
  - `ShipmentDispatched` and `DeliveryStatusUpdated` (shipping/tracking notifications).
  - Explicitly **not** in scope: `ReviewSubmitted`, `CouponRedeemed`, catalog/search events, admin/analytics-internal events — none carry notification intent and none fall under the `order.*`/`payment.*` wildcards (ADR-0003).
- Select a delivery channel (or channels) per triggering event according to the channel-selection rule in §4/§6 Q2 (resolved below), rather than fanning every event to every channel unconditionally.
- Check the recipient's per-channel, per-category opt-out preference (§4/§6 Q3, resolved below) before attempting delivery on any channel, and record a suppressed/skipped outcome (not a silent no-op) when a user has opted out.
- Deduplicate redelivered upstream events before sending, via the idempotency mechanism decided in `edge-cases.md` ("Duplicate Notification Delivery Under At-Least-Once Redelivery"): a unique constraint on `(eventId, channel)` in the existing PostgreSQL audit store, checked before attempting delivery.

## 3. Non-Functional Requirements

Pulled from the BRD's global NFR table (§3), the RabbitMQ Limitations section (§14), and the Kafka Migration section (§15), scoped to this service:

| Attribute | Target | Applies here because |
|---|---|---|
| Availability | **99.9% (secondary tier)** — resolved (§6 Q5, no existing ADR needed: single-service default) | Notification is not a participant Order compensates against in the Order Saga (§5.1, §12) and has no synchronous inbound API of its own (§5.4) for anything else to depend on availability-wise, so it does not meet the BRD's stated criterion for the 99.99% "order path" tier ("critical path" services other requests synchronously depend on). Unlike Identity (which gates all authenticated traffic through the Gateway, §18, and was left open for that reason in `kart-identity-service`'s spec), Notification has no comparable synchronous fan-in dependency from other services, so this call is made directly here rather than deferred. |
| Reliability | At-least-once delivery + idempotent consumers (BRD §3 general rule), satisfied by the `(eventId, channel)` dedup check above. `NotificationSent`'s own publish retry ("1x, fire-and-forget audit", §10) governs only the **audit-record publish step after a send attempt concludes** — it does not govern the send attempt itself. See the retry/DLQ tiering resolution below (§6 Q6/Q7) for why these are two different policies, not a contradiction. | Notification both consumes at-least-once (redelivery expected, handled by dedup) and publishes its own audit event with the platform's loosest retry tier (deliberately — losing an audit-publish retry delays Analytics' visibility into an already-resolved outcome, not the user-facing delivery itself) |
| Consistency | Eventual — notification delivery is inherently asynchronous and best-effort relative to the triggering event | No BRD section claims strong consistency for notification delivery; this is the natural default given the async, fan-out nature of the service |
| Throughput | Exposed to platform-wide event volume: ~200M messages/day (§4.3), peak Kafka throughput ~50,000 msgs/sec (§4.3) — Notification is one of the platform's broadest single consumers on its resolved event set (ADR-0003) | §14 names "throughput ceiling under heavy fan-out" as a RabbitMQ limitation; mitigated per `edge-cases.md`'s "Consumer Overwhelmed by Event Fan-In" decision (HPA autoscaling + per-criticality queue splitting) |
| Messaging placement | Remains on RabbitMQ permanently, not migrated to Kafka (§15: "Notification and transactional Order/Payment flows stay on RabbitMQ because they need low-latency task-queue semantics... not a log") | Directly scopes this service's messaging NFR — the apparent tension with §14's fan-out throughput ceiling is resolved as an accepted, deliberate trade-off, not a contradiction; see §6 Q8 |
| Retry/DLQ | Tiered by the triggering event's own already-catalogued retry policy (resolved §6 Q6/Q7): Tier 1 (money-moving-triggered: `PaymentCompleted`, `PaymentFailed`, `RefundIssued`) — 5x + paged, mirroring Payment's own tier; Tier 2 (order/identity-lifecycle-triggered: `OrderCreated`, `OrderConfirmed`, `OrderCancelled`, `OrderCompensationTriggered`, `OrderDelivered`, `ShipmentDispatched`, `DeliveryStatusUpdated`, `UserRegistered`) — 3x, non-paged; Tier 3 (catalog/wishlist-triggered: `WishlistPriceAlertTriggered`) — 2x, non-paged. The `NotificationSent` audit-publish event itself keeps BRD §10's stated 1x/fire-and-forget/`notification.dlq` tier unchanged — that governs the audit record only, published after the send attempt (with its own tiered retries above) has already concluded. | Resolves the apparent §10/§8.2 tension (§6 Q6) by separating "retry budget for the send attempt" from "retry budget for the resulting audit-log publish," and resolves criticality tiering (§6 Q7) by reusing each triggering event's existing catalogued tier instead of inventing a new scheme |

## 4. Domain Invariants

- Every consumed event that should trigger a notification must eventually result in either a recorded successful delivery, a recorded suppressed-by-opt-out outcome, or an auditable failure entry in the PostgreSQL audit store — never a silent drop (inferred from "PostgreSQL (audit)" at §5.4 combined with the platform's general DLQ philosophy at §8.2 that failures are "inspected via admin tooling, never silently dropped").
- `NotificationSent`'s `status` field must reflect the actual per-channel delivery outcome (`sent` / `failed` / `suppressed`), not merely "event was consumed" (inferred from the stated payload shape at §10: userId, channel, status).
- Notification processing must be idempotent under RabbitMQ's at-least-once delivery (BRD §3 general Reliability rule): the same upstream event redelivered must not produce a duplicate user-facing email/SMS/push. Resolved mechanism: a unique `(eventId, channel)` constraint against the existing PostgreSQL audit store, checked before attempting delivery (see `edge-cases.md`).
- A user's per-channel, per-category opt-out preference must be checked and honored before any send attempt (resolved §6 Q3) — Notification must never dispatch to a channel/category a user has explicitly opted out of, regardless of the triggering event's own criticality tier.
- The channel(s) selected for a given triggering event must follow the resolved channel-selection rule (§6 Q2) rather than being an ad hoc per-event choice made at implementation time.

## 5. API Surface (from BRD, starting point only)

| Endpoint/Event | Direction | Notes |
|---|---|---|
| — | Inbound API | None — Notification exposes no public API (BRD §5.4) |
| `OrderCreated` | Consumed | Published by Order (BRD §10); Tier 2 retry |
| `OrderConfirmed` | Consumed | Published by Order (BRD §10); Tier 2 retry |
| `OrderCancelled` | Consumed | Published by Order (BRD §10); Tier 2 retry |
| `OrderCompensationTriggered` | Consumed | Published by Order (BRD §10); Tier 2 retry |
| `OrderDelivered` | Consumed | Published by Order, canonical terminal event per ADR-0005 (BRD §10); Tier 2 retry |
| `PaymentCompleted` | Consumed | Published by Payment (BRD §10); Tier 1 retry |
| `PaymentFailed` | Consumed | Published by Payment (BRD §10); Tier 1 retry |
| `RefundIssued` | Consumed | Published by Payment (BRD §10); Tier 1 retry |
| `ShipmentDispatched` | Consumed | Published by Shipping (BRD §10); Tier 2 retry |
| `DeliveryStatusUpdated` | Consumed | Published by Delivery Tracking (BRD §10); Tier 2 retry |
| `WishlistPriceAlertTriggered` | Consumed | Published by Wishlist (BRD §10); Tier 3 retry |
| `UserRegistered` | Consumed | Published by Identity (BRD §10); Tier 2 retry |
| `NotificationSent` | Published | Consumed by Analytics (BRD §10); 1x, fire-and-forget audit publish (unchanged, §6 Q6) |

Resolved consumed-event set per ADR-0003; the RabbitMQ binding set needed to realize it (§9's example manifest binds only `order.*`/`payment.*` — the `WishlistPriceAlertTriggered`/`UserRegistered` bindings need their own routing-key entries, e.g. `wishlist.*`, `identity.*`) is a topology-finalization detail carried forward to the Architecture/event-design stage, not a blocking gap in this spec (the *scope* is fully resolved; only the JSON manifest's literal binding list needs extending to match it).

Final contract (payload versioning, opt-out API surface if one is warranted) is the API Design Agent's job, not this spec's.

## 6. Open Questions / Flagged Ambiguities

All previously blocking items below are now resolved. Two items remain, both explicitly non-blocking handoffs to later pipeline stages (labeled as such).

1. **Consumed-event set contradiction — RESOLVED.** Was: BRD §5.4 ("almost every event in catalog") vs §10 (3 named rows) disagreed on Notification's consumption scope. **Resolution: ADR-0003** (`docs/adr/0003-notification-consumed-event-scope.md`) settles this as all `order.*`/`payment.*` events, plus `WishlistPriceAlertTriggered`, `UserRegistered`, `ShipmentDispatched`, and `DeliveryStatusUpdated` — explicitly excluding `ReviewSubmitted`, `CouponRedeemed`, and catalog/search/admin/analytics-internal events. `kart-requirements.md` §5.4 and §10 have already been updated to state this resolved scope directly. No re-litigation needed; see §2/§5 above for the concrete list this spec now uses.

2. **Channel-selection rule — RESOLVED (single-service default).** The BRD names email/SMS/push (§2.1 item 15) but states no routing rule. **Decision:** default channel priority is `email` (universal reachability, no opt-in device requirement); escalate to `SMS` in addition to email for time-critical delivery/logistics events where the user is expected to act or be physically present (`ShipmentDispatched`, `DeliveryStatusUpdated`, and Tier 1 money-moving events `PaymentFailed`/`RefundIssued`, where a fast out-of-band signal matters); add `push` alongside email whenever the recipient has an app-installed flag set on their profile (avoids assuming push reachability the BRD never confirms exists for every user). **Why:** email is the only channel the BRD implies universal reachability for (every registered user has one, per Identity's `UserRegistered.email` payload, §10); SMS/push are additive for urgency/reachability, not replacements — this matches how the platform already tiers criticality elsewhere (money-moving and time-sensitive get more channels/attention, not just more retries). **Trade-off accepted:** this is an engineering default, not a BRD-stated rule — if product later wants a different default (e.g., push-first for a mobile-heavy user base), that's a product decision to revise here, not a re-reading of the BRD.

3. **User notification-preference / opt-out handling — RESOLVED (single-service default).** No BRD section defines a notification-specific opt-out mechanism, and User Service's general "preferences" (BRD §2.1 item 2) are not stated to include per-channel notification opt-out. **Decision:** opt-out is modeled as **per-channel, per-category** (e.g., "SMS off for marketing, email on for order updates"), owned and stored entirely within Notification's own PostgreSQL store (not delegated to or synchronously fetched from User Service), and checked before every send attempt on every channel. **Why:** Notification has no public API and no synchronous outbound calls to other services (BRD §5.4) — a sync call to User Service to check preferences on every send would violate that architecture and add a hard dependency to the platform's highest-fan-in consumer; owning this data locally is consistent with the platform's existing "each service denormalizes what it needs to make its own decisions" pattern (the same reasoning ADR-0006 already applied to User's own denormalized copy of Identity's email/displayName). **Trade-off accepted:** the exact mechanism by which a user *sets* this preference (a small dedicated Notification-owned API, vs. a new User→Notification sync event analogous to `UserAccountUpdated`) is **not** decided here — that is a concrete API/event-contract design question, correctly deferred to the API Design/Architecture Agent stage, not a BRD ambiguity blocking sign-off. This is carried forward as **non-blocking**: the what/where/when-checked of opt-out is fixed now; the how-it's-populated wiring is downstream work.

4. **Dedup window/mechanism — RESOLVED.** Was: BRD §3's general at-least-once + idempotent-consumer rule gave no concrete Notification-specific mechanism. **Resolution:** see `edge-cases.md` ("Duplicate Notification Delivery Under At-Least-Once Redelivery") — a unique `(eventId, channel)` constraint against the existing PostgreSQL audit store, checked before attempting delivery. This is a single-service engineering default reusing a component the service already has (the audit store) rather than a new one, consistent with the idempotency-key pattern the platform already uses for Payment (BRD §5.3/§6.1). A narrow residual race (a redelivery arriving before the original attempt's row commits) is a known, accepted, non-blocking hardening detail left to the Architecture/DDD Agent — the *mechanism* itself is decided, only its transactional tightening is downstream work.

5. **Availability tier — RESOLVED (single-service default).** See §3 NFR table above: 99.9% secondary tier, on the grounds that Notification is not an Order Saga compensation participant and has no synchronous inbound dependents (unlike Identity, whose comparable question remains genuinely open in its own spec because Identity *does* gate all authenticated traffic).

6. **Retry/DLQ tension — RESOLVED.** Was: `NotificationSent`'s "1x fire-and-forget" retry (§10) appeared to contradict §8.2's "never silently dropped" DLQ philosophy. **Resolution:** these apply to two different things. The 1x/fire-and-forget tier governs only publishing the `NotificationSent` audit record after a send attempt has already concluded (success or failure) — it is not silently dropped (still lands in `notification.dlq` on failure, still inspected per §8.2), it's simply low-stakes because the user-facing outcome it's describing already happened; losing/delaying this publish delays Analytics' visibility, not delivery. The send attempt itself is retried per its triggering event's own criticality tier (see Q7 and §3's Retry/DLQ row) — a materially different, tiered policy, not "1x" at all. No contradiction remains.

7. **Criticality tiering for consumption — RESOLVED (single-service default, reuses existing convention).** Was: the BRD tiers retry/DLQ per *published* event, not per event a downstream consumer processes, so it was unclear whether Notification's own send/retry behavior should vary by the criticality of the event that triggered it. **Decision:** Notification's internal send-attempt retry budget for a given notification **inherits the triggering event's own already-catalogued BRD §10 retry tier** verbatim — Tier 1 (5x + paged, for `PaymentCompleted`/`PaymentFailed`/`RefundIssued`), Tier 2 (3x, for the Order-lifecycle and identity/shipping/tracking events), Tier 3 (2x, for `WishlistPriceAlertTriggered`). **Why:** this reuses the platform's existing money-moving-criticality convention (`docs/standards/kart-conventions.md`, `event-standards.md`) instead of inventing a new, one-off tiering scheme for Notification specifically — no new business judgment call is required, since the criticality of "an order-confirmation notification" is already exactly the criticality the platform assigned to `OrderConfirmed` itself. **Trade-off accepted:** Notification's send pipeline must carry/derive the triggering event's type (and therefore its tier) through to the retry logic — a small piece of pipeline metadata, in exchange for not requiring a fresh product/business decision about "what makes a notification critical" that the BRD never supplies criteria for.

8. **RabbitMQ-permanence vs. fan-out-throughput-ceiling tension — RESOLVED (accepted trade-off, not a contradiction).** §15 keeps Notification on RabbitMQ permanently for low-latency task-queue semantics; §14 separately names "throughput ceiling under heavy fan-out" as a RabbitMQ limitation at flash-sale volumes. **Resolution:** this is not an unreconciled contradiction — §15's own stated rationale (Notification needs ack/nack, per-message task-queue semantics, not log replay) is a deliberate trade-off the BRD already makes explicitly, distinguishing Notification/Order/Payment (stay on RabbitMQ) from Analytics/Recommendation (migrate to Kafka *because* they need replay/partitioned throughput, which Notification does not need). The throughput-ceiling limitation is real and is mitigated operationally, not by a broker change: see `edge-cases.md`'s "Consumer Overwhelmed by Event Fan-In" decision (HPA autoscaling on queue depth + per-criticality queue splitting). No ADR is needed — this is the BRD's own already-stated architectural choice plus a standard scaling mitigation, not a fresh cross-service decision.

## Sign-off

- [x] Blocking open questions resolved (Q1 in particular)
- [x] Reviewed by: Automated architecture pipeline -- see docs/adr and this run's decision log
- [x] Approved to proceed to Architecture Agent
