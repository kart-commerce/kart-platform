---
doc_type: ddd-model
service: kart-analytics-service
status: pending-approval
generated_by: ddd-agent
source: [docs/services/kart-analytics-service/requirement-spec.md, docs/services/kart-analytics-service/edge-cases.md, docs/services/kart-analytics-service/architecture.md, docs/services/kart-analytics-service/design-decisions.md, docs/services/kart-analytics-service/database-design.md, docs/services/kart-analytics-service/event-contract.md, docs/adr/0004-analytics-full-fanin-ingestion.md, docs/adr/0016-user-gdpr-erasure-policy.md]
---

# DDD Model: kart-analytics-service

**Input-freshness note:** `requirement-spec.md` and `edge-cases.md` are both `status: approved`, re-read fresh at drafting time — every item previously tracked as an Open Question is closed (§6): the "all events vs. Event Catalog" scope contradiction (Q1) via **ADR-0004**, schema versioning/evolution (Q2) via **D2** (Confluent-compatible registry, Avro, `BACKWARD` compatibility, registry-assigned schema ID + `MAJOR.MINOR` subject-metadata label), warehouse/topic retention (Q3) via **D3**, the dashboards/funnels enumeration (Q4) via **D4a** (ten concrete dashboards/funnels, listed under Read Models below), Analytics' own consumer-side failure handling (Q5) via **D5**, and the availability tier (Q6) via **D6a** (latency is explicitly carried forward, non-blocking). No stale "Open Question" language remains anywhere in the current requirement-spec.md/edge-cases.md text. `architecture.md` and `design-decisions.md` are both still `status: pending-approval` (unchecked human sign-off checkbox) but their content raises no open question and is internally consistent with the now-closed requirement-spec.md/edge-cases.md — the same already-accepted pattern `kart-delivery-tracking-service/ddd-model.md`, `database-design.md`, `event-contract.md`, and `api-contract.yaml` each record for this exact service. This model is derived directly from architecture.md's and design-decisions.md's already-decided content, not a re-decision of anything upstream.

**Pipeline-order note (why this file is being written after, not before, database-design.md/event-contract.md):** `database-design.md` and `event-contract.md` for this service were both authored citing the same precedent already used by `kart-admin-service/database-design.md` — that a Generic Subdomain service with no transactional aggregate of consequence beyond "the raw ingested event" and "the derived read model" is narrow enough to design directly, without a dedicated DDD Agent pass. That reasoning is not wrong on its own terms, but this run does add the DDD Agent pass those two docs anticipated skipping. This model is written to be **fully consistent with, not a redesign of,** the write-model schema `database-design.md` already built (`analytics_raw_events`, `analytics_dlq_events`, `analytics_reconciliation_runs`, `analytics_pii_redactions`) and the event catalog `event-contract.md` already finalized — it formalizes the DDD justification for a shape that was already implicitly correct, rather than inventing a different one. Those two docs' own header notes ("No `ddd-model.md` exists for this service") are now stale prose given this file's existence; correcting that prose is those documents' own owning agents' job on a future pass, not this file's — out of this stage's scope per `ddd-agent.md`'s output contract (this stage owns only `ddd-model.md` and the ubiquitous-language glossary).

## Boundary Summary

`kart-analytics-service` is a **Generic Subdomain** (architecture.md's Boundary Rationale): it owns no transactional business concept belonging to any other bounded context, asserts zero write authority over any other service's state, and publishes nothing back to the bus (verified against every Publisher column in the BRD's Event Catalog — restated in `event-contract.md`'s "Published Events: None"). Its bounded context is exactly two things:

1. An idempotent ingestion pipeline landing the **full platform event fan-in** ([ADR-0004](../../adr/0004-analytics-full-fanin-ingestion.md)) into a durable, replayable raw event store.
2. A set of read models (dashboards/funnels, requirement-spec §6 D4a) computed from that raw store and served through an internal-only query surface (`api-contract.yaml`).

Four aggregate roots below, each its own PostgreSQL table (`database-design.md`) and its own transaction boundary — the split is justified by the exact test in `ddd-agent.md`/`ddd-cqrs-standards.md`: if two "things" can't be saved in one transaction, they're two aggregates, not one. Each of the four already has its own independent write path in `database-design.md` (raw ingest, DLQ hand-off, reconciliation bookkeeping, PII-redaction audit) with no cross-table ACID requirement between them — see Cross-Aggregate Interaction below.

## Aggregate: IngestedEvent

**Entity:** `IngestedEvent` — identified by `EventId` (value object; the publisher-assigned event id). Backed by `analytics_raw_events` (`database-design.md`). One row per distinct event, upserted idempotently.

**Value objects:**
- `EventId` — publisher-assigned UUID; the de-dup key for idempotent upsert (edge-cases.md, "Replay Correctness").
- `SchemaVersionPointer` — `{ schemaId, versionLabel }`: `schemaId` is the Confluent schema-registry-assigned id (the de facto wire-format version pointer — no separate hand-maintained version field, requirement-spec §6 D2); `versionLabel` is the registry subject metadata's human-readable `MAJOR.MINOR` label (`MINOR` = additive-only, compatible in place; `MAJOR` = breaking, new topic/namespace + dual-publish window). This is the concrete registry/versioning scheme requirement-spec §6 D2 and the Schema Evolution edge case's escalated sub-item already decided — restated here as the value object that carries it on every `IngestedEvent` instance, not re-decided.
- `EventEnvelope` — `{ eventType, publisherService, partitionKey, occurredAt }`: the publisher-supplied metadata every event carries regardless of type; `partitionKey` is the aggregate/entity id used as the Kafka partition key (design-decisions.md, "Concurrency/Scaling"), preserving per-entity ordering.

**Fields:** `eventId`, `envelope: EventEnvelope`, `schemaVersion: SchemaVersionPointer`, `ingestedAt`, `payload` (opaque — see Modeling Decision 3), `containsPii`, `piiRedactedAt` (nullable).

**Invariants:**
- A given `EventId` may exist at most once; a redelivered or replayed event overwrites its own row rather than inserting a duplicate (idempotent upsert) — this is what lets live ingestion and replay share one code path safely without double-counting downstream aggregates (edge-cases.md, "Replay Correctness"; requirement-spec Domain Invariant #3).
- Every instance must carry a resolvable `SchemaVersionPointer` — no event is accepted without one (requirement-spec Domain Invariant #1). A publisher's schema change is rejected at publish time by the registry's `BACKWARD`-compatibility gate before it ever reaches this aggregate (D2) — this aggregate never has to reconcile an unresolvable schema itself except via the tolerant-reader defense-in-depth path (edge-cases.md).
- `payload` is never decomposed into per-domain reference fields (e.g. no modeled `orderId` FK) — see Modeling Decision 3.
- Once `containsPii = true` and a matching `PiiRedactionRecord` sweep has processed this row, PII-bearing fields inside `payload` are nulled/replaced in place and `piiRedactedAt` is set — the row is **never hard-deleted**: the Replay Correctness design recomputes every dashboard/funnel aggregate from raw storage, and hard-deleting a row would silently shrink historical aggregates on the next recompute (`database-design.md`, "PII Redaction on `UserDataErased`"; [ADR-0016](../../adr/0016-user-gdpr-erasure-policy.md)).
- Retained indefinitely once ingested (requirement-spec §6 D3) — the Replay Correctness design forbids ever deleting raw history; only the Kafka topic itself (not this aggregate) has a 30-day retention window.
- **CanRead/CanWrite/CanDelete ownership (BRD §24.1.2).** `CanWrite` (the idempotent upsert) is never end-user-facing — it is performed exclusively by this service's own ingestion pipeline consuming the full platform event fan-in (ADR-0004), gated only by the schema-registry's `BACKWARD`-compatibility check at publish time, never a caller-invoked command. `CanDelete` is never exposed to any caller, human or system — rows are only ever redacted-in-place (below), never removed, per the Replay Correctness design. `CanRead` has no per-row instance here at all: no endpoint in api-contract.yaml exposes `IngestedEvent` rows directly (only the derived, pre-aggregated MongoDB read models are queryable, gated by the `analytics.dashboards.read` scope, requirement-spec §3/§24.1.2 cross-reference) — there is no ownership-comparison question to answer for a row no caller ever reads individually.
- **Audit-actor invariant (BRD §24.3).** Every upsert stamps `created_by` at first insert and `updated_by` on every subsequent touch (a replay-driven re-upsert, or a redaction sweep) with the acting internal pipeline's own `system:*` principal id — `system:analytics-ingestion-consumer` for ingestion/replay, `system:analytics-pii-redaction-sweep` for a redaction touch — never `NULL`, since no human/API caller ever writes to this aggregate. Auto-injected by the shared `kart-shared` `Kart.Shared.Auditing` package's `SaveChanges` interceptor (§24.3) — this service has a genuine EF Core `DbContext`, unlike `kart-delivery-tracking-service`/`kart-recommendation-service`, so the interceptor mechanism applies directly, without a Mongo-driver workaround. See database-design.md.

**Domain events:**
- Consumed: the full platform event fan-in, every event in `event-contract.md`'s Consumed Events table ([ADR-0004](../../adr/0004-analytics-full-fanin-ingestion.md)) — not restated row-by-row here to avoid drifting out of sync with that document, the same reasoning requirement-spec §5 and architecture.md's Dependencies table already apply.
- Internal, this service's own (**new**, not in the BRD's Event Catalog): `EventIngested` — raised once an event is durably upserted into `analytics_raw_events`; the trigger the near-real-time incremental read-model projector (`database-design.md`) reacts to. Proposed addition to the ubiquitous language / this service's own internal event catalog — flagged for review, not blocking, the same precedent already used by `kart-delivery-tracking-service`'s `CarrierStatusIngested` and `kart-offer-service`'s `CouponRedemptionVoided`.
- Published externally: none — this aggregate, like the service as a whole, publishes nothing to the bus.

## Aggregate: DeadLetteredEvent

**Entity:** `DeadLetteredEvent` — identified by `DlqId`. Backed by `analytics_dlq_events` (`database-design.md`).

**Value objects:**
- `DlqId` — generated identifier for the DLQ row itself (distinct from the `EventId` it references).
- `FailureReason` — free-text description of why the warehouse write (or schema-registry/tolerant-reader parse) failed.

**Fields:** `dlqId`, `eventId` (reference to the `IngestedEvent` this row failed to become — see Modeling Decision 2), `eventType`, `payload`, `failureReason: FailureReason`, `retryCount`, `dlqLandedAt`, `reprocessedAt` (nullable).

**Invariants:**
- A `DeadLetteredEvent` is created only after the 3x exponential-backoff retry budget is exhausted (requirement-spec §6 D5; design-decisions.md, "Resilience Pattern") — never on the first failure.
- The Kafka consumer offset for the originating event is committed once this aggregate is successfully created (a successful DLQ hand-off), exactly as it is committed once `IngestedEvent`'s own write succeeds — never left uncommitted either way, so a stuck event can never stall the consumer group or create redelivery pressure on upstream publishers (requirement-spec Domain Invariant #4).
- `reprocessedAt` is set only once the scheduled reprocessor successfully replays this event into `IngestedEvent`; until then it stays `NULL` and the row remains in the reprocessor's pending scan (`database-design.md`'s partial index).
- This tier is uniform across every one of the ~34 consumed event types, including the money-adjacent and compliance-critical ones (`PaymentCompleted`, `ChargebackReceived`, `UserDataErased`) — their *upstream* delivery-to-Analytics retry tier is a separate, publisher-side concern (`event-contract.md`); this aggregate's own creation trigger never varies by event type (requirement-spec §6 D5; architecture.md's Non-Functional Targets section).
- **CanRead/CanWrite/CanDelete ownership (BRD §24.1.2).** `CanWrite` (DLQ hand-off, and the reprocessor's later replay) is gated identically to `IngestedEvent` above — only this service's own internal ingestion/reprocessing pipeline may write here. `CanDelete` is never exposed. `CanRead` has no client-facing endpoint at all — this is a purely operational table read only by the scheduled reprocessor itself, the same "no ownership concept, no end-user reader" carve-out as `IngestedEvent`.
- **Audit-actor invariant (BRD §24.3).** `created_by` stamps `system:analytics-ingestion-consumer` (the pipeline that exhausted its retry budget and created this row) at insert; `updated_by` stamps `system:analytics-dlq-reprocessor` when `reprocessedAt` is set. Never `NULL`; auto-injected by the shared `kart-shared` interceptor, same as `IngestedEvent` — see database-design.md.

**Domain events:**
- Internal, this service's own (**new**): `EventDeadLettered` — raised on creation (the DLQ hand-off itself). `EventReprocessed` — raised once the scheduled reprocessor successfully replays this row back into `IngestedEvent` and sets `reprocessedAt`. Both proposed additions, flagged for review, not blocking.

## Aggregate: ReconciliationRun

**Entity:** `ReconciliationRun` — identified by `RunDate`. Backed by `analytics_reconciliation_runs` (`database-design.md`).

**Value objects:**
- `RunDate` — the calendar date (event-time) this run reconciles.
- `RunStatus` — `running | completed | failed`.

**Fields:** `runId`, `runDate: RunDate`, `startedAt`, `completedAt` (nullable), `status: RunStatus`.

**Invariants:**
- At most one `ReconciliationRun` per `RunDate` (DB-enforced `UNIQUE(run_date)`) — prevents a double-run for the same date, which would otherwise double-write reconciled read-model documents for the same time bucket (`database-design.md`).
- `status` only ever transitions `running → completed` or `running → failed`, never regresses from a terminal state back to `running` for the same `RunDate` — a failed run is retried as a fresh attempt against the same `RunDate` row, not resurrected in place (architecture.md's proposed 06:00 UTC completion target; edge-cases.md, "Out-of-Order Event Arrival").
- Completion of a run is what flips every read-model document's `isProvisional` flag to `false` and sets its `reconciledThrough` — this aggregate's own completion is the trigger, not a side effect the read models decide on their own (`ddd-cqrs-standards.md`'s "surface, don't hide" eventual-consistency rule, already applied in `database-design.md`'s envelope fields).
- **CanRead/CanWrite/CanDelete ownership (BRD §24.1.2).** `CanWrite` (run creation and status transition) is performed exclusively by the scheduled nightly batch reconciler process — no caller ever creates or mutates a `ReconciliationRun` directly. `CanDelete` is never exposed. `CanRead` has no dedicated client-facing endpoint; a run's `reconciledThrough`/`isProvisional` state surfaces indirectly through the `DashboardEnvelope` fields on every dashboard/funnel response (already gated by the same `analytics.dashboards.read` scope as `IngestedEvent`'s read path), not through a direct query against this table.
- **Audit-actor invariant (BRD §24.3).** `created_by` stamps `system:analytics-reconciliation-job` at run creation (`status = running`); `updated_by` stamps the same principal on every status transition (`→ completed` or `→ failed`). Never `NULL`; auto-injected by the shared `kart-shared` interceptor — see database-design.md.

**Domain events:**
- Internal, this service's own (**new**): `ReconciliationCompleted` — raised when `status` transitions to `completed`; the signal the nightly batch reconciler's read-model write step reacts to. Proposed addition, flagged for review, not blocking.

## Aggregate: PiiRedactionRecord

**Entity:** `PiiRedactionRecord` — identified by `RedactionId`. Backed by `analytics_pii_redactions` (`database-design.md`). Immutable once written — an audit record, never updated or deleted.

**Value objects:**
- `RedactionId` — generated identifier for the audit record.

**Fields:** `redactionId`, `userId`, `triggeringEventId` (the `UserDataErased` event id that triggered this sweep), `rowsRedacted`, `redactedAt`.

**Invariants:**
- Created only in direct response to consuming `UserDataErased` for a given `userId` ([ADR-0016](../../adr/0016-user-gdpr-erasure-policy.md) item 6; `database-design.md`, "PII Redaction on `UserDataErased`") — never created speculatively or on a schedule.
- Immutable once written: this is the compliance-facing record of "this user's data was redacted, when" — it is never edited retroactively, even if a later sweep processes additional rows for the same `userId` (e.g. late-arriving events for that user); a later sweep produces its own new `PiiRedactionRecord` row rather than mutating an earlier one.
- `rowsRedacted` reflects exactly the count of `IngestedEvent` rows this specific sweep touched — a factual count, not a running total across sweeps.
- **CanRead/CanWrite/CanDelete ownership (BRD §24.1.2).** `CanWrite` (creation, the only mutation this aggregate ever undergoes) is performed exclusively by the internal redaction-sweep process reacting to `UserDataErased` — never a caller-invoked command, and never re-triggerable for an already-processed sweep. `CanDelete` is never exposed — this is a permanent compliance audit trail. `CanRead` has no client-facing endpoint at all (no dashboard/funnel in api-contract.yaml surfaces this table); it exists purely for internal compliance/audit lookup, the same operator-only access pattern BRD §24.1.5 already applies to Admin's `admin_actions.metadata`.
- **Audit-actor invariant (BRD §24.3).** `created_by` stamps `system:analytics-pii-redaction-sweep` at creation — never `NULL`. No `updated_by` applies: this aggregate is immutable once written (the invariant above), so there is no "most recent update" to attribute, the same treatment `kart-delivery-tracking-service`'s append-only `TrackingStatusHistory` entries receive. Auto-injected by the shared `kart-shared` interceptor — see database-design.md.

**Domain events:**
- Consumed: `UserDataErased` (external — owned by `kart-user-service`; the sweep-triggering event, per ADR-0016 item 6's explicit statement that "Analytics consumes `UserDataErased` under its standing full fan-in default — additive, not a special case").
- Internal, this service's own (**new**): `UserDataRedacted` — raised once a redaction sweep for a given `userId` completes across every matching `IngestedEvent` row, immediately before this aggregate's own record is written. Named to parallel `UserDataErased` (the event that triggers it) while remaining Analytics' own internal signal, never published externally. Proposed addition, flagged for review, not blocking.

## Read Models (CQRS projections — not aggregates)

The ten dashboard/funnel collections requirement-spec §6 D4a enumerates and `database-design.md` already builds as MongoDB collections (`order_conversion_funnel`, `revenue_dashboard`, `fulfillment_performance_dashboard`, `inventory_movement_dashboard`, `catalog_pricing_dashboard`, `promotions_effectiveness_dashboard`, `user_growth_dashboard`, `reviews_ratings_dashboard`, `admin_audit_log`, `notification_delivery_dashboard`) are **deliberately not modeled as aggregates here**. Per `ddd-cqrs-standards.md`, "read model is always rebuildable from the write model + event log" and is "never written to outside a projection consumer" — these collections have no domain invariant of their own beyond "faithfully reflects a recomputation of `IngestedEvent`," enforced entirely by the two projection consumers (`EventIngested`-driven incremental projector; `ReconciliationCompleted`-driven nightly batch reconciler), never by a command directly against the collection. There is nothing here for an aggregate boundary/transaction-boundary test to apply to — they are derived data, not a transactional consistency boundary — so introducing a fifth "aggregate" to represent them would be modeling a projection as if it had write-side invariants it does not have.

## Cross-Aggregate Interaction

The ingestion pipeline touches at most two of the four aggregates per consumed event, as two mutually exclusive outcomes, never one shared transaction:

1. **Happy path:** the event is upserted into `IngestedEvent` (idempotent by `EventId`). The Kafka offset is committed. `EventIngested` fires, driving the incremental read-model projector.
2. **Failure path:** after the 3x exponential-backoff retry budget is exhausted, a `DeadLetteredEvent` is created instead (referencing the same `EventId` by value, not by a transactional foreign key — the `IngestedEvent` row was never successfully written in this path, so no FK could hold). The Kafka offset is committed on this successful DLQ hand-off instead. `EventDeadLettered` fires.

These are two independent aggregate writes gated by which one succeeds — never both, never a joint transaction — which is exactly why `EventId` is referenced by value on `DeadLetteredEvent` rather than enforced as a foreign key against `IngestedEvent` (requirement-spec Domain Invariant #4; `database-design.md`'s schema already reflects this: no FK constraint between the two tables).

The scheduled reprocessor later replays a `DeadLetteredEvent` row through the same ingestion code path, which (if it now succeeds) creates the corresponding `IngestedEvent` row and sets `reprocessedAt` on the `DeadLetteredEvent` row — again two separate writes, not one transaction, tied together only by the shared `EventId` value and the `EventReprocessed` signal.

`ReconciliationRun` never writes to `IngestedEvent`, `DeadLetteredEvent`, or the read-model collections directly — it only records that a reconciliation pass happened. The nightly batch reconciler (an external process, not this aggregate) reads across many `IngestedEvent` rows and writes the read-model documents; `ReconciliationRun.status` transitioning to `completed` is the signal, not the mechanism, per the CQRS "read model rebuilt by a projection consumer" rule.

A `PiiRedactionRecord` sweep is a **domain process operating across many `IngestedEvent` instances, not a single aggregate transaction**: each matching `IngestedEvent` row is redacted with its own independent, idempotent update (safe to retry/resume if interrupted partway, since redaction is itself just another field-level upsert keyed by `EventId`), and exactly one `PiiRedactionRecord` is written once the sweep completes. This deliberately does not attempt one all-or-nothing transaction across a potentially unbounded number of `IngestedEvent` rows — consistent with the transaction-boundary test (a redaction sweep touching thousands of rows could never realistically be one ACID transaction) and with `database-design.md`'s own row-by-row redaction design.

## Referenced Elsewhere (owned by another bounded context — accessed via ACL, not redefined here)

Unlike other services in this pipeline, `kart-analytics-service` does **not** decompose any consumed event's payload into modeled reference fields (e.g. no `IngestedEvent.orderId`, no `IngestedEvent.userId` as a first-class typed reference). Every consumed event's payload is stored as opaque `JSONB` on `IngestedEvent` (see Modeling Decision 3) — this **is** this bounded context's Anti-Corruption Layer: it never imports or re-models Order's, Payment's, Product's, User's, or any of the other ~14 publishing contexts' own domain concepts (their aggregates, invariants, or lifecycles), it only durably lands and later recomputes over their event payloads as inert data. There is accordingly no per-term reference table here the way `kart-delivery-tracking-service/ddd-model.md` has one for `Order`/`Shipment` — every publishing context's terms remain entirely theirs, referenced only implicitly through `EventEnvelope.eventType`/`publisherService`, never redefined or partially modeled here. The full, current list of publishing contexts and their events is `event-contract.md`'s Consumed Events table, not restated here.

## Modeling Decisions & Assumptions (resolved here, not escalated — engineering defaults, revisable)

1. **Four aggregates, not one (transaction-boundary test applied).** `IngestedEvent`, `DeadLetteredEvent`, `ReconciliationRun`, and `PiiRedactionRecord` are modeled as four separate aggregate roots because none of their invariants ever require a cross-table ACID transaction — confirmed directly by `database-design.md`'s already-built schema (four independent tables, no FK between `analytics_raw_events` and `analytics_dlq_events`) and by the Cross-Aggregate Interaction section above. Merging any two (e.g. folding DLQ handling into `IngestedEvent` as a status field) would force the ingestion write path to decide up front which shape it needs before either write, which is exactly backwards from D5's actual retry-then-park sequencing.
2. **Read models are projections, not aggregates (restated as its own decision, not merely descriptive).** This is a direct application of `ddd-cqrs-standards.md`'s CQRS rule to this service's own boundary: the ten dashboard/funnel collections have no invariant of their own to enforce at write time because nothing ever writes to them except the two projection consumers reacting to `EventIngested`/`ReconciliationCompleted`. Modeling them as aggregates would invite a future implementer to accept direct writes against them, which is the exact anti-pattern the standard forbids.
3. **`payload` is opaque JSONB, never decomposed (Q1/ADR-0004's consequence, made explicit here).** Because `IngestedEvent` must accept literally every platform event type by design (ADR-0004's full fan-in, no per-event-type allowlist), and because Analytics owns none of those events' actual domain concepts, decomposing `payload` into typed per-domain reference fields would require this bounded context to import ~15 other contexts' own field shapes — a direct violation of "reference through an ACL, never redefine" (`ddd-agent.md`). The `EventEnvelope`'s `eventType`/`publisherService` are the only structured metadata modeled; everything else stays inside the registry-validated, opaque `payload`. This is why there is no `Order`/`Payment`/`Product` reference table in this document the way other services have one.
4. **Internal domain events are proposed additions, not escalations.** `EventIngested`, `EventDeadLettered`, `EventReprocessed`, `ReconciliationCompleted`, and `UserDataRedacted` are all new, internal-only signals not present in the BRD's Event Catalog and never published externally — the same treatment `kart-delivery-tracking-service` gave `CarrierStatusIngested`/`UnmappedCarrierStatusFlagged` and `kart-offer-service` gave `CouponRedemptionVoided`/`PromotionDeactivated`. None of these change `event-contract.md`'s "Published Events: None" — they never cross this bounded context's own boundary.
5. **Dashboards/funnels enumeration (D4a) and schema-versioning scheme (D2) are cited, not re-decided.** Both were already closed in requirement-spec.md §6 before this stage ran; this document's only job regarding them was to give them a concrete DDD shape (`SchemaVersionPointer` value object for D2; the ten named read-model projections for D4a), consistent with `database-design.md`'s and `event-contract.md`'s own already-built artifacts, not to reopen either decision.

## Sign-off

- [ ] Reviewed by: _pending human review_
- [ ] Approved to proceed to API/Database/Event Design Agents
