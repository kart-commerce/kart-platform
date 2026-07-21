---
doc_type: design-decisions
service: kart-analytics-service
status: pending-approval
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

## Out of scope for this doc (left to later stages)

- Concrete dashboard/funnel query-layer technology (internal REST/GraphQL vs. BI-tool connection) — requirement-spec §1/§5 (D4b) explicitly hands this to the Architecture/API Design Agents.
- Numeric ingestion-lag and dashboard-query latency budgets — requirement-spec §6 item 6 explicitly carries these forward, non-blocking, to the Architecture Agent for human sign-off.
- Warehouse/table schema and retention-tiering implementation — requirement-spec §6 item 3 (D3) already fixes the policy (30-day Kafka retention, indefinite raw-layer retention); the schema/table shape itself is the Database Design Agent's job.

## Sign-off

- [ ] Reviewed by a human before the Architecture Agent runs against this service (per `agent-reusables/agents/design-decision-agent.md`'s Human Approval Required gate).
