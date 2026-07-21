---
doc_type: edge-cases
service: kart-notification-service
status: approved
generated_by: edge-case-analyzer-agent
source: docs/services/kart-notification-service/requirement-spec.md
---

# Edge Cases: kart-notification-service

## Edge Case: Consumer Overwhelmed by Event Fan-In During Traffic Spike

- **What happens:** `notification.queue` depth and consumer lag spike during flash-sale traffic, delaying or backing up notifications platform-wide, not just for one event type.
- **Why it happens:** Notification consumes all `order.*`/`payment.*` events plus `WishlistPriceAlertTriggered`, `UserRegistered`, `ShipmentDispatched`, and `DeliveryStatusUpdated` (ADR-0003; requirement-spec §2/§5) and is structurally the platform's broadest single consumer on that resolved set (requirement-spec NFR Throughput row); this is precisely the "throughput ceiling under heavy fan-out" limitation BRD §14 names for RabbitMQ, and it is not mitigated by the Kafka migration since Notification is explicitly excluded from it (BRD §15).
- **Solutions available (3):** Horizontal autoscale consumers on queue-depth custom metric (K8s HPA, BRD §13/§22) · Split `notification.queue` into per-channel or per-criticality sub-queues by routing key to isolate/prioritize load (BRD §9 config-driven topology) · Shed load by dropping/degrading lowest-priority notification categories under backpressure
- **Decision:**
  - Chosen: HPA-driven consumer autoscaling on queue-depth metric, combined with per-criticality queue splitting (money-moving-triggered vs. informational-triggered) so a spike in one category doesn't starve another
  - Why: matches the platform's stated remedy for queue overflow (BRD §13: "Autoscale consumers via K8s HPA on queue-depth custom metric") and requires no broker change, consistent with Notification staying on RabbitMQ (BRD §15)
  - Trade-off accepted: does not resolve the underlying RabbitMQ fan-out throughput ceiling itself (BRD §14) — this is a scaling mitigation, not a structural fix; requirement-spec §6 Q8 already resolves the RabbitMQ-permanence-vs-throughput-ceiling tension as an accepted, deliberate trade-off (not a contradiction), so this mitigation is the accepted operational answer to a known, accepted limitation — not evidence of an open gap

## Edge Case: Duplicate Notification Delivery Under At-Least-Once Redelivery

- **What happens:** the same upstream event (e.g. `OrderConfirmed`) is redelivered after a broker requeue or ack timeout, and a user receives the same email/SMS/push twice.
- **Why it happens:** RabbitMQ's at-least-once delivery (requirement-spec NFR Reliability row) is combined, for Notification specifically, with the loosest retry/DLQ tier in the entire catalog (`NotificationSent`: 1x, fire-and-forget audit) and no stated idempotency-key or dedup-window mechanism (requirement-spec Domain Invariant #3, Open Question 4).
- **Solutions available (3):** idempotency check (eventId + channel) against the existing PostgreSQL audit store before sending · time-windowed dedup cache (e.g. Redis) keyed on eventId with a short TTL · rely on the downstream channel provider's own dedup/idempotency, where offered
- **Decision:**
  - Chosen: idempotency check against the PostgreSQL audit store (unique constraint on `eventId + channel`) before attempting delivery
  - Why: Notification already persists an audit record of every attempt (requirement-spec FR / Domain Invariant #1), so the audit store doubles as the dedup source of truth without a new component, mirroring the idempotency-key pattern the platform already uses for Payment (BRD §5.3/§6.1)
  - Trade-off accepted: a redelivery arriving before the original attempt's audit row commits can still race past the check — this narrows but does not eliminate the duplicate-send window; fully closing it is left to the Architecture/DDD Agent stage, per requirement-spec Open Question 4

## Edge Case: One Slow/Failing Downstream Channel Blocking the Whole Consumer

- **What happens:** an SMS gateway (or email/push provider) goes slow or unavailable, and the shared Notification consumer's capacity gets tied up waiting on it — backing up `notification.queue` for every channel, not just the failing one.
- **Why it happens:** a single fan-in consumer handling all channels means a slow synchronous call to one downstream provider consumes shared capacity (BRD §13 Failure Simulation names this failure class generally — "Consumer Failure," "Slow Database" — generalized here to a slow downstream channel dependency); nothing in the BRD isolates channels from each other.
- **Solutions available (3):** per-channel consumer pools/queues (bulkhead isolation) so email/SMS/push each get independent capacity · circuit breaker per downstream channel provider that opens on sustained failure/latency and fails fast to the audit store instead of blocking · fully async, non-blocking channel calls with a bounded per-send timeout
- **Decision:**
  - Chosen: per-channel bulkhead isolation (separate consumer pools per channel), plus a circuit breaker per downstream provider
  - Why: directly matches the platform's stated Fault Tolerance NFR ("graceful degradation, no cascading failure... circuit breakers on all outbound calls," BRD §3) and the bulkhead pattern already named for slow-dependency isolation (BRD §13)
  - Trade-off accepted: requires provisioning and monitoring separate capacity per channel instead of one shared pool — more operational surface, in exchange for preventing one vendor outage from silently degrading every notification channel

## Edge Case: DLQ/Retry Policy Not Differentiated by Triggering-Event Criticality

- **What happens:** a notification triggered by a money-moving event (e.g. an order-confirmation email tied to `OrderConfirmed`) fails to send and is handled identically to one triggered by a low-stakes event (e.g. a review-submitted confirmation) — both get the same 1x retry, fire-and-forget DLQ treatment.
- **Why it happens:** the BRD's only stated retry/DLQ row for Notification covers its own published event, `NotificationSent` (1x, fire-and-forget), with no tiering by the criticality of the *triggering* event — even though the platform elsewhere tiers retry/DLQ strictly by criticality (`Payment*` at 5x + paging vs. looser catalog-event retry, BRD §10 footnote) (requirement-spec §6 Q7, resolved).
- **Solutions available (3):** notification-send retry/backoff inherits the triggering event's own criticality tier (e.g. an order-confirmation notification gets Order's 3x tier) · a single uniform Notification-side retry policy regardless of trigger, with criticality expressed only via alerting/paging on DLQ entries · a two-tier scheme — paged DLQ for an explicit list of critical notification types, fire-and-forget for everything else
- **Decision:**
  - Chosen: notification-send retry inherits the triggering event's own already-catalogued BRD §10 retry tier verbatim — Tier 1 (5x + paged) for notifications triggered by `PaymentCompleted`/`PaymentFailed`/`RefundIssued`; Tier 2 (3x, non-paged) for notifications triggered by the Order-lifecycle, `UserRegistered`, `ShipmentDispatched`, or `DeliveryStatusUpdated` events; Tier 3 (2x, non-paged) for notifications triggered by `WishlistPriceAlertTriggered`. This matches requirement-spec §3 (NFR Retry/DLQ row) and §6 Q7.
  - Why: reuses the platform's existing money-moving-criticality convention (`docs/standards/kart-conventions.md`, reusable `event-standards.md`: "retry budget scales with criticality") instead of inventing a new, one-off tiering scheme for Notification specifically — the criticality of "an order-confirmation notification" is already exactly the criticality the platform assigned to `OrderConfirmed` itself, so no fresh product/business judgment call about "what makes a notification critical" is required
  - Trade-off accepted: Notification's send pipeline must carry/derive the triggering event's type (and therefore its tier) through to the retry logic — a small piece of pipeline metadata. This also means a notification's criticality can never exceed or diverge from its triggering event's catalogued tier; if product later wants a notification-specific criticality independent of the underlying event (e.g. paging on a *marketing* send failure that the underlying event itself doesn't page on), that would be a new product decision to revisit this default, not a gap in it today — every event currently in Notification's consumed scope (ADR-0003) is transactional/lifecycle, none are marketing, so this ceiling is not currently binding
