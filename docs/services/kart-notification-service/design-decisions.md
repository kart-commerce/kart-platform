---
doc_type: design-decisions
service: kart-notification-service
status: pending-approval
generated_by: design-decision-agent
source: docs/services/kart-notification-service/requirement-spec.md, docs/services/kart-notification-service/edge-cases.md
---

# Design Decisions: kart-notification-service

Both source docs are `status: approved` with all blocking Open Questions resolved (ADR-0003 for consumed-event scope; Q2 channel-selection, Q3 opt-out, Q6 retry/DLQ tension, and Q7 criticality tiering all resolved as single-service defaults). The decisions below translate those already-settled calls into locked technology/pattern choices for the Architecture Agent, plus two new cross-cutting decisions (retry mechanism, opt-out lookup caching) the requirement-spec/edge-cases forced but didn't fully specify at the mechanism level.

## Decision: Communication Style — Consumer-Only Async Messaging over RabbitMQ

- **Requirement driving this:** BRD §5.4 ("consumer only, no public API"); §15 keeps Notification permanently on RabbitMQ, not migrated to Kafka; requirement-spec §6 Q8 resolves the apparent tension with §14's fan-out throughput ceiling as an accepted trade-off, not a contradiction.
- **Options considered (3):** RabbitMQ topic-exchange consumer (task-queue semantics, per-message ack/nack) · Kafka consumer group (replay + partitioned throughput, per §15's stated criterion for Analytics/Recommendation) · synchronous inbound API exposed to callers instead of pure event consumption
- **Decision:**
  - Chosen: RabbitMQ topic-exchange consumer only, on the `ecommerce.events` exchange (`docs/standards/kart-conventions.md`), bound to `order.*`, `payment.*`, plus dedicated routing keys for `WishlistPriceAlertTriggered`, `UserRegistered`, `ShipmentDispatched`, `DeliveryStatusUpdated`; no inbound public API of any kind
  - Why: matches BRD §5.4's explicit "consumer only, no public API" statement and §15's explicit rationale for excluding Notification from the Kafka migration (ack/nack task-queue semantics, not log replay)
  - Trade-off accepted: the "throughput ceiling under heavy fan-out" limitation (BRD §14) is accepted as-is and mitigated operationally (see Concurrency & Scaling decision below), not by a broker change — already resolved as deliberate at requirement-spec §6 Q8, not re-litigated here

## Decision: Idempotency Mechanism for Duplicate Notification Delivery

- **Requirement driving this:** Domain invariant — processing must be idempotent under at-least-once delivery (requirement-spec §4); `edge-cases.md` "Duplicate Notification Delivery Under At-Least-Once Redelivery."
- **Options considered (3):** unique constraint on `(eventId, channel)` in the existing PostgreSQL audit store, checked before send · time-windowed Redis dedup cache keyed on `eventId` with a short TTL · rely on the downstream channel provider's own dedup/idempotency support
- **Decision:**
  - Chosen: unique `(eventId, channel)` constraint against the existing PostgreSQL audit store, checked before attempting delivery — already decided in `edge-cases.md`, restated here as the locked mechanism the Architecture/DDD Agent designs schema and transactional detail around
  - Why: reuses a component the service already owns (the audit store) instead of introducing Redis solely for dedup; mirrors the idempotency-key pattern the platform already uses for Payment (BRD §5.3/§6.1)
  - Trade-off accepted: a redelivery arriving before the original attempt's row commits can still race past the check (known, accepted, narrow residual window) — fully closing it is explicitly deferred to the Architecture/DDD Agent stage (requirement-spec Open Question 4), not re-decided here

## Decision: Resilience Pattern for Per-Channel Downstream Provider Isolation

- **Requirement driving this:** Fault Tolerance NFR — "graceful degradation, no cascading failure... circuit breakers on all outbound calls" (BRD §3); `edge-cases.md` "One Slow/Failing Downstream Channel Blocking the Whole Consumer."
- **Options considered (3):** per-channel consumer pools/queues (bulkhead isolation) · circuit breaker per downstream provider, failing fast to the audit store · fully async, non-blocking channel calls with a bounded per-send timeout on one shared pool
- **Decision:**
  - Chosen: per-channel bulkhead isolation (separate consumer pools for email, SMS, push) combined with a circuit breaker per downstream provider — already decided in `edge-cases.md`, restated here as the locked resilience pattern
  - Why: directly matches BRD §3's Fault Tolerance NFR and the bulkhead pattern BRD §13 already names for slow-dependency isolation; prevents one vendor outage (e.g. an SMS gateway) from starving capacity shared with email/push
  - Trade-off accepted: separate capacity to provision/monitor per channel instead of one shared pool — more operational surface, in exchange for failure containment

## Decision: Retry & DLQ Mechanism — Criticality-Tiered TTL-Ladder Parking-Lot Queues

- **Requirement driving this:** requirement-spec §3 NFR Retry/DLQ row (Tier 1: 5x + paged; Tier 2: 3x; Tier 3: 2x — each inherited verbatim from the triggering event's own catalogued BRD §10 tier, per §6 Q7); `edge-cases.md` "DLQ/Retry Policy Not Differentiated by Triggering-Event Criticality"; reusable `event-standards.md`'s RabbitMQ retry mandate.
- **Options considered (3):** TTL-ladder parking-lot retry queues per criticality tier (e.g. `retry.5s`/`retry.30s`/`retry.5m`), each terminal failure landing in its own per-consumer-queue DLQ · immediate in-place requeue on nack · an external retry/backoff library with exponential jitter run inside the consumer process before ack/nack
- **Decision:**
  - Chosen: TTL-ladder parking-lot retry queues, one ladder depth per criticality tier (Tier 1 rides the ladder up to 5 attempts + pages on final failure; Tier 2 up to 3 attempts, non-paged; Tier 3 up to 2 attempts, non-paged), with `notification.dlq` as the dedicated terminal-failure queue for send-attempt failures — distinct from, and not to be confused with, `NotificationSent`'s own separate 1x/fire-and-forget audit-publish tier (requirement-spec §6 Q6)
  - Why: applies the reusable platform default for RabbitMQ retries (`event-standards.md`: "Retry via TTL-ladder parking-lot queues... never immediate requeue"; "every consumer queue has its own DLQ") to the concrete tier counts requirement-spec §3/§6 Q7 already fixed — no new tiering scheme invented, just the concrete queueing mechanism to implement the one already decided
  - Trade-off accepted: three ladder configurations to provision and monitor instead of one uniform retry policy, in exchange for a retry budget that actually scales with the triggering event's criticality

## Decision: Consumer Concurrency & Scaling Pattern for Fan-In Volume

- **Requirement driving this:** Throughput NFR — ~200M msgs/day platform-wide, ~50,000 msgs/sec peak (requirement-spec §3); BRD §14 "throughput ceiling under heavy fan-out"; `edge-cases.md` "Consumer Overwhelmed by Event Fan-In During Traffic Spike."
- **Options considered (3):** K8s HPA-driven horizontal autoscaling on a queue-depth custom metric, combined with per-criticality queue splitting · static fixed replica count sized for peak · load-shedding — drop/degrade lowest-priority notification categories under backpressure
- **Decision:**
  - Chosen: HPA autoscaling on queue-depth metric + per-criticality queue splitting (money-moving-triggered notifications isolated from informational-triggered ones) — already decided in `edge-cases.md`, restated here as the locked concurrency/scaling pattern
  - Why: matches BRD §13's stated remedy for queue overflow directly, requires no broker change, and keeps a volume spike in one criticality tier (e.g. a flash-sale surge of `OrderCreated`) from starving Tier 1 payment-triggered sends
  - Trade-off accepted: does not remove the underlying RabbitMQ fan-out throughput ceiling (BRD §14) itself — already resolved as an accepted trade-off (§6 Q8), not a gap; this is the operational mitigation, not a structural fix

## Decision: Caching Strategy for Opt-Out Preference Lookup

- **Requirement driving this:** Domain invariant — a user's per-channel, per-category opt-out preference "must be checked and honored before any send attempt... regardless of the triggering event's own criticality tier" (requirement-spec §4); Throughput NFR (~50,000 msgs/sec peak) creates pressure to avoid a naive per-send synchronous lookup at that volume.
- **Options considered (3):** direct synchronous read against the same PostgreSQL store used for the idempotency/audit check, combined into one indexed query per send attempt · in-process or Redis cache of opt-out preferences with invalidation on preference change · preload all preferences into memory at startup with periodic full refresh
- **Decision:**
  - Chosen: no separate caching layer — a direct synchronous, indexed Postgres read against the same audit/preference store, combined with the `(eventId, channel)` idempotency check into a single query path per send attempt where practical
  - Why: the opt-out invariant is absolute ("must never dispatch... regardless of criticality tier") — any cache staleness window, even a short TTL or a startup-preload gap after a preference change, risks exactly the outcome the invariant forbids; reusing the store the idempotency check already queries avoids adding Redis purely to solve a caching problem correctness doesn't actually permit trading off
  - Trade-off accepted: one extra indexed DB read (or an extended combined query) per send attempt at up to ~50,000 msgs/sec peak, instead of the lower-latency path a cache would offer — accepted because per-channel bulkhead pools (see resilience decision above) already isolate this read's latency from cascading across channels, and correctness of "never dispatch to an opted-out channel" outweighs the raw throughput headroom a cache would buy

## Sign-off

- [ ] Reviewed by a human before the Architecture Agent runs against this service
- [ ] Chosen technologies/patterns approved
- [ ] Approved to proceed to Architecture Agent
