---
doc_type: database-design
service: kart-analytics-service
status: approved
generated_by: database-design-agent
source: docs/services/kart-analytics-service/requirement-spec.md, docs/services/kart-analytics-service/edge-cases.md, docs/services/kart-analytics-service/design-decisions.md, docs/services/kart-analytics-service/architecture.md, docs/services/kart-analytics-service/ddd-model.md, docs/services/kart-analytics-service/api-contract.yaml, docs/adr/0004-analytics-full-fanin-ingestion.md, docs/adr/0016-user-gdpr-erasure-policy.md
---

# Database Design: kart-analytics-service

**Superseded note (corrected on this pass):** this section previously read "No `ddd-model.md` exists for this service," citing the same precedent recorded in `kart-admin-service/database-design.md`. `docs/services/kart-analytics-service/ddd-model.md` has since been authored (its own "Pipeline-order note" explicitly flags that this prose was stale and hands the correction to this document's owning agent) — that prose is now corrected in place rather than left to drift. `ddd-model.md`'s Boundary Summary confirms the same shape this document already assumed: `architecture.md`'s Boundary Rationale fixes Analytics' domain shape as a **Generic Subdomain** with exactly two responsibilities — (1) an idempotent ingestion pipeline landing the full platform event fan-in ([ADR-0004](../../adr/0004-analytics-full-fanin-ingestion.md)) into a raw event store, and (2) a set of read models (dashboards/funnels, requirement-spec.md §6 D4a) computed from that raw store. `ddd-model.md` formalizes this as **four aggregate roots** — `IngestedEvent`, `DeadLetteredEvent`, `ReconciliationRun`, `PiiRedactionRecord` — each mapping 1:1 onto a table already built below (`analytics_raw_events`, `analytics_dlq_events`, `analytics_reconciliation_runs`, `analytics_pii_redactions` respectively), with `SchemaVersionPointer`/`EventEnvelope` value objects matching this document's `schema_id`/`schema_version_label`/`event_type`/`publisher_service`/`partition_key`/`occurred_at` columns field-for-field. No schema rework was needed to reconcile the two documents — `ddd-model.md` was written to be consistent with this already-built schema, not the other way around — so this write-model design stands as previously drafted.

**Approval status (updated on this pass):** `architecture.md` and `design-decisions.md` are now both `status: approved`, consistent with `requirement-spec.md`/`edge-cases.md`. This design was derived directly from their already-decided content (D2 schema registry/versioning, D3 retention, D4a/D4b dashboards and query surface, D5 retry/DLQ, the Out-of-Order/replay decisions) and required no substantive rework once they were confirmed.

**Resolved contradictions/gaps this stage relied on directly rather than re-deciding:**
- *"All events" vs. Event Catalog scope* — settled by [ADR-0004](../../adr/0004-analytics-full-fanin-ingestion.md); the raw event store below has no per-event-type allowlist, it accepts any event type by design (schema-registry-gated, not catalog-gated).
- *Schema versioning/evolution policy* — settled by requirement-spec.md §6 D2 / design-decisions.md's "Serialization Format & Schema Governance": Confluent-compatible registry, Avro payloads, `BACKWARD` compatibility mode, registry-assigned schema ID as the wire-format version pointer, human-readable `MAJOR.MINOR` subject-metadata label (additive-only within a `MINOR`, new topic/namespace + dual-publish window on `MAJOR`). This stage's only job is to make sure the raw-event table actually persists that schema ID/version-label metadata per row (see `analytics_raw_events` below) — not to re-pick a registry format.
- *Dashboards/funnels not enumerated* — settled by requirement-spec.md §6 D4a and already turned into ten concrete endpoints in `api-contract.yaml`. The MongoDB read model below has one collection per already-enumerated endpoint; no new dashboard is invented here.
- *`UserDataErased` warehouse-copy redaction, left open by `architecture.md`'s "Full Fan-In Completeness Check"* — this stage closes it (see "PII Redaction on `UserDataErased`" below), since architecture.md explicitly handed it to "the DDD/Database Design Agent stages."

Write model is **PostgreSQL** (source of truth) for the raw event store, the dead-letter table, and reconciliation-run bookkeeping. Read model is **MongoDB**, one collection per dashboard/funnel enumerated in `api-contract.yaml`, always rebuilt from the PostgreSQL raw-event store by two projection consumers (a near-real-time incremental projector and the nightly batch reconciler) — never written to directly by the query API, per `agent-reusables/docs/standards/ddd-cqrs-standards.md`'s "read model always rebuildable from the write model + event log, never written to outside a projection consumer."

## Write Model (PostgreSQL)

```sql
-- Raw ingested event store — the single source of truth every dashboard/funnel read model is
-- recomputed from (design-decisions.md "Idempotency Mechanism for Replay-Safe Aggregation";
-- edge-cases.md "Replay Correctness"). Idempotent upsert keyed by event_id: a redelivered or
-- replayed event overwrites its own row rather than inserting a duplicate, which is what makes
-- live ingestion and replay share one code path safely.
CREATE TABLE analytics_raw_events (
    event_id            UUID PRIMARY KEY,             -- publisher-assigned event id; the de-dup key (Replay Correctness decision)
    event_type          TEXT NOT NULL,                -- e.g. 'OrderCreated', 'PaymentCompleted' — no allowlist; full fan-in per ADR-0004
    publisher_service   TEXT NOT NULL,                -- e.g. 'kart-order-service' — informational, for the completeness audits architecture.md already runs
    partition_key       TEXT NOT NULL,                -- aggregate/entity id used as the Kafka partition key (design-decisions.md "Concurrency/Scaling" decision) — preserves per-entity ordering
    schema_id           TEXT NOT NULL,                -- Confluent schema-registry-assigned id; the wire-format version pointer (requirement-spec.md §6 D2) — no separate hand-maintained version field
    schema_version_label TEXT NOT NULL,               -- registry subject metadata's human-readable MAJOR.MINOR label (D2) — lets ingestion/ops distinguish an additive MINOR bump from a breaking MAJOR one in flight
    occurred_at         TIMESTAMPTZ NOT NULL,          -- event-time (publisher's own timestamp) — the basis for event-time windowing/watermarks (edge-cases.md "Out-of-Order Event Arrival")
    ingested_at         TIMESTAMPTZ NOT NULL DEFAULT now(), -- Analytics' own landing time — the partitioning key below, and the basis for the P95<60s/P99<5min ingestion-lag target (architecture.md)
    payload             JSONB NOT NULL,               -- the event's own schema-registry-validated body
    contains_pii        BOOLEAN NOT NULL DEFAULT false, -- true for event types that can carry end-user PII (UserRegistered, SessionCreated, ReviewSubmitted, UserProfileUpdated, etc.) — drives the redaction sweep below
    pii_redacted_at      TIMESTAMPTZ NULL,              -- set once this row's PII fields have been redacted in response to a UserDataErased event for the same user (see "PII Redaction" below); NULL = not yet redacted (or never contained PII)
    created_by          TEXT NOT NULL,                 -- BRD §24.3 — always "system:analytics-ingestion-consumer"; no human/API caller ever writes this row
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(), -- BRD §24.3 — new column, distinct from ingested_at (which keeps its existing "first landing time" meaning); bumped on a replay-driven re-upsert or a redaction sweep touch
    updated_by          TEXT NOT NULL                  -- BRD §24.3 — "system:analytics-ingestion-consumer" on a replay re-upsert, "system:analytics-pii-redaction-sweep" on a redaction touch
) PARTITION BY RANGE (ingested_at);

-- Partitioned by ingestion date (requirement-spec.md §6 D3: "raw-event layer retains ingested
-- events indefinitely ... partitioned by ingestion date, tiered hot/cold storage as a later cost
-- detail"). Monthly partitions shown; a scheduled job creates the next partition ahead of time
-- and detaches/tiers partitions older than the active hot window to cold storage without deleting
-- them — indefinite retention is a hard requirement of the Replay Correctness design (aggregates
-- are always recomputed from raw storage, never incrementally mutated), so old partitions are
-- moved, never dropped.
CREATE TABLE analytics_raw_events_2026_07 PARTITION OF analytics_raw_events
    FOR VALUES FROM ('2026-07-01') TO ('2026-08-01');

-- The query pattern every projector (real-time incremental + nightly reconciliation batch) runs:
-- "give me every event of type X, in event-time order, since the last watermark." This is the one
-- index every dashboard/funnel computation in D4a depends on.
CREATE INDEX idx_analytics_raw_events_type_occurred
    ON analytics_raw_events (event_type, occurred_at);

-- Supports the redaction sweep's own query ("find every not-yet-redacted PII-bearing row") without
-- a full-table scan across an indefinitely-retained table.
CREATE INDEX idx_analytics_raw_events_pii_pending
    ON analytics_raw_events (contains_pii)
    WHERE contains_pii = true AND pii_redacted_at IS NULL;

-- Dead-letter table for ingestion write failures (requirement-spec.md §6 D5; design-decisions.md
-- "Resilience Pattern"): after 3x exponential-backoff retry, the raw event is parked here instead
-- of dropped, and the consumer offset is committed anyway (Domain Invariant #4) so a stuck event
-- never stalls the consumer group. A scheduled reprocessor drains this table using the same replay
-- tooling as the 30-day reprocessing scenario (BRD §14).
CREATE TABLE analytics_dlq_events (
    dlq_id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id            UUID NOT NULL,                -- the event_id that failed to write to analytics_raw_events
    event_type          TEXT NOT NULL,
    payload             JSONB NOT NULL,
    failure_reason      TEXT NOT NULL,
    retry_count         INT NOT NULL,                 -- always 3 at hand-off time per D5, kept as a column rather than a hardcoded assumption in case the tier is revisited later
    dlq_landed_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    reprocessed_at      TIMESTAMPTZ NULL,             -- set once the scheduled reprocessor successfully replays this event into analytics_raw_events
    created_by          TEXT NOT NULL,                -- BRD §24.3 — "system:analytics-ingestion-consumer" (the pipeline that exhausted its retry budget and created this row)
    updated_by          TEXT NOT NULL                 -- BRD §24.3 — never NULL, per the platform-wide convention: set equal to created_by at insert, then overwritten to "system:analytics-dlq-reprocessor" once reprocessed_at is set
);

-- The reprocessor's own scan: "find everything still parked, oldest first."
CREATE INDEX idx_analytics_dlq_events_pending
    ON analytics_dlq_events (dlq_landed_at)
    WHERE reprocessed_at IS NULL;

-- Bookkeeping for the nightly batch reconciliation run (edge-cases.md "Out-of-Order Event
-- Arrival"; architecture.md's proposed 06:00 UTC completion target). This is what the MongoDB
-- read model's `reconciledThrough` field (api-contract.yaml DashboardEnvelope) is ultimately
-- sourced from — an operational audit trail of reconciliation runs, not a customer-facing table.
CREATE TABLE analytics_reconciliation_runs (
    run_id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    run_date            DATE NOT NULL,                -- the calendar date this run reconciles (event-time)
    started_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at        TIMESTAMPTZ NULL,
    status              TEXT NOT NULL DEFAULT 'running' CHECK (status IN ('running', 'completed', 'failed')),
    created_by          TEXT NOT NULL,                -- BRD §24.3 — always "system:analytics-reconciliation-job"
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(), -- BRD §24.3 — new column, distinct from completed_at (which stays NULL until a successful completion specifically); bumped on every status transition, including running → failed
    updated_by          TEXT NOT NULL,                -- BRD §24.3 — same principal, set equal to created_by at insert, overwritten on every status transition (→ completed / → failed)
    UNIQUE (run_date)
);

-- Audit trail of PII redaction sweeps triggered by UserDataErased (ADR-0016 item 6), independent
-- of any one raw_events row — the compliance-facing record of "this user's data was redacted, when."
CREATE TABLE analytics_pii_redactions (
    redaction_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id             TEXT NOT NULL,
    triggering_event_id UUID NOT NULL,                -- the UserDataErased event_id that triggered this sweep
    rows_redacted        INT NOT NULL,                 -- count of analytics_raw_events rows touched by this sweep, for compliance reporting
    redacted_at         TIMESTAMPTZ NOT NULL DEFAULT now(), -- this is the BRD §24.3 created_at equivalent, kept under its existing domain name rather than duplicated
    created_by          TEXT NOT NULL                 -- BRD §24.3 — always "system:analytics-pii-redaction-sweep". No updated_at/updated_by column: this row is immutable once written (ddd-model.md's own invariant), so there is no "most recent update" to attribute
);

CREATE INDEX idx_analytics_pii_redactions_user
    ON analytics_pii_redactions (user_id, redacted_at);
```

### PII Redaction on `UserDataErased` (closing architecture.md's carried-forward gap)

`architecture.md`'s "Full Fan-In Completeness Check" explicitly left open "whether Analytics' own warehouse copy [of `UserDataErased`-triggered PII] is redacted or merely tagged for exclusion from future reporting," handing it to the DDD/Database Design Agent stages. **Decision: redact in place, don't hard-delete, and don't merely tag-for-exclusion.**

- On consuming `UserDataErased` for a given `user_id`, a redaction sweep updates every `analytics_raw_events` row where `contains_pii = true` and the payload's `userId` matches: known PII fields inside the JSONB `payload` (e.g. email, name, free-text review body) are nulled/replaced with a redaction placeholder, `pii_redacted_at` is set, and one `analytics_pii_redactions` row is written recording the sweep.
- **Why redact rather than hard-delete the row:** the Replay Correctness design (edge-cases.md) recomputes every dashboard/funnel aggregate from raw storage, never from an incrementally-mutated counter. Hard-deleting a user's `OrderCreated`/`PaymentCompleted` rows would silently shrink historical revenue/order-count aggregates on the next recompute — a correctness regression the replay design was built specifically to avoid. Redacting the PII fields while preserving the non-PII facts (order totals, timestamps, event type) keeps every D4a aggregate stable across replay while still satisfying GDPR erasure for the actual personal data.
- **Why not merely tag-for-exclusion (keep the PII, just flag it):** that satisfies neither GDPR's actual erasure requirement nor the redact intent behind ADR-0016 — the raw PII would still exist at rest, just filtered out at query time, which is a weaker guarantee than the platform's other erasure handling (ADR-0016) provides everywhere else. Redaction-in-place is consistent with treating Analytics' warehouse copy the same as any other service's copy of that data under ADR-0016, not carving out a laxer exception just because Analytics' copy is a read-only reporting sink.
- This is a single-service (Analytics' own warehouse schema) decision, not a new ADR: ADR-0016 already established the platform-wide erasure obligation; this only decides *how* Analytics' own raw-event schema satisfies it.

## Row-Level Security Policy (BRD §24.1.4)

Per BRD §24.1.4, the service whose database physically holds a row decides and enforces that row's row-level security. Analytics' write model is PostgreSQL, so native RLS is the mechanism this platform defaults to — but **none of the four tables above has a per-row end-user ownership concept for a `CREATE POLICY` to key on**, and no policy is added for any of them, for reasons specific to each:

- **`analytics_raw_events`** — a single row's `payload` may reference any number of end users depending on `event_type` (an `OrderCreated` payload names a customer; an `AdminActionPerformed` payload names an admin; a `CategoryUpdated` payload names none at all), and that reference lives inside opaque, schema-varying JSONB, never a first-class `user_id` column (ddd-model.md Modeling Decision 3: "`payload` is opaque JSONB, never decomposed"). There is no queryable column to key a row-ownership policy on even if one were wanted, and — decisively — no end user or Support Agent ever queries this table directly at all: the only readers are this service's own two projection consumers and the redaction sweep (all internal, all already trusted call sites), and the only external-facing surface is the derived MongoDB read models, gated by scope (§24.1.2 above), not row ownership.
- **`analytics_dlq_events`, `analytics_reconciliation_runs`** — pure operational bookkeeping tables with no per-user semantic at all; the same "no per-row ownership concept" carve-out BRD §24.1.4 itself anticipates for tables like Payment's `payment_intents`.
- **`analytics_pii_redactions`** — the one table with a `user_id` column, but it identifies the *data subject of a compliance record*, not a caller who ever queries their own row: no endpoint anywhere in `api-contract.yaml` exposes this table to any caller, internal or external, so a `user_id`-keyed `CREATE POLICY` would gate a query that structurally cannot happen. If a future compliance-reporting endpoint against this table is ever added, this document will need to revisit that decision then, against whatever caller the new endpoint actually has.

**What actually protects these tables today, in the absence of a row-ownership policy:** (1) there is no public API Gateway route to any of them at all (requirement-spec.md §1); (2) the one client-facing surface, the MongoDB dashboards, is gated by the `analytics.dashboards.read` scope check (§24.1.2 above) before a request ever reaches a query; (3) direct database access is restricted to this service's own application role, per the column-level `GRANT` control below. This mirrors the reasoning `kart-identity-service/database-design.md` already gives for its own `service_principals`/`idp_group_role_mappings` tables — RLS is additive protection against a *specific* failure mode (a user-facing code path forgetting its own `WHERE` clause), and that failure mode cannot occur on a table with no user-facing code path in the first place.

## Sensitive / PII Column Classification (BRD §24.1.5)

Column-level security answers a narrower question than row-level security: of the columns in a row a caller already has `CanRead` on (BRD §24.1.2), which does that caller's own coarse role actually see — full value, masked, or nothing. Analytics' primary PII control predates this cross-cutting pass (the ADR-0016 redaction sweep below); this section cross-references it rather than layering a competing masking rule on top.

| Column | Full Value Visible To | Masked/Omitted For | Masking Rule |
|---|---|---|---|
| `analytics_raw_events.payload` (rows where `contains_pii = true`, before `pii_redacted_at` is set) | No one, via any API response, ever | Every role, including Admin | Never returned by any endpoint in `api-contract.yaml` — only the ten pre-aggregated MongoDB dashboard/funnel collections are queryable, none of which re-expose raw payload fields. Not a masking rule so much as the column never appearing in any response DTO in the first place, the same "never-serialized rather than merely role-masked" treatment `kart-identity-service/database-design.md` applies to its own credential columns. The column's PII content is additionally destroyed at rest once `pii_redacted_at` is set (ADR-0016 sweep, above) — a stronger, permanent guarantee than any role-based masking rule, since a redacted value cannot be un-masked by any role, ever |
| `admin_audit_log.adminId` (MongoDB read model) | Any caller holding the `analytics.dashboards.read` scope (internal-only; §24.1.2 above) | Every caller outside that scope (this endpoint has no public Gateway route at all) | An internal-staff identifier, not customer PII — visible to any authorized internal/BI caller the same way BRD §24.1.5's own worked example scopes Admin Service's `admin_actions.metadata` to grant-holders rather than the general public |

**Why this list and no more:** every other column across all four PostgreSQL tables and all ten MongoDB dashboard/funnel collections is either an opaque identifier (`event_id`, `dlq_id`, `run_id`, `redaction_id`), operational metadata (`schema_id`, `retry_count`, `status`), or a pre-aggregated count/bucket (`revenue`, `orderCount`, `ratingDistribution`) — none of it is personal data about an identifiable individual. `analytics_pii_redactions.user_id` itself is not classified as a masked column here because, per the Row-Level Security Policy section above, no endpoint exposes this table to any caller at all — there is no response DTO for a masking rule to apply to yet.

**Enforcement point:** primarily the absence of any response DTO for `analytics_raw_events`/`analytics_pii_redactions` in `api-contract.yaml` (§24.1.5's stated primary control — a field that never appears in a response needs no masking rule), combined with the ADR-0016 redaction-in-place sweep for the PII that does exist at rest; secondarily, for any direct database connection bypassing this service's own ingestion/query code (an ops/BI tooling query against PostgreSQL directly), native `GRANT SELECT` restricted to exclude `analytics_raw_events.payload` for any database role other than this service's own application/reconciliation roles, mirroring how §24.1.5 layers native column-level privileges underneath the primary API-level control for every other PostgreSQL-backed service.

## Read Model (MongoDB)

One collection per dashboard/funnel already enumerated in requirement-spec.md §6 D4a and exposed as an endpoint in `api-contract.yaml`. Every collection is rebuilt from `analytics_raw_events` by exactly two projection consumers, never written to by the query API directly (`ddd-cqrs-standards.md`):

1. **Near-real-time incremental projector** — consumes newly-landed rows and upserts provisional bucket documents, targeting the architecture.md-proposed dashboard/funnel query budget (P95 < 2s / P99 < 5s) by keeping documents pre-aggregated rather than computed per-request.
2. **Nightly batch reconciler** — recomputes each bucket from `analytics_raw_events` in full (never incrementally), overwrites the provisional document, sets `isProvisional: false` and `reconciledThrough`, and writes the completed `analytics_reconciliation_runs` row — targeting the proposed 06:00 UTC completion time.

Every document carries the same envelope fields as `api-contract.yaml`'s `DashboardEnvelope` schema (`generatedAt`, `isProvisional`, `reconciledThrough`), so the eventual-consistency window is surfaced in the read model itself, not bolted on at the API layer (`ddd-cqrs-standards.md`'s "surface, don't hide").

```js
// One doc per (granularity, bucketStart) — funnel stage counts. Backs
// GET /internal/v1/funnels/order-conversion.
db.createCollection("order_conversion_funnel")
// { _id, granularity, bucketStart, stages: [{stage, count, dropOffRate}], generatedAt, isProvisional, reconciledThrough }

// One doc per (granularity, bucketStart, sku?, category?). Backs GET /internal/v1/dashboards/revenue.
db.createCollection("revenue_dashboard")
// { _id, granularity, bucketStart, sku, category, revenue: {amount, currency}, orderCount, generatedAt, isProvisional, reconciledThrough }

// One doc per (granularity, bucketStart). Backs GET /internal/v1/dashboards/fulfillment-performance.
db.createCollection("fulfillment_performance_dashboard")
// { _id, granularity, bucketStart, timeToShip: {p50Hours,p95Hours,p99Hours}, timeToDeliver: {...}, generatedAt, isProvisional, reconciledThrough }

// One doc per (granularity, bucketStart, sku?). Backs GET /internal/v1/dashboards/inventory-movement.
db.createCollection("inventory_movement_dashboard")
// { _id, granularity, bucketStart, sku, reserved, reservationFailed, released, replenished, generatedAt, isProvisional, reconciledThrough }

// One doc per (granularity, bucketStart). Backs GET /internal/v1/dashboards/catalog-pricing.
db.createCollection("catalog_pricing_dashboard")
// { _id, granularity, bucketStart, productsCreated, priceChanges, categoryUpdates, generatedAt, isProvisional, reconciledThrough }

// One doc per (granularity, bucketStart). Backs GET /internal/v1/dashboards/promotions-effectiveness.
db.createCollection("promotions_effectiveness_dashboard")
// { _id, granularity, bucketStart, couponsRedeemed, quotesIssued, attributableOrderVolume: {amount,currency}, redemptionRate, generatedAt, isProvisional, reconciledThrough }

// One doc per (granularity, bucketStart). Backs GET /internal/v1/dashboards/user-growth.
db.createCollection("user_growth_dashboard")
// { _id, granularity, bucketStart, signups, sessionsCreated, profileChanges, generatedAt, isProvisional, reconciledThrough }

// One doc per (granularity, bucketStart). Backs GET /internal/v1/dashboards/reviews-ratings.
db.createCollection("reviews_ratings_dashboard")
// { _id, granularity, bucketStart, reviewCount, ratingDistribution: {"1":n,...,"5":n}, generatedAt, isProvisional, reconciledThrough }

// One doc per source event (a log, not a time-bucket aggregate) — no granularity param in
// api-contract.yaml for this endpoint. Backs GET /internal/v1/dashboards/admin-audit.
db.createCollection("admin_audit_log")
// { _id (= source event_id, dedup key), occurredAt, actionType, adminId, generatedAt, isProvisional, reconciledThrough }

// One doc per (granularity, bucketStart, channel?). Backs GET /internal/v1/dashboards/notification-delivery.
db.createCollection("notification_delivery_dashboard")
// { _id, granularity, bucketStart, channel, sent, priceAlertsTriggered, generatedAt, isProvisional, reconciledThrough }
```

## Indexing Rationale

| Index | Query it supports | Why needed |
|---|---|---|
| `analytics_raw_events` PK on `event_id` | Idempotent upsert on ingest/replay | Direct DB-enforced backing for the "Replay Correctness" decision — a redelivered or replayed event must overwrite, not duplicate |
| `idx_analytics_raw_events_type_occurred` | Every projector's "events of type X since the last watermark, in event-time order" scan | Both the near-real-time incremental projector and the nightly reconciler run this exact pattern for every one of D4a's ten dashboards/funnels — without it, each projection run degrades to a full scan of an indefinitely-retained table |
| `idx_analytics_raw_events_pii_pending` (partial, `contains_pii AND pii_redacted_at IS NULL`) | The redaction sweep's "find rows still needing redaction for this user" scan | Backs the PII Redaction decision above without a full-table scan; partial index keeps it cheap since only a small fraction of rows carry PII |
| `idx_analytics_dlq_events_pending` (partial, `reprocessed_at IS NULL`) | The scheduled reprocessor's drain scan | Same reasoning as `kart-admin-service`'s `idx_admin_actions_unpublished` — keeps the reprocessor a cheap index scan instead of a full-table scan as the DLQ table grows |
| `analytics_reconciliation_runs (run_date)` UNIQUE | "Has today's run already started/completed" check before kicking off the nightly job | Prevents a double-run for the same `run_date`, which would otherwise double-write reconciled Mongo documents for the same bucket |
| `idx_analytics_pii_redactions_user` | Compliance lookup — "has this user's data been redacted, and when" | Direct support for ADR-0016's audit/compliance obligation; without it a compliance query scans the whole redaction-audit table |
| Mongo: `{granularity:1, bucketStart:1}` on every time-bucketed dashboard/funnel collection | Every `GET .../{dashboard}?from=&to=&granularity=` query in `api-contract.yaml` | Direct 1:1 match to the API's `From`/`To`/`Granularity` query parameters — the P95 < 2s / P99 < 5s budget (architecture.md) requires this be an index range scan, not a collection scan, especially once historical buckets accumulate |
| Mongo: additional `sku`/`category`/`channel` compound prefix on `revenue_dashboard`, `inventory_movement_dashboard`, `notification_delivery_dashboard` | The optional `sku`/`category`/`channel` filter params those three endpoints expose | Same latency budget as above, applied to the filtered variant of each query — an unindexed filter on top of an already-bucketed collection would still force a collection scan for the filtered case |
| Mongo: `{occurredAt:1, actionType:1, adminId:1}` on `admin_audit_log` | `GET /internal/v1/dashboards/admin-audit?from=&to=&actionType=` — a log query, not a bucket aggregate | Matches this endpoint's actual parameter shape (no `granularity`); `admin_audit_log`'s `_id` is the source `event_id` itself, giving idempotent upsert for free without a separate unique index |

## Partitioning/Sharding

- **`analytics_raw_events` — range-partitioned by `ingested_at` (monthly), required, not optional.** This isn't a speculative choice: requirement-spec.md §6 D3 explicitly commits to "partitioned by ingestion date, tiered hot/cold storage" because the table retains every platform event **indefinitely** (the Replay Correctness design forbids ever deleting raw history). Monthly range partitions let older partitions be moved to cold storage (or a cheaper tablespace) without touching the active hot partitions, and let the retention-tiering job operate as simple partition detach/attach instead of row-level deletes across an ever-growing table.
- **No sharding for PostgreSQL at current scale.** The BRD's capacity plan doesn't name a per-partition write rate that exceeds a single well-provisioned PostgreSQL instance handling full platform fan-in with micro-batched writes (design-decisions.md "Concurrency/Scaling Model"); range partitioning already isolates hot-path writes (current month) from the indefinitely-growing cold history, which is the throughput problem sharding would otherwise solve here. Revisit only if the autoscaled consumer group's write throughput evidence later shows single-instance PostgreSQL saturating even the active partition.
- **MongoDB collections: single replica set, no sharding, at current scale.** Unlike the raw event store, these collections are bounded by **time-bucket cardinality × dimension cardinality** (e.g. day-buckets × SKU count), not raw event volume — several orders of magnitude smaller than `analytics_raw_events`. If a specific collection's dimensional cardinality (e.g. `revenue_dashboard` by SKU) later proves large enough to threaten the P95 < 2s budget, shard that collection on `{granularity, bucketStart}` (matching its own primary query pattern above) rather than sharding the whole read model preemptively.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner
- [x] Approved (write-model schema)
