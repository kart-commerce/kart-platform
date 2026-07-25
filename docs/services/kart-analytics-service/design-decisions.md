---
doc_type: design-decisions
service: kart-analytics-service
status: approved
generated_by: design-decision-agent
source: [docs/services/kart-analytics-service/requirement-spec.md, docs/services/kart-analytics-service/edge-cases.md]
---

# Design Decisions: kart-analytics-service

Cross-cutting technology/pattern choices this service's approved requirement-spec.md and edge-cases.md force. Boundaries, aggregates, and schema/table design are left to the Architecture, DDD, and Database Design Agents.

## Decision: Ingestion Transport & Communication Style

- **Requirement driving this:** BRD §5.4 gives Analytics no public inbound or outbound request/response API ("ingestion only"); FR requires consuming the full platform event fan-in (ADR-0004); Domain Invariant #2 requires a durable, replayable event log; Throughput NFR requires absorbing the aggregate fan-in of every publisher.
- **Options considered (3):** Kafka partitioned consumer groups (durable log, native replay) · RabbitMQ topic-exchange fan-out (the platform's other default, per `agent-reusables/docs/standards/event-standards.md`) · synchronous pull/polling API against each publisher
- **Decision:**
  - Chosen: Kafka, consumer-only — no synchronous API of any kind, inbound or outbound.
  - Why: RabbitMQ is explicitly ruled out by BRD §14 ("no native replay... queues are consumed and gone") and §15 (its throughput ceiling was breached specifically by Analytics' fan-out); a sync polling API would contradict §5.4's "ingestion only" and can't scale to full fan-in.
  - Trade-off accepted: gives up RabbitMQ's simpler topology/ops model still used elsewhere on the platform — accepted because BRD §15 names Analytics as the first service migrated for exactly this reason.

## Decision: Concurrency / Scaling Model for Ingestion

- **Requirement driving this:** Throughput NFR ("must absorb the aggregate fan-in of every publishing service"); Edge Case "Event Volume / Backpressure at Full Platform Fan-In."
- **Options considered (2):** Kafka partitioning + horizontally autoscaled consumer group (K8s HPA on consumer-group lag) · load-shedding/sampling of low-priority events under sustained backlog
- **Decision:**
  - Chosen: Kafka partitioning + autoscaled consumer group, with micro-batched warehouse writes to cut write amplification — as already decided in the Event Volume/Backpressure edge case; not re-derived here.
  - Partition key: aggregate/entity id per the platform default (`agent-reusables/docs/standards/event-standards.md`), preserving per-entity ordering within a partition — this is what makes the replay-safe idempotent-upsert design (below) and per-entity funnel ordering tractable.
  - Why: follows the Throughput NFR's own commitment to Kafka for high-throughput partitioned consumption rather than inventing a new mechanism.
  - Trade-off accepted: no load-shedding — Analytics must be provisioned (and pay) for full-fidelity ingestion at burst volume instead of degrading gracefully when overwhelmed.

## Decision: Serialization Format & Schema Governance

- **Requirement driving this:** Domain Invariant #1 (every ingested event must carry/resolve to a schema version; multiple versions must be tolerated in flight); Maintainability NFR ("versioned events"); Edge Case "Schema Evolution Breaking Downstream Consumers"; requirement-spec §6 D2.
- **Options considered (3):** schema registry with enforced compatibility checks at publish time (Avro/Protobuf) · consumer-side tolerant reader (ignore unknown fields, default missing ones) with dead-lettering on unparseable payloads · contract tests between publisher and Analytics gating CI/CD on schema diff
- **Decision:**
  - Chosen: Confluent-compatible schema registry, Avro payloads, `BACKWARD` compatibility mode as the primary gate, plus a consumer-side tolerant reader as defense in depth — already settled in requirement-spec §6 (D2) and the Schema Evolution edge case; restated here as the service's serialization-format decision, not re-derived.
  - Versioning scheme: the registry-assigned schema ID is the wire-format version pointer (no separate hand-maintained version field); each logical event type additionally exposes a human-readable `MAJOR.MINOR` label in registry subject metadata — `MINOR` = additive-only (new optional field/enum value), compatible in place; `MAJOR` = breaking, requires a new topic/version namespace plus a dual-publish transition window mirroring the RabbitMQ→Kafka strangler precedent (BRD §15).
  - Why: only a registry stops a bad change before it ships, versus catching it only after Analytics has already broken; the tolerant reader is defense in depth for the (out-of-Analytics'-control) case a publisher slips through anyway.
  - Trade-off accepted: every publisher now owns a schema contract and CI-time compatibility gate — real process coupling across independent service teams, already accepted in principle by BRD §2.2 and made concrete here.

## Decision: Idempotency Mechanism for Replay-Safe Aggregation

- **Requirement driving this:** Reliability NFR (at-least-once delivery + idempotent consumers, applied uniformly); Domain Invariant #3 (replay must not corrupt or double-count aggregates); Edge Case "Replay Correctness (Reprocessing Without Double-Counting)."
- **Options considered (2):** idempotent upserts keyed by event ID at raw-event storage, with aggregates always recomputed from raw storage rather than incrementally mutated · replay-aware shadow-table mode (replay writes to a separate table, diffed and swapped in)
- **Decision:**
  - Chosen: idempotent upserts (dedup by event ID) at the raw-event layer; every dashboard/funnel aggregate is recomputed from raw storage, never maintained as an incrementing counter — already decided in the Replay Correctness edge case; restated here as this service's idempotency-mechanism design.
  - Why: gives live ingestion and replay one shared code path — a separate incrementing-counter path would need its own replay-safe variant that could drift from live behavior. Consistent with `agent-reusables/docs/standards/ddd-cqrs-standards.md`'s "read model always rebuildable from the write model + event log" default, applied here with the raw event log itself as that source of truth.
  - Trade-off accepted: recomputing aggregates from raw storage costs more compute per refresh than maintaining running counters — correctness is bought with recompute cost.

## Decision: Resilience Pattern — Retry & Dead-Letter Handling for Ingestion Write Failures

- **Requirement driving this:** Retry/DLQ NFR row ("Analytics-side write failures: 3x exponential backoff, then `analytics.dlq`"); Domain Invariant #4 (ingestion failures must never block or slow upstream publishers; consumer offset only advances after a successful write or a successful DLQ hand-off); requirement-spec §6 D5.
- **Options considered (3, retry-tier comparison per D5):** 1x retry then DLQ (fail-fast, too aggressive given every dashboard in D4a depends on the write succeeding eventually) · 3x exponential backoff then `analytics.dlq` · 5x retry then DLQ (the platform's highest, money-critical tier reserved for `payment.*`/`order.*`)
- **Decision:**
  - Chosen: 3x exponential-backoff retry, then hand off to `analytics.dlq` (naming per the platform's existing per-domain DLQ convention) — already settled in requirement-spec §6 (D5); restated here as this service's resilience-pattern decision.
  - Consumer offset is committed only after a successful warehouse write **or** a successful DLQ hand-off, never left uncommitted — so a stuck event cannot stall the consumer group or create redelivery pressure on upstream brokers.
  - Why 3x and not 1x or 5x: a warehouse write failure isn't money-critical the way `PaymentCompleted` is (nothing blocks on it synchronously), but every D4a dashboard depends on it eventually landing, so it isn't pure fire-and-forget either — 3x matches the platform's existing "standard business event" tier rather than either extreme.
  - Trade-off accepted: a scheduled reprocessor is required to drain `analytics.dlq` (reusing the same replay tooling as the 30-day reprocessing scenario) — DLQ'd events are not self-healing.

## Decision: Consistency Pattern for Out-of-Order Event Handling

- **Requirement driving this:** Consistency NFR (Eventual); Edge Case "Out-of-Order Event Arrival Skewing Funnel/Time-Series Accuracy" (independent publisher retry policies plus the RabbitMQ→Kafka dual-publish window both introduce transient out-of-order arrival).
- **Options considered (3):** event-time windowing with watermarks/allowed lateness in the stream processor · delayed funnel computation, finalizing a stage's metrics only after a fixed grace period closes · real-time dashboards marked "provisional," reconciled by a nightly batch recompute from the full event log
- **Decision:**
  - Chosen: event-time windowing with watermarks/allowed lateness, combined with nightly batch reconciliation from raw storage — already decided in the Out-of-Order Event Arrival edge case; restated here as this service's consistency-pattern decision.
  - Why: reuses the raw-storage-first design already chosen for replay correctness (above) — one source of truth handles both "replay after a bug" and "events arriving late," instead of a bespoke mechanism per failure mode.
  - Trade-off accepted: real-time dashboards stay provisional/approximate until the nightly reconciliation runs — exact funnel numbers are not available instantly. This eventual-consistency window must be surfaced to whatever internal query layer (D4b) is later chosen, not hidden behind a fake-precise number, per `agent-reusables/docs/standards/ddd-cqrs-standards.md`'s "surface, don't hide" CQRS default.

## Decision: Observability & Instrumentation

**Decision:** Serilog (structured logging) + OpenTelemetry SDK (distributed tracing + metrics), per the platform's reusable observability-standards.md and this repo's kart-conventions.md Observability section. Logs export via OTLP → Grafana Loki; traces via OTLP → Grafana Tempo; metrics scraped by Prometheus from `/metrics`; Grafana provides dashboards and alerting. Wired once via the shared `Kart.Shared.Observability` package, not reimplemented per service.

**Options considered:**
- Ad-hoc per-service logging/APM tool choice — rejected: fragments dashboards/alerting across 18 services and breaks single-trace-id correlation across the platform.
- Platform-standard Serilog + OpenTelemetry + Grafana LGTM stack — adopted: one mental model and one Grafana pane across every service.

**Why:** Analytics' primary correlation field is `eventId` — the ingested event's own id, the same key its idempotent-upsert dedup mechanism (this doc's "Idempotency Mechanism for Replay-Safe Aggregation" decision) already keys on, so a trace/log line for a given ingested event lines up directly with its raw-storage row. Analytics runs the standard (not 100%) sampling tier — it is a pure consumer sink, never a Saga participant. The metric worth calling out is consumer-group lag per Kafka partition (feeding the autoscaling decision above) and `analytics.dlq` depth, since both are the earliest signal of the exact backpressure/ingestion-failure scenarios this doc's Concurrency/Scaling and Resilience decisions already exist to handle.

## Out of scope for this doc (left to later stages)

- Concrete dashboard/funnel query-layer technology (internal REST/GraphQL vs. BI-tool connection) — requirement-spec §1/§5 (D4b) explicitly hands this to the Architecture/API Design Agents.
- Numeric ingestion-lag and dashboard-query latency budgets — requirement-spec §6 item 6 explicitly carries these forward, non-blocking, to the Architecture Agent for human sign-off.
- Warehouse/table schema and retention-tiering implementation — requirement-spec §6 item 3 (D3) already fixes the policy (30-day Kafka retention, indefinite raw-layer retention); the schema/table shape itself is the Database Design Agent's job.

## Decision: Global Exception Handling & Consistent Response Model

**Decision:** A single global exception-handling middleware (ASP.NET Core `IExceptionHandler`/`UseExceptionHandler`) is the only place this service catches and translates unhandled exceptions into an HTTP response — no `Handler`/controller/domain code wraps business logic in try/catch purely to log-and-rethrow or log-and-return an error. Every error response (validation failure or unhandled exception) is shaped as an RFC 7807 `ProblemDetails` envelope extended with the platform's standard fields (`traceId`, `errorCode`); every success response follows the same consistent envelope convention as every other Kart service. Both the middleware and the `ProblemDetails` factory are wired once via the shared `Kart.Shared.ErrorHandling` package, not reimplemented locally.

**Options considered:**
- Per-handler/controller try/catch translating exceptions to a response inline — rejected: duplicates translation logic per endpoint, risks inconsistent status-code/response-shape choices across handlers, and produces double-logging (or missed logging) when a local catch and the global handler both react to the same exception.
- Platform-standard global exception handler + `Kart.Shared.ErrorHandling`-wired `ProblemDetails` envelope — adopted: one place to change the error shape platform-wide, and a response contract every client (web, admin, partner API) can parse identically regardless of which of the 18 services it's calling.

**Why:** matches the same "one platform-wide implementation, not built locally by each service" pattern already applied to `Kart.Shared.Observability` and `Kart.Shared.Auditing` above — reimplementing exception translation per service is the identical per-service-drift failure mode those decisions already reject. Domain/business errors continue to use the Result/Either pattern (`agent-reusables/docs/standards/api-standards.md`) rather than exceptions; the global handler exists for the genuinely exceptional case (an unhandled infrastructure fault), and logs it exactly once — at `Error` level, tagged with `traceId`/`service` and this service's own primary correlation field named in its Observability & Instrumentation decision above — through the same Serilog/OTel pipeline, never a second, ad-hoc log line from a local catch block.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner (per `agent-reusables/agents/design-decision-agent.md`'s Human Approval Required gate).
