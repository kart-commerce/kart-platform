---
doc_type: database-design
service: kart-delivery-tracking-service
status: approved
generated_by: database-design-agent
source: docs/services/kart-delivery-tracking-service/ddd-model.md, docs/services/kart-delivery-tracking-service/architecture.md, docs/services/kart-delivery-tracking-service/design-decisions.md, docs/services/kart-delivery-tracking-service/requirement-spec.md, docs/services/kart-delivery-tracking-service/edge-cases.md, docs/services/kart-delivery-tracking-service/api-contract.yaml, docs/adr/0005-unify-order-terminal-event.md
---

# Database Design: kart-delivery-tracking-service

**Input-freshness note:** `requirement-spec.md`, `edge-cases.md`, `ddd-model.md`, `architecture.md`, and `design-decisions.md` are all `status: approved` with every blocking item resolved (Q1's carrier-webhook contract, the `202`/`PENDING` pre-materialization response, ETA computation, and the `ShipmentDispatched` creation-trigger relationship are all closed). This design is derived directly from `ddd-model.md`'s three already-decided aggregates rather than re-deciding anything upstream.

## Architecture Exception: No PostgreSQL Write Side

Per `architecture.md`'s Boundary Rationale and `ddd-model.md`'s header, this service has **no PostgreSQL write side** — a deliberate, already-approved exception to `agent-reusables/docs/standards/ddd-cqrs-standards.md`'s general "write model is always PostgreSQL" default. There is no client-initiated write command against a domain aggregate the usual CQRS way: the entire tracking domain is fed by two external triggers only — consuming `ShipmentDispatched` (aggregate-creation) and carrier webhooks/polling (state transitions) — and `GET /v1/tracking/{trackingId}` (`api-contract.yaml`) is this service's only client-facing surface, a pure read.

This differs from `kart-analytics-service`'s (structurally similar-looking) exception in one material way worth flagging explicitly rather than silently copying that precedent: Analytics retains an indefinitely-retained raw PostgreSQL event store as its true source of truth, with MongoDB as a *rebuildable* projection of it (`ddd-cqrs-standards.md`'s "read model always rebuildable from the write model + event log"). This service keeps **no separate durable event log** of every inbound webhook/event beyond what is captured in the MongoDB collections themselves — `ddd-model.md` names `CarrierStatusIngested` as an internal, in-flight RabbitMQ message (durably enqueued, then consumed and discarded once processed), not a retained append-only source table. That means the three MongoDB collections below are not merely a "read model" in the strict CQRS sense — collectively, **they are this service's sole durable source of truth**, even though the storage technology is MongoDB rather than PostgreSQL. Treated accordingly for sign-off purposes: this design requires the same human-approval weight `database-design-agent.md` assigns a write-model schema ("costly to change post-migration"), not the lighter "read-model/projection changes can be marked approved directly" path — because there is no upstream write model here to fall back on if this schema needs to change later.

## Storage (MongoDB) — One Collection per `ddd-model.md` Aggregate

Three aggregate roots, three collections, matching `ddd-model.md`'s transaction-boundary-test split exactly (no cross-document invariant is ever enforced between them; each is touched by the ingestion pipeline as an independent save, never one ACID transaction — see `ddd-model.md`'s Cross-Aggregate Interaction section).

```js
// ── tracking_records ──────────────────────────────────────────────────────
// Backs the TrackingRecord aggregate (ddd-model.md). One document per
// trackingId, holding only the *current* exposed state. _id = trackingId
// directly (not a separate ObjectId + secondary unique index) because every
// access path — GET /v1/tracking/{trackingId} (api-contract.yaml), and the
// atomic ordinal-guarded update below (design-decisions.md "Concurrency
// Control") — is a point lookup/update keyed by trackingId and nothing else.
db.createCollection("tracking_records")
// {
//   _id: <trackingId>,                 // opaque id, first seen in ShipmentDispatched (ubiquitous-language.md TrackingId)
//   orderId: <string>,                 // reference only — ShipmentDispatched payload; never models Order's own state (ddd-model.md "Referenced Elsewhere")
//   carrierId: <string>,               // selects the per-carrier adapter/mapping/SLA table (requirement-spec §5)
//   currentStatus: <CanonicalDeliveryStatus>, // api-contract.yaml enum: Dispatched|InTransit|OutForDelivery|Delivered|Returned|FailedDelivery — never a raw carrier code, never PENDING/Unknown
//   currentOrdinal: <int>,             // LifecycleOrdinal — see "Ordinal Assignment" below; the non-regression guard's comparison key
//   eta: { value: <ISODate>, source: "CARRIER_SUPPLIED" | "SLA_FALLBACK" }, // recomputed on every accepted update, never on a fixed schedule (edge-cases.md "ETA Going Stale Mid-Transit")
//   lastUpdatedAt: <ISODate>,          // when currentStatus/eta was last (re)computed by an accepted update — also the polling-fallback staleness clock (edge-cases.md "Carrier Webhook Failure or Silence"); this is the BRD §24.3 updated_at equivalent, kept under its existing domain name rather than duplicated
//   createdAt: <ISODate>,              // BRD §24.3 — set once, at ShipmentDispatched-consumption creation time; new field, previously absent since lastUpdatedAt covered only the "last touched" half
//   createdBy: <string>,               // BRD §24.3 — the ShipmentDispatched consumer's own system:* principal id (e.g. "system:shipment-dispatched-consumer"); never NULL, never a human/API caller
//   updatedBy: <string>                // BRD §24.3 — the ingesting carrier adapter's system:* principal id (e.g. "system:carrier-webhook:{carrierId}" / "system:carrier-poll:{carrierId}") on the most recent accepted update; never NULL
// }

// Point lookup/update key. No placeholder document is ever written for a
// not-yet-materialized trackingId (ddd-model.md Modeling Decision 2 —
// "PENDING" is never persisted, absence of a document *is* the pending
// state the API layer translates to 202/PENDING, api-contract.yaml).
// The atomic regression guard (design-decisions.md) runs as:
//   db.tracking_records.findOneAndUpdate(
//     { _id: trackingId, currentOrdinal: { $lt: incomingOrdinal } },
//     { $set: { currentStatus, currentOrdinal, eta, lastUpdatedAt } }
//   )
// relying on MongoDB's native single-document atomicity — no lock service,
// no retry loop (design-decisions.md "Concurrency Control for the
// Status-Regression Guard").

// Supports the scheduled polling-fallback job's own selection query
// (edge-cases.md "Carrier Webhook Failure or Silence"): "every non-terminal
// shipment whose lastUpdatedAt exceeds the 6-hour staleness threshold."
// Partial index — terminal shipments (Delivered/Returned/FailedDelivery)
// are permanently excluded from this scan by design, matching the edge
// case's "only for shipments that have not yet reached a terminal status."
db.tracking_records.createIndex(
  { lastUpdatedAt: 1 },
  { partialFilterExpression: { currentStatus: { $nin: ["Delivered", "Returned", "FailedDelivery"] } } }
)

// ── tracking_status_history_entries ─────────────────────────────────────────
// Backs the TrackingStatusHistory aggregate / StatusHistoryEntry child
// entity (ddd-model.md). One document per entry (not one array-valued
// document per trackingId) — a long-lived, high-traffic trackingId could
// otherwise approach MongoDB's 16MB document-size ceiling over the
// shipment's lifetime, and every entry here is independently
// append-only/immutable with its own identity ((trackingId, sequence),
// ddd-model.md), which maps naturally onto one row/document per entry
// rather than a growing embedded array.
db.createCollection("tracking_status_history_entries")
// {
//   _id: ObjectId(),
//   trackingId: <string>,              // partitions the stream; not embedded inside tracking_records (design-decisions.md: "independent operations with no cross-document invariant")
//   sequence: <int>,                   // monotonic per-trackingId ordinal — see "Sequence Assignment" below
//   carrierStatusCode: <string | null>, // raw, carrier-native value; null only for the one SYSTEM anchor entry (ddd-model.md Modeling Decision 4)
//   canonicalStatus: <CanonicalDeliveryStatus | null>, // null exactly when carrierStatusCode failed to map (edge-cases.md "Unmapped Carrier Status")
//   ingestionSource: "SYSTEM" | "WEBHOOK" | "POLL",     // SYSTEM = the ShipmentDispatched-creation anchor entry; WEBHOOK/POLL = the two carrier-status ingestion paths
//   rawPayload: <string | null>,       // opaque passthrough of the original carrier webhook body (requirement-spec §5) — this is the audit trail requirement-spec §5 promises "stored for audit/debugging"; null for SYSTEM/POLL entries that have no webhook body
//   eventTimestamp: <ISODate>,         // carrier-reported event time (requirement-spec §5's NormalizedCarrierIngestion field), or ShipmentDispatched's own event time for the SYSTEM anchor
//   receivedAt: <ISODate>,             // this service's own ingestion time — distinct from eventTimestamp because carrier webhook delivery has no ordering guarantee (edge-cases.md "Out-of-Order Carrier Status Updates"); kept for audit/debugging even though it is never the ordering key. This is the BRD §24.3 created_at equivalent, kept under its existing domain name rather than duplicated
//   createdBy: <string>                // BRD §24.3 — the writing pipeline's system:* principal id ("system:shipment-dispatched-consumer" for the SYSTEM anchor; "system:carrier-webhook:{carrierId}" / "system:carrier-poll:{carrierId}" otherwise); never NULL. No updated_at/updated_by column — entries are immutable/append-only (ddd-model.md invariant), so there is no "most recent update" to attribute
// }

// Unique compound index: enforces append-only identity ((trackingId,
// sequence) per ddd-model.md) at the database layer, and is the one query
// every consumer of this stream runs — "give me trackingId's history in
// order" (ops/triage review of a specific shipment, edge-cases.md
// "Unmapped Carrier Status" and "Duplicate Carrier Webhook Delivery").
db.tracking_status_history_entries.createIndex(
  { trackingId: 1, sequence: 1 },
  { unique: true }
)

// Supports the operational triage queue's own scan (edge-cases.md
// "Unmapped Carrier Status": "raise it to an operational/manual-review
// queue for adding the missing carrier mapping," 1-business-day SLA,
// escalated to paged/same-day once the shipment's ETA window passes).
// Partial index — only a small fraction of entries are ever unmapped.
db.tracking_status_history_entries.createIndex(
  { receivedAt: 1 },
  { partialFilterExpression: { canonicalStatus: null, ingestionSource: { $ne: "SYSTEM" } } }
)

// ── webhook_dedup_entries ───────────────────────────────────────────────────
// Backs the WebhookDedupEntry aggregate (ddd-model.md). Colocated in
// MongoDB rather than Redis, per design-decisions.md's "Idempotency
// Mechanism Design" decision (reuses the one datastore this service already
// has; a TTL index natively expresses both eviction rules edge-cases.md
// fixed, with no separate cleanup job).
db.createCollection("webhook_dedup_entries")
// {
//   _id: <dedupKey>,       // carrier-supplied idempotency key where that carrier's adapter contract provides one, else a computed content hash of trackingId + canonicalStatus-or-raw-code-if-unmapped + carrierEventTimestamp (edge-cases.md "Duplicate Carrier Webhook Delivery")
//   trackingId: <string>,  // reference only, not a transactional coupling (ddd-model.md) — needed to re-target this entry's expiresAt once that trackingId reaches a terminal status
//   createdAt: <ISODate>,   // BRD §24.3 — already present under this name; set once at first receipt
//   createdBy: <string>,    // BRD §24.3 — the ingesting pipeline's system:* principal id at insert; never NULL
//   expiresAt: <ISODate>,   // defaults to createdAt + 7 days; recomputed to an earlier value once the trackingId's tracking_records.currentStatus reaches Delivered/Returned/FailedDelivery, at (terminal timestamp + 30-day grace) — edge-cases.md
//   updatedAt: <ISODate>,   // BRD §24.3 — new field; set whenever expiresAt is recomputed by the terminal-status sweep (the one mutation this document ever undergoes)
//   updatedBy: <string>     // BRD §24.3 — new field; "system:delivery-tracking-terminal-status-sweep" for the expiresAt recompute; never NULL
// }

// TTL index — MongoDB's background reaper deletes a document once its
// expiresAt has passed, giving both eviction rules (edge-cases.md's 7-day
// baseline and the terminal+30-day early-eviction recompute) for free with
// no separate cleanup job (design-decisions.md).
db.webhook_dedup_entries.createIndex(
  { expiresAt: 1 },
  { expireAfterSeconds: 0 }
)

// Supports the early-eviction recompute itself: "find every still-live
// dedup entry for a trackingId that just reached a terminal status, and
// push its expiresAt out to terminal+30-days" (edge-cases.md). Without this,
// that recompute would need a full collection scan per terminal transition.
db.webhook_dedup_entries.createIndex({ trackingId: 1 })
```

### Ordinal Assignment (`LifecycleOrdinal`) — Filling a Gap `ddd-model.md` Leaves Implicit

`ddd-model.md` fixes the `CanonicalDeliveryStatus` member list and its *progressing* order (`Dispatched → InTransit → OutForDelivery → Delivered`) but does not say where the two "non-progressing terminal alternates," `Returned` and `FailedDelivery`, sit on the ordinal number line the regression guard compares against — a genuine gap this stage must close to make the guard implementable, not a re-litigation of `ddd-model.md`'s enum choice itself.

| `CanonicalDeliveryStatus` | `currentOrdinal` |
|---|---|
| `Dispatched` | 1 |
| `InTransit` | 2 |
| `OutForDelivery` | 3 |
| `Delivered` | 4 |
| `Returned` | 4 |
| `FailedDelivery` | 4 |

**Decision:** all three terminal values share the same ordinal (4), the maximum. Once a `tracking_records` document's `currentOrdinal` reaches 4, the atomic guard (`currentOrdinal: { $lt: incomingOrdinal }`) rejects every subsequent update — including an attempt by *another* terminal value to overwrite the one already recorded (e.g. a stray `Returned` webhook arriving after `Delivered` was already recorded). This is a single-service engineering default, consistent with the requirement-spec §4 Domain Invariant ("status should not regress") read at its most protective: none of `ddd-model.md`, `requirement-spec.md`, or `edge-cases.md` describe a real-world lifecycle transition *out of* a terminal state (e.g. a delivered package later being returned is, in the BRD's stated vocabulary, out of scope — Delivery Tracking never models post-delivery returns processing, which is a different bounded context's concern if it exists at all). Flagged for confirmation alongside `ddd-model.md`'s own Modeling Decision 3 flag (member list/ordering is revisable), but not a blocking gap: an incorrect terminal-value collision is inherently rare (a shipment reaching two different terminal states) and, worst case, only means the *first*-recorded terminal value wins, which is never a silent data-loss outcome — the losing update is still captured in `tracking_status_history_entries` per that collection's "regression-rejected update is still appended for audit" invariant (`ddd-model.md`).

### Sequence Assignment (`StatusHistoryEntry.sequence`) — Filling a Gap `ddd-model.md` Leaves Implicit

`ddd-model.md` identifies a `StatusHistoryEntry` by `(trackingId, sequence)` but does not fix the mechanism that assigns `sequence`. Decision: a dedicated MongoDB counters collection (`tracking_status_history_counters`, one document per `trackingId`, `{ _id: trackingId, nextSequence: <int> }`), incremented atomically via `findOneAndUpdate({ _id: trackingId }, { $inc: { nextSequence: 1 } }, { upsert: true, returnDocument: "after" })` immediately before each insert into `tracking_status_history_entries`. **BRD §24.3 note:** this collection is a bare atomic counter, not a business-data record — the platform-wide equivalent of a PostgreSQL `SEQUENCE` object, which itself carries no `created_at`/`created_by`/`updated_at`/`updated_by` columns anywhere else on this platform either. No audit columns are added here for the same reason; the actual business mutation (the history entry the counter is generating a sequence number for) is already audited via `tracking_status_history_entries.createdBy` above. This is the same "MongoDB single-document atomicity, no lock service" pattern design-decisions.md already chose for the ordinal guard, applied to sequence generation — and it deliberately does **not** couple to `tracking_records`' own document (no shared counter field there), preserving the "independent operations with no cross-document invariant" property design-decisions.md states between the status write and the history append. A duplicate-webhook or regression-rejected update still consumes a `sequence` value under this scheme (it still gets appended to history per that collection's invariants) — this is expected and harmless, since `sequence` only needs to be monotonic and unique per `trackingId`, not gapless.

### Reference Data — Explicitly Out of Scope for This Schema

Per `ddd-model.md` Modeling Decision 5, the per-carrier `carrierStatusCode → CanonicalDeliveryStatus` mapping table and the per-carrier/per-service-level SLA fallback table for `Eta` are maintained, out-of-band, static reference/configuration data — "not modeled as aggregates themselves, since they have no per-instance lifecycle, identity, or invariant of their own." Consistent with that: this design does not add a `carrier_status_mappings` or `carrier_sla_table` collection. Whether that reference data ultimately lives in application config, a small admin-managed config collection, or a separate config service is an operational/deployment concern the requirement-spec/edge-cases/ddd-model chain never asks this stage to fix — flagged here only so its absence from the schema above reads as a deliberate scope boundary, not an oversight.

## Row-Level Security Policy (BRD §24.1.4)

Per BRD §24.1.4, the service whose database physically holds a row decides and enforces that row's row-level security. This service has **no PostgreSQL write side at all** (Architecture Exception, above) — every collection lives in MongoDB — so native `ENABLE ROW LEVEL SECURITY`/`CREATE POLICY` never applies here; the relevant BRD §24.1.4 mechanism is instead its MongoDB alternative, "a single, shared, unbypassable query-builder at that service's data-access boundary."

**No collection here carries a `user_id`-shaped ownership column.** `tracking_records` and `tracking_status_history_entries` key on the opaque `trackingId`; `webhook_dedup_entries` keys on `dedupKey`; `tracking_status_history_counters` keys on `trackingId` purely as a counter target. None of the four is scoped to an individual end user — this mirrors the exact carve-out BRD §24.1.4 itself names for Payment's `payment_intents` ("keys only on the opaque `order_id`... a `user_id`-shaped row-level policy would not even apply"), and is consistent with `GET /v1/tracking/{trackingId}` being deliberately public/possession-based (api-contract.yaml, requirement-spec.md's §24.1.2 cross-reference above) rather than ownership-scoped. There is therefore no per-row *read* filter for this service's data-access-boundary query-builder to enforce.

**What this service's data-access boundary does enforce (write-path integrity, not row ownership):** every write to any of the four collections is routed through this service's own ingestion pipeline (design-decisions.md's durably-buffered consumer/webhook handler) and nowhere else — no other code path in this service, and no external caller, writes to these collections directly. The two gates that stand in for a "session-scoped principal" here, since there is no interactive end-user principal on this service's write path at all:

- The internal `ShipmentDispatched` consumer only accepts messages from the trusted internal RabbitMQ bus (platform-wide transport trust boundary, BRD §8–§11) — not a per-row check, a channel-level one.
- The `POST /internal/webhooks/carriers/{carrierId}` handler only accepts a write once the carrier's `X-Carrier-Signature` HMAC verifies (requirement-spec §5) — rejected requests (`401`) never reach the ingestion pipeline's write path at all, so an unverified caller cannot produce even a foreign/incorrect `trackingId` row.

Both gates are checked before the query-builder layer is reached at all, the same "additive, not a replacement" layering BRD §24.1.3/§24.1.4 describe generally — they are this service's version of the ambient session-scoped principal, just channel/signature-based rather than `user_id`-based, because no `user_id`-shaped principal ever originates a write here.

## Sensitive / PII Column Classification (BRD §24.1.5)

Column-level security answers a narrower question than row-level security: of the columns in a row a caller already has `CanRead` on (BRD §24.1.2), which does that caller's own coarse role actually see — full value, masked, or nothing.

| Column | Full Value Visible To | Masked/Omitted For | Masking Rule |
|---|---|---|---|
| `tracking_status_history_entries.rawPayload` | Internal ops/triage tooling only (edge-cases.md's unmapped-status queue) | Every external-facing role — Customer, Support Agent, Admin, Partner API — via any public endpoint | Opaque passthrough of a carrier's native webhook body (requirement-spec §5); may incidentally embed carrier-supplied recipient name/address/phone as an artifact of the raw capture, even though this service never parses those sub-fields itself. `GET /v1/tracking/{trackingId}` never returns this field at all (api-contract.yaml's response schema is `{trackingId, status, eta, lastUpdatedAt}` only) — not a masking rule so much as the field never appearing in any public response DTO in the first place, the same "never-serialized rather than merely role-masked" treatment `kart-identity-service/database-design.md` applies to its own never-returned credential columns |

**Why this list and no more:** `trackingId`, `orderId`, `carrierId`, `currentStatus`/`carrierStatusCode`, `eta`, and the §24.3 audit columns carry no PII — they are opaque identifiers or shipment-lifecycle metadata, not personal data about the recipient. `GET /v1/tracking/{trackingId}`'s public response body (`trackingId, status, eta, lastUpdatedAt`) is deliberately minimal and was never in scope for a role-gated masking rule, since none of its fields differ in sensitivity by caller role — this mirrors BRD §24.1.5's own reasoning for Payment Service's non-PCI columns ("no unmasked PCI data exists to protect in the first place" for the fields that don't carry it).

**Enforcement point:** primarily this service's own response-serialization DTO (api-contract.yaml) never including `rawPayload` in any public-facing schema at all, per §24.1.5's stated primary control; secondarily, for any direct database connection bypassing this service's own API (an ops/triage tooling query against MongoDB directly), access to `tracking_status_history_entries.rawPayload` is restricted to the narrow internal ops/triage tooling role, mirroring how §24.1.5 layers native column-level `GRANT` restrictions underneath the primary API-level control for PostgreSQL-backed services — the MongoDB-equivalent control here is restricting which database role/connection string the ops/triage tooling uses, since MongoDB has no native per-column `GRANT`.

## Indexing Rationale

| Index | Query it supports | Why needed |
|---|---|---|
| `tracking_records` `_id` (= `trackingId`) | `GET /v1/tracking/{trackingId}` point read; the atomic ordinal-guarded `findOneAndUpdate` on ingestion | Both are single-document point lookups by `trackingId` and nothing else — this is the P95<150ms/P99<400ms read-path index (requirement-spec §3) and design-decisions.md's "no cache" decision leans on this being a fast primary-key lookup, not a secondary index scan |
| `tracking_records` partial `{lastUpdatedAt: 1}` (non-terminal only) | The scheduled polling-fallback job's "every non-terminal shipment stale past 6 hours" scan (edge-cases.md "Carrier Webhook Failure or Silence") | Without it, that job scans every tracking record ever created, including permanently-terminal ones that will never need polling again; the partial filter keeps the scanned set bounded to genuinely in-flight shipments |
| `tracking_status_history_entries` unique `{trackingId: 1, sequence: 1}` | Ops/triage review of one shipment's full history, in order (edge-cases.md "Unmapped Carrier Status", "Duplicate Carrier Webhook Delivery") | Direct 1:1 match to the append-only identity `ddd-model.md` assigns this entity; the uniqueness constraint is a database-enforced backstop against a sequence-assignment bug producing a silent duplicate |
| `tracking_status_history_entries` partial `{receivedAt: 1}` (unmapped, non-`SYSTEM` only) | The unmapped-status triage queue's "oldest unresolved unmapped entries first" scan, feeding the 1-business-day/paged-on-ETA-breach SLA (edge-cases.md "Unmapped Carrier Status") | Without it, finding outstanding unmapped statuses degrades to a full collection scan of an ever-growing audit stream; the partial filter keeps it cheap since unmapped entries are expected to be a small fraction |
| `webhook_dedup_entries` `_id` (= `dedupKey`) | The ingestion pipeline's dedup check, step 1 of `ddd-model.md`'s Cross-Aggregate Interaction sequence, run once per inbound update before any other write | Direct primary-key lookup — this is the one index design-decisions.md's "not on the `GET` P95<150ms read path" trade-off note explicitly accepts paying MongoDB latency for, since it happens once per webhook, not once per read |
| `webhook_dedup_entries` `{expiresAt: 1}` TTL (`expireAfterSeconds: 0`) | Background expiry — no explicit query, MongoDB's own TTL reaper | Implements both eviction rules edge-cases.md fixed (7-day baseline; terminal+30-day early-eviction recompute) with no separate cleanup job, per design-decisions.md |
| `webhook_dedup_entries` `{trackingId: 1}` | The early-eviction recompute's own lookup: "every still-live dedup entry for a `trackingId` that just reached a terminal status" | Without it, every terminal-status transition would force a full collection scan of the dedup store to find entries to re-target |
| `tracking_status_history_counters` `_id` (= `trackingId`) | Atomic `$inc` sequence generation, one call per history append | Same single-document-atomicity pattern as the ordinal guard — a point lookup/upsert, not a scan |

## Partitioning/Sharding

No partitioning or sharding for any of the four collections at current scale, and none is called for by any capacity assumption named upstream:

- **`tracking_records`** is bounded by *distinct in-flight-or-recently-terminal shipment count*, not raw event volume — a single replica set comfortably holds this at any Kart-plausible order volume; no capacity plan in `requirement-spec.md`/`architecture.md` suggests otherwise. If this ever needs sharding, `trackingId` is the natural shard key (matches the only query pattern this collection serves).
- **`tracking_status_history_entries`** grows unboundedly over time (no TTL — this is a durable audit/triage record, and no retention/archival policy is stated anywhere in `requirement-spec.md`, `edge-cases.md`, or `ddd-model.md`). **Flagged, not blocking:** unlike `kart-analytics-service`'s raw event store — whose indefinite retention and partition-by-ingestion-date scheme is an explicit BRD-derived requirement (`requirement-spec.md §6 D3` there) — nothing upstream for this service states a retention horizon or asks for range partitioning here. Given each `trackingId` typically accumulates only a handful of entries across one shipment's lifecycle (a few status transitions, not a high-frequency event stream), this collection's growth rate is expected to track shipment volume linearly and modestly, not explosively — a single collection is sufficient today. Revisit with a real retention/archival decision (and, if needed, range-partition by `receivedAt` the way Analytics does) once actual volume data or a stated compliance retention window exists; inventing one now would be setting a number this stage has no basis for, the same reasoning `design-decisions.md`'s caching decision already applied to declining to invent a staleness TTL.
- **`webhook_dedup_entries`** is self-bounding by the TTL index (7-day baseline, terminal+30-day grace ceiling) — it cannot grow unboundedly regardless of ingestion volume, so no partitioning question arises.
- **`tracking_status_history_counters`** has exactly one document per `trackingId` that has ever received at least one status event — bounded the same way `tracking_records` is.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner
- [x] Approved (this schema is this service's sole source of truth — see "Architecture Exception" above — treated with write-model-equivalent approval weight, not the lighter read-model/projection path)
