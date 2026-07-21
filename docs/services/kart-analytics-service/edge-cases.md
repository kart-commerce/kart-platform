---
doc_type: edge-cases
service: kart-analytics-service
status: approved
generated_by: edge-case-analyzer-agent
source: docs/services/kart-analytics-service/requirement-spec.md
---

# Edge Cases: kart-analytics-service

## Edge Case: Schema Evolution Breaking Downstream Consumers

- **What happens:** An upstream publisher changes an event's shape (renamed/removed/retyped field, new required field) with no compatibility contract, and Analytics either crashes on ingest, silently drops the event, or writes corrupted rows to the warehouse.
- **Why it happens:** Requirement-spec Domain Invariant #1 asserts schema versioning discipline is forced on Analytics (BRD §2.2), but no compatibility scheme or registry is defined anywhere in the BRD — nothing gates a publisher from shipping a breaking change before it reaches Analytics.
- **Solutions available (3):** Schema registry with enforced backward/forward compatibility checks at publish time (e.g. Avro/Protobuf + compatibility mode) · Consumer-side tolerant reader (ignore unknown fields, default missing ones) with dead-lettering on unparseable payloads · Contract tests between publisher and Analytics gating CI/CD on schema diff
- **Decision (3-5 bullets max):**
  - Chosen: Confluent-compatible schema registry (Avro payloads), enforced `BACKWARD` compatibility mode as the primary gate, plus a consumer-side tolerant reader as defense in depth.
  - Why: Requirement-spec calls this a *forced* discipline, not an optional nicety — only a registry stops a bad change before it ships, versus catching it only after Analytics already broke. The concrete format (Avro + registry-assigned schema ID as the version pointer, `MAJOR.MINOR` subject metadata for human-readable additive-vs-breaking distinction) is now decided in requirement-spec.md §6 (D2), closing the residual gap this edge case previously escalated.
  - Trade-off accepted: Every publisher now owns a schema contract and compatibility gate — added process coupling across otherwise-independent service teams. A `MAJOR` bump additionally requires a dual-publish transition window per event type, mirroring the platform's existing RabbitMQ→Kafka dual-publish precedent (BRD §15).

## Edge Case: Event Volume / Backpressure at Full Platform Fan-In

- **What happens:** At platform peak (BRD NFR: 1M RPS flash-sale burst), aggregate event volume across every publisher overwhelms Analytics' ingestion consumers, producing consumer lag, unbounded topic backlog, or warehouse write saturation.
- **Why it happens:** Analytics' load scales with total platform event volume, not one bounded stream (requirement-spec §2/§5 — fan-in from most or all published events); the BRD itself names Analytics' fan-out across 10+ consumer groups per event as the reason RabbitMQ's throughput ceiling was breached in the first place.
- **Solutions available (2):** Kafka partitioned parallel consumption with an autoscaled consumer group (already the BRD's stated direction for Analytics) · Load-shedding/sampling of low-priority events (e.g. audit-only `NotificationSent`) under sustained backlog
- **Decision (3-5 bullets max):**
  - Chosen: Kafka partitioning + horizontally autoscaled consumer group (K8s HPA on consumer-group lag), with micro-batched warehouse writes to cut write amplification.
  - Why: The requirement-spec's Throughput NFR already commits Analytics to Kafka specifically for high-throughput partitioned consumption — this follows the platform's existing decision rather than inventing a new one.
  - Trade-off accepted: No load-shedding means Analytics must be provisioned (and pay) for full-fidelity ingestion at burst volume instead of degrading gracefully when overwhelmed.

## Edge Case: Replay Correctness (Reprocessing Without Double-Counting)

- **What happens:** Reprocessing historical events (the BRD's own scenario: 30 days of `OrderCreated` after a bug fix) re-ingests events already reflected in existing dashboard/funnel aggregates, inflating metrics such as order counts or revenue.
- **Why it happens:** Replay is a BRD-mandated capability (requirement-spec FR, BRD §14), but requirement-spec Domain Invariant #3 notes nothing in a plain "sum this stream" aggregation is inherently idempotent — replaying the same events into an incrementing counter double-counts them.
- **Solutions available (2):** Idempotent upserts keyed by event ID at raw-event storage, with aggregates recomputed from raw storage rather than incrementally mutated · Replay-aware shadow-table mode: replay writes to a separate table, diffed and swapped in rather than replayed into the live aggregate path
- **Decision (3-5 bullets max):**
  - Chosen: Idempotent upserts on raw event storage (dedup by event ID), with all aggregates recomputed from raw storage rather than maintained as incrementing counters.
  - Why: This makes live ingestion and replay share one code path safely — a separate incrementing-counter path would need its own replay-safe variant that could drift from live behavior.
  - Trade-off accepted: Recomputing aggregates from raw storage costs more compute per refresh than maintaining running counters — correctness is bought with recompute cost.

## Edge Case: Out-of-Order Event Arrival Skewing Funnel/Time-Series Accuracy

- **What happens:** Events from independent publishers (or the same logical event observed twice during the RabbitMQ→Kafka dual-publish strangler window, BRD §15) arrive out of causal order — e.g. `PaymentCompleted` observed before `OrderCreated` — producing funnels with impossible sequences or time buckets that undercount/overcount a window.
- **Why it happens:** The BRD's Event Catalog gives each publisher its own independent retry/backoff policy (1x-5x depending on event), and no BRD section states a global ordering guarantee across the union of all events Analytics consumes; the dual-publish migration window (BRD §15) adds a second, transient source of skew.
- **Solutions available (3):** Event-time windowing with watermarks/allowed lateness in the stream processor · Delayed funnel computation, finalizing a stage's metrics only after a fixed grace period closes · Real-time dashboards marked "provisional," reconciled by a nightly batch recompute from the full event log
- **Decision (3-5 bullets max):**
  - Chosen: Event-time windowing with watermarks/allowed lateness, combined with nightly batch reconciliation from raw storage.
  - Why: Reuses the raw-storage-first design already chosen for replay correctness — one source of truth handles both "replay after a bug" and "events arriving late," instead of a bespoke mechanism per failure mode.
  - Trade-off accepted: Real-time dashboards stay provisional/approximate until the nightly reconciliation runs — exact funnel numbers are not available instantly.
