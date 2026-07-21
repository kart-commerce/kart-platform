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
- **Why it happens:** Notification consumes "almost every event in catalog" (requirement-spec §2/§5) and is structurally the platform's highest-fan-in consumer (requirement-spec NFR Throughput row); this is precisely the "throughput ceiling under heavy fan-out" limitation BRD §14 names for RabbitMQ, and it is not mitigated by the Kafka migration since Notification is explicitly excluded from it (BRD §15).
- **Solutions available (3):** Horizontal autoscale consumers on queue-depth custom metric (K8s HPA, BRD §13/§22) · Split `notification.queue` into per-channel or per-criticality sub-queues by routing key to isolate/prioritize load (BRD §9 config-driven topology) · Shed load by dropping/degrading lowest-priority notification categories under backpressure
- **Decision:**
  - Chosen: HPA-driven consumer autoscaling on queue-depth metric, combined with per-criticality queue splitting (money-moving-triggered vs. informational-triggered) so a spike in one category doesn't starve another
  - Why: matches the platform's stated remedy for queue overflow (BRD §13: "Autoscale consumers via K8s HPA on queue-depth custom metric") and requires no broker change, consistent with Notification staying on RabbitMQ (BRD §15)
  - Trade-off accepted: does not resolve the underlying RabbitMQ fan-out throughput ceiling itself (BRD §14) — this is a scaling mitigation, not a structural fix; requirement-spec Open Question 8 (RabbitMQ-permanence vs. fan-out-ceiling tension) remains unresolved and is escalated, not silently decided here

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
- **Why it happens:** the BRD's only stated retry/DLQ row for Notification covers its own published event, `NotificationSent` (1x, fire-and-forget), with no tiering by the criticality of the *triggering* event — even though the platform elsewhere tiers retry/DLQ strictly by criticality (`Payment*` at 5x + paging vs. looser catalog-event retry, BRD §10 footnote) (requirement-spec Open Question 7).
- **Solutions available (3):** notification-send retry/backoff inherits the triggering event's own criticality tier (e.g. an order-confirmation notification gets Order's 3x tier) · a single uniform Notification-side retry policy regardless of trigger, with criticality expressed only via alerting/paging on DLQ entries · a two-tier scheme — paged DLQ for an explicit list of critical notification types, fire-and-forget for everything else
- **Decision:**
  - Chosen: escalated as unresolved
  - Why: the BRD gives no criteria for what makes a *notification* (as distinct from its underlying domain event) critical enough to page on; picking a tiering scheme here would invent a policy the requirement-spec explicitly could not source from the BRD (Open Question 7) — this is a business/product call, not an engineering default
  - Trade-off accepted: none taken silently — left open for human decision before the Architecture Agent designs the retry/DLQ implementation
