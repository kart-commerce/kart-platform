---
doc_type: requirement-spec
service: kart-notification-service
status: pending-approval
generated_by: requirement-agent
source: docs/requirements/kart-requirements.md
---

# Requirement Spec: kart-notification-service

## 1. Scope

Covers the single BRD service **Notification Service** (BRD §2.1 item 15): "Email/SMS/push fan-out." No merge; no ADR applies.

Like Identity, Notification gets no dedicated deep-dive section (§5.1–5.3 only cover Order/Inventory/Payment) — it appears as one condensed row in §5.4, plus scattered mentions in the Service Boundary Diagram (§5.5), the RabbitMQ topology example (§9), the Event Catalog (§10), RabbitMQ Limitations (§14), and the Kafka Migration section (§15). This spec draws only on those mentions; it does not invent channel logic, preference handling, or dedup mechanics the BRD never states — see §6 for the resulting gaps.

Notification is architecturally distinct from every other service profiled so far: it has **no public API** (§5.4: "consumer only, no public API") and is the platform's fan-in point — §5.4 describes its consumed events as "almost every event in catalog," a breadth no other service's row claims.

## 2. Functional Requirements

- Consume domain events published across the platform and fan them out to end users via email, SMS, and push (BRD §2.1 item 15: "Email/SMS/push fan-out").
- Persist an audit record of each notification attempt in PostgreSQL (BRD §5.4: "Notification | ... | PostgreSQL (audit) | ...").
- Publish `NotificationSent` (userId, channel, status) after processing an inbound event (BRD §10).
- Expose no inbound public API — Notification is consumer-only (BRD §5.4); it is driven entirely by the message bus, not by direct client or service calls.
- Consume, at minimum, the events the Event Catalog (§10) explicitly names Notification as a consumer of: `OrderConfirmed` (orderId, address), `ShipmentDispatched` (orderId, carrier, trackingId), `DeliveryStatusUpdated` (trackingId, status).
- The BRD's condensed service row (§5.4) states Notification consumes "almost every event in catalog" — materially broader than the three events §10 explicitly lists it against. Which additional events (e.g. `OrderCreated`, `PaymentCompleted`, `PaymentFailed`, `ReviewSubmitted`, `CouponRedeemed`) are in scope is not stated; see Open Questions Q1. This spec does not assume the broader set as a functional requirement beyond what §10 names explicitly.

## 3. Non-Functional Requirements

Pulled from the BRD's global NFR table (§3), the RabbitMQ Limitations section (§14), and the Kafka Migration section (§15), scoped to this service:

| Attribute | Target | Applies here because |
|---|---|---|
| Availability | Not placed in either BRD tier (99.99% order path / 99.9% secondary) — Notification does not appear in the Order Saga (§5.1, §12) as a participant Order compensates against, which argues for the 99.9% secondary tier, but the BRD never states this explicitly for Notification; see Open Questions Q5 | No BRD section assigns Notification an availability tier |
| Reliability | At-least-once delivery + idempotent consumers (BRD §3 general rule) — but `NotificationSent`'s own retry row (§10) is "1x (fire-and-forget audit)", the loosest of any event in the catalog | Notification both consumes at-least-once (so redelivery is expected) and publishes with the weakest retry guarantee in the platform — see Open Questions Q4 on the resulting dedup gap |
| Consistency | Eventual — notification delivery is inherently asynchronous and best-effort relative to the triggering event | No BRD section claims strong consistency for notification delivery; this is the natural default given the async, fan-out nature of the service |
| Throughput | Exposed to platform-wide event volume: ~200M messages/day (§4.3), peak Kafka throughput ~50,000 msgs/sec (§4.3) — because it consumes "almost every event in catalog" (§5.4), Notification is structurally the single highest-fan-in consumer in the system | §14 names "throughput ceiling under heavy fan-out" as a RabbitMQ limitation specifically because "10+ consumer groups per event" multiplies effective message rate — Notification, as the broadest single consumer, is the service this limitation is written about |
| Messaging placement | Remains on RabbitMQ permanently, not migrated to Kafka (§15: "Notification and transactional Order/Payment flows stay on RabbitMQ because they need low-latency task-queue semantics... not a log") | Directly scopes this service's messaging NFR — see Open Questions Q8 for the tension this creates against the §14 fan-out throughput limitation |
| Retry/DLQ | `NotificationSent`: 1x retry, `notification.dlq` (BRD §10) | Notably the loosest retry budget of any event in the catalog, despite §8.2's general DLQ philosophy ("never silently dropped") — see Open Questions Q6 |

## 4. Domain Invariants

- Every consumed event that should trigger a notification must eventually result in either a recorded successful delivery or an auditable failure entry in the PostgreSQL audit store — never a silent drop (inferred from "PostgreSQL (audit)" at §5.4 combined with the platform's general DLQ philosophy at §8.2 that failures are "inspected via admin tooling, never silently dropped").
- `NotificationSent`'s `status` field must reflect the actual per-channel delivery outcome (success/failure), not merely "event was consumed" (inferred from the stated payload shape at §10: userId, channel, status).
- Notification processing must be idempotent under RabbitMQ's at-least-once delivery (BRD §3 general Reliability rule) — the same upstream event redelivered must not produce a duplicate user-facing email/SMS/push. The BRD states the general idempotency rule but no dedup mechanism specific to Notification; see Open Questions Q3.

## 5. API Surface (from BRD, starting point only)

| Endpoint/Event | Direction | Notes |
|---|---|---|
| — | Inbound API | None — Notification exposes no public API (BRD §5.4) |
| `OrderConfirmed` | Consumed | Published by Order (BRD §10) |
| `ShipmentDispatched` | Consumed | Published by Shipping (BRD §10) |
| `DeliveryStatusUpdated` | Consumed | Published by Delivery Tracking (BRD §10) |
| (additional events) | Consumed, unspecified | BRD §5.4 says "almost every event in catalog" but §10 names only the three rows above — see Open Questions Q1 |
| `NotificationSent` | Published | Consumed by Analytics (BRD §10) |

Final contract is the API Design Agent's job, not this spec's.

## 6. Open Questions / Flagged Ambiguities

1. **Consumed-event set contradiction.** The Event Catalog (§10) explicitly lists Notification as a consumer only for `OrderConfirmed`, `ShipmentDispatched`, and `DeliveryStatusUpdated`. The condensed service row (§5.4) instead describes Notification's consumption as "almost every event in catalog" — a materially broader claim (e.g. would include `OrderCreated`, `PaymentCompleted`, `PaymentFailed`, `ReviewSubmitted`, `CouponRedeemed`). Both readings appear in the BRD and are not reconciled. This is the single most consequential gap in this spec, since it directly determines the service's consumption surface, load profile, and RabbitMQ binding set (§9's example manifest only binds `order.*` and `payment.*` to `notification.queue`, which is consistent with neither reading exactly).
2. **Channel-selection rule unspecified.** The BRD names email/SMS/push as the fan-out channels (§2.1 item 15) but states no rule for which event types route to which channel(s), or whether some events fan out to multiple channels simultaneously.
3. **User notification-preference / opt-out handling unspecified.** No BRD section mentions a user-configurable notification preference, channel opt-out, or do-not-disturb setting, despite User Service (§5.4) owning general "preferences." Whether Notification must consult User's preference data before sending is not stated.
4. **Dedup window/mechanism unspecified.** BRD §3 states a general at-least-once + idempotent-consumer rule, but gives Notification's own publish event the loosest retry tier in the catalog (1x, fire-and-forget) rather than a stated idempotency-key or dedup-window mechanism. How redelivery of the same upstream event (e.g. `OrderConfirmed` redelivered after a broker requeue) is detected and suppressed is not stated.
5. **Availability tier unassigned.** As with Identity in a prior pass, BRD §3 splits Availability into two tiers but never places Notification in either explicitly.
6. **Retry/DLQ tension.** `NotificationSent` gets a "1x (fire-and-forget audit)" retry policy (§10) — the loosest in the entire Event Catalog — yet §8.2 states the platform's DLQ philosophy is that failures are "never silently dropped." Whether "fire-and-forget" was intended to mean "audit-only, delivery failure is acceptable" or is simply the BRD's shorthand for "low criticality" is not stated.
7. **No per-source-event criticality tiering for consumption.** The BRD's retry/DLQ criticality tiering (§10, §14) is defined per *published* event, not per event a downstream consumer processes. Whether Notification should apply a different retry/backoff/DLQ policy depending on the criticality of the *triggering* event it consumed (e.g. a failed send triggered by `PaymentCompleted` vs. one triggered by `ReviewSubmitted`) is not addressed anywhere in the BRD.
8. **RabbitMQ-permanence vs. fan-out-throughput-ceiling tension.** §15 commits Notification to RabbitMQ permanently, citing low-latency task-queue semantics; but §14 names "throughput ceiling under heavy fan-out" as a RabbitMQ limitation specifically driven by high-consumer-group fan-out at flash-sale volumes (167K RPS, §4.2) — and Notification, consuming "almost every event" (§5.4), is the platform's most fan-out-exposed consumer. The BRD does not reconcile why the service most exposed to this named limitation is also the one explicitly excluded from the Kafka migration.

## Sign-off

- [ ] Blocking open questions resolved (Q1 in particular)
- [ ] Reviewed by:
- [ ] Approved to proceed to Architecture Agent
