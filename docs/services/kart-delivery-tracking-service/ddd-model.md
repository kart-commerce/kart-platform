---
doc_type: ddd-model
service: kart-delivery-tracking-service
status: approved
generated_by: ddd-agent
source: docs/services/kart-delivery-tracking-service/architecture.md, docs/services/kart-delivery-tracking-service/design-decisions.md, docs/services/kart-delivery-tracking-service/requirement-spec.md, docs/services/kart-delivery-tracking-service/edge-cases.md
---

# DDD Model: kart-delivery-tracking-service

**Input-freshness note:** `requirement-spec.md`, `edge-cases.md`, `architecture.md`, and `design-decisions.md` are all `status: approved` with every blocking item resolved. This model is derived directly from architecture.md's and design-decisions.md's already-decided content (the read-side-projection boundary, the three-collection storage split, the ingestion pipeline) rather than re-deciding anything upstream.

**Architecture exception carried forward:** per architecture.md's Boundary Rationale, this service has no PostgreSQL write side — the entire tracking record is a materialized read-side projection fed by an async event (`ShipmentDispatched`) and third-party webhooks/polling. This is a deliberate, already-flagged exception to `ddd-cqrs-standards.md`'s general "write model is always PostgreSQL" default. The aggregates below are modeled as event/webhook-fed projections with their own internal consistency rules, not as a fictitious command-side domain model with no write API of its own.

Three aggregate roots, each its own MongoDB collection and its own transaction boundary — the split is justified below by the exact test in `ddd-agent.md`/`ddd-cqrs-standards.md`: if two "things" can't be saved in one transaction, they're two aggregates, not one. design-decisions.md's own concurrency-control decision already states this explicitly for two of the three ("the status/ordinal write and the append-only status-history write are independent operations with no cross-document invariant between them"), which is the basis for not modeling history as a child entity list inside `TrackingRecord`.

## Aggregate: TrackingRecord

**Entity:** `TrackingRecord` — identified by `TrackingId` (value object; sourced from `ShipmentDispatched`'s `trackingId` field, requirement-spec §2). One document per `trackingId`, holding only the *current* exposed state.

**Value objects:**
- `TrackingId` — opaque identifier, first seen in `ShipmentDispatched`'s payload; this service never generates one itself.
- `CarrierId` — identifies which per-carrier adapter/mapping/polling client owns this record (requirement-spec §5's `POST /internal/webhooks/carriers/{carrierId}`).
- `CanonicalDeliveryStatus` — the single internal status enum every exposed/published status must be a member of (edge-cases.md, "Inconsistent Status Vocabulary Across Carriers"). BRD names no fixed vocabulary, so the concrete member list is an engineering default (see Modeling Decision 3): `Dispatched → InTransit → OutForDelivery → Delivered`, plus non-progressing terminal alternates `Returned` / `FailedDelivery`. `Delivered` is fixed as the literal terminal value Order's consumer already depends on ([ADR-0005](../../adr/0005-unify-order-terminal-event.md); `kart-order-service/requirement-spec.md`: "consumes only its terminal 'delivered' status value") — this is a cross-service wire-contract constraint, not a free naming choice.
- `LifecycleOrdinal` — the monotonic position of a `CanonicalDeliveryStatus` value within the ordering above; the mechanism the non-regression invariant is checked against (edge-cases.md, "Out-of-Order Carrier Status Updates").
- `Eta` — `{ value: timestamp, source: CARRIER_SUPPLIED | SLA_FALLBACK }`; recomputed on every accepted status update (requirement-spec §2, edge-cases.md "ETA Going Stale Mid-Transit"), never on an independent schedule.

**Fields:** `trackingId`, `orderId` (reference only — see Referenced Elsewhere below), `carrierId`, `currentStatus: CanonicalDeliveryStatus`, `currentOrdinal: LifecycleOrdinal`, `eta: Eta`, `lastUpdatedAt`.

**Invariants:**
- A `TrackingRecord` may only come into existence by consuming `ShipmentDispatched` (requirement-spec §2/§4 — the aggregate-creation trigger). Before that consumption happens for a given `trackingId`, no document exists; "pending" is **never a stored state on this aggregate** — it is purely an absence-of-record condition the API layer translates into `202`/`PENDING` (requirement-spec §5/§6, edge-cases.md "Tracking Query Before the First Status Event Has Arrived"). See Modeling Decision 2.
- `currentStatus`/`currentOrdinal` must never regress: an incoming update whose ordinal is not strictly greater than `currentOrdinal` is rejected at the aggregate boundary via an atomic conditional update (design-decisions.md's `findOneAndUpdate` ordinal-guard), never applied and never overwrites the existing value.
- `currentStatus` must always be a member of `CanonicalDeliveryStatus` — a raw carrier code that fails to map is never written here (held at its previous value instead; edge-cases.md "Unmapped Carrier Status"). There is no synthetic `Unknown` enum member — an unmapped code simply does not advance this aggregate.
- `eta` is recomputed as part of every accepted (non-duplicate, non-regressing) status update; it is never refreshed on a fixed independent schedule (edge-cases.md).
- A `currentStatus` change that is accepted (passes dedup, passes the ordinal guard, and is a mapped canonical value) publishes `DeliveryStatusUpdated` at-least-once, idempotently; a dedup-suppressed duplicate or a rejected regression must never trigger a publish (requirement-spec §4 Domain Invariant, edge-cases.md "Duplicate Carrier Webhook Delivery").

**Domain events:**
- Consumed: `ShipmentDispatched` (external — owned by `kart-shipping-service`; aggregate-creation trigger only, requirement-spec §2).
- Consumed (internal, this service's own — **new**, not in the BRD's Event Catalog): `CarrierStatusIngested` — the normalized, HMAC-verified representation of requirement-spec §5's webhook contract (`carrierId, trackingId, carrierStatusCode, eventTimestamp, rawPayload`) after design-decisions.md's durable-RabbitMQ-enqueue step, immediately before dedup/ordinal-check/mapping runs. Naming this explicitly separates "durably accepted" (the webhook handler's concern) from "domain-applied" (this event's concern), mirroring the split requirement-spec §6 item 4 already draws. Proposed addition to the ubiquitous language / this service's own internal event catalog — flagged for review, not blocking (same precedent as `kart-offer-service`'s `CouponRedemptionVoided`).
- Published: `DeliveryStatusUpdated` (`trackingId, status`) — existing, BRD §10. `status` is always `CanonicalDeliveryStatus`, never a raw carrier code, never `PENDING`/`Unknown`. Consumer set per [ADR-0005](../../adr/0005-unify-order-terminal-event.md): Notification, Analytics, and Order (Order filters client-side to the `Delivered` terminal value only).
- Published (internal/ops-only — **new**, not in the BRD): `UnmappedCarrierStatusFlagged` — raised when an incoming `carrierStatusCode` fails to resolve against the canonical enum, carrying `{carrierId, trackingId, carrierStatusCode, eventTimestamp}`. Drives the operational triage queue edge-cases.md already specifies (routine ticket within 1 business day; escalated to paged/same-day if the shipment's ETA window passes while still unmapped). Proposed addition, flagged for review, not blocking — this is purely an internal ops signal, never exposed to Notification/Analytics/Order.

## Aggregate: TrackingStatusHistory

**Entity:** `TrackingStatusHistory` — identified by `TrackingId` (one history stream per tracking id; a separate MongoDB collection/document from `TrackingRecord` — design-decisions.md's concurrency-control decision explicitly names these as independent writes with no cross-document invariant, which is this split's basis, not an oversight).

**Child entity:** `StatusHistoryEntry` — identified by `(trackingId, sequence)`; append-only, never mutated or deleted once written.

**Value objects:**
- `CarrierStatusCode` — the raw, carrier-native status string, opaque to the canonical mapping.
- `CanonicalDeliveryStatus` (nullable on an entry) — null exactly when the raw code was unmapped at ingestion time (edge-cases.md, "Unmapped Carrier Status").
- `IngestionSource` — `SYSTEM | WEBHOOK | POLL`. `SYSTEM` marks the single synthetic entry a `TrackingRecord`'s creation (via `ShipmentDispatched`) writes as this stream's anchor (see Modeling Decision 4); `WEBHOOK`/`POLL` mark entries from the two carrier-status ingestion paths (requirement-spec §2, edge-cases.md "Carrier Webhook Failure or Silence").

**Invariants:**
- Append-only: an entry, once persisted, is never mutated or removed — this is the audit trail edge-cases.md's "Duplicate Carrier Webhook Delivery" and "Unmapped Carrier Status" decisions both depend on.
- Records **distinct received states only**: a webhook suppressed as a duplicate by `WebhookDedupEntry` never produces a new entry here (edge-cases.md: "status history becomes a record of distinct received states, not a literal receipt log of every webhook call").
- An unmapped `carrierStatusCode` is still appended here (with `canonicalStatus = null`) even though it never touches `TrackingRecord.currentStatus` — this is the audit/triage record edge-cases.md's "Unmapped Carrier Status" decision requires; without it, an unmapped update would leave no trace at all.
- A regression-rejected update (fails the ordinal guard on `TrackingRecord`) is still appended here for audit, exactly as an unmapped one is — rejection from the current-state aggregate is not the same as "never happened."

**Domain events:** None published directly. This aggregate is a passive, append-only record populated as a side effect of the same ingestion pipeline that updates `TrackingRecord` — see Cross-Aggregate Interaction below for why these are two separate writes, not one transaction.

## Aggregate: WebhookDedupEntry

**Entity:** `WebhookDedupEntry` — identified by `DedupKey` (value object). One entry per distinct received update, colocated in MongoDB with the other two collections (design-decisions.md's idempotency-mechanism decision) but its own document/collection with no cross-document invariant enforced against `TrackingRecord` or `TrackingStatusHistory`.

**Value objects:**
- `DedupKey` — a carrier-supplied idempotency key when that carrier's adapter contract provides one; otherwise a computed content hash of `trackingId + canonicalStatus-or-raw-code-if-unmapped + carrierEventTimestamp` (edge-cases.md, "Duplicate Carrier Webhook Delivery").

**Fields:** `dedupKey`, `trackingId` (reference only), `createdAt`, `expiresAt`.

**Invariants:**
- A given `DedupKey` may be recorded at most once within its live window; a second webhook producing the same key is recognized as a duplicate and must suppress both the `TrackingRecord` update attempt and the `TrackingStatusHistory` append for that update (edge-cases.md).
- Lifetime: `expiresAt` defaults to 7 days from `createdAt` (MongoDB TTL index, design-decisions.md), recomputed to an earlier value once the corresponding `trackingId`'s `TrackingRecord.currentStatus` reaches a terminal `CanonicalDeliveryStatus` (`Delivered`, `Returned`, or `FailedDelivery`) plus a 30-day grace period — a cross-aggregate *reference* (by `trackingId`), never a transactional coupling.

**Domain events:** None. Purely an internal idempotency ledger — never a business event source, never exposed outside this bounded context.

## Cross-Aggregate Interaction

The webhook-ingestion pipeline (design-decisions.md's durably-buffered RabbitMQ consumer, triggered by an internal `CarrierStatusIngested`) touches all three aggregates per inbound update, in sequence, but as three independent saves, never one ACID transaction:

1. Check `WebhookDedupEntry` for `DedupKey` — a hit aborts all further processing for this update (no `TrackingRecord` write, no `TrackingStatusHistory` append). A miss records a new `WebhookDedupEntry` and continues.
2. Attempt the atomic conditional update against `TrackingRecord` (ordinal-guarded `findOneAndUpdate`) — succeeds only if the incoming status is canonical-mapped and its ordinal is strictly greater than the current one; otherwise this aggregate is left untouched.
3. Append a `StatusHistoryEntry` to `TrackingStatusHistory` — unconditionally for every non-duplicate update, regardless of whether step 2 succeeded (captures unmapped and regression-rejected updates for audit, per both aggregates' invariants above).

This is a deliberate application of the transaction-boundary test (`ddd-agent.md`/`ddd-cqrs-standards.md`), not an oversight: design-decisions.md already states there is "no cross-document invariant" between the status write and the history write, and the dedup check is explicitly a pre-check gate, not a joint commit with either of the other two.

`ShipmentDispatched` consumption creates only `TrackingRecord` plus the one `SYSTEM`-sourced anchor entry in `TrackingStatusHistory` (Modeling Decision 4) — it never touches `WebhookDedupEntry`, since a `ShipmentDispatched` consumption is not a carrier webhook and has no duplicate-webhook risk to guard against (it has its own, separately-stated idempotent-consumption invariant, requirement-spec §4).

## Referenced Elsewhere (owned by another bounded context — accessed via ACL, not redefined here)

| Term | Owning Context | How this service uses it |
|---|---|---|
| Order | `kart-order-service` | `TrackingRecord.orderId` is a reference field only, populated from `ShipmentDispatched`'s payload; this service never models Order's own state machine or lifecycle. |
| Shipment / `ShipmentDispatched` | `kart-shipping-service` | Consumed only as the `TrackingRecord` creation trigger; this service never models Shipping's own aggregate (e.g. carrier selection, dispatch scheduling). |

## Modeling Decisions & Assumptions (resolved here, not escalated — engineering defaults, revisable)

1. **Three aggregates, not one (transaction-boundary test applied).** `TrackingRecord`, `TrackingStatusHistory`, and `WebhookDedupEntry` are modeled as three separate aggregate roots, each its own MongoDB document/collection, because none of them are ever required to commit in the same transaction — confirmed directly by design-decisions.md's concurrency-control decision ("independent operations with no cross-document invariant") for the first two, and by `WebhookDedupEntry`'s role as a pure pre-check gate for the third. Modeling `StatusHistoryEntry`/`WebhookDedupEntry` as child collections embedded inside a single `TrackingRecord` aggregate would force an atomic multi-concern write the architecture never asks for and design-decisions.md explicitly rejected the cost of (an in-process/single-document approach was considered and rejected for the dedup store specifically because it "doesn't survive restarts or work once ingestion is horizontally scaled").
2. **`PENDING` is never a persisted state.** requirement-spec §5/§6 and edge-cases.md fix the `GET /tracking/{id}` `202`/`PENDING` response for the pre-materialization race window, but nothing upstream says whether a placeholder `TrackingRecord` document should be written early to represent it. Decision: no placeholder document — absence of a `TrackingRecord` document *is* the pending state, checked directly against MongoDB by the read path. This avoids inventing a second "empty" aggregate state to keep in sync with true absence, and keeps the non-regression/canonical-vocabulary invariants meaningful only once a record genuinely exists.
3. **`CanonicalDeliveryStatus` member list and ordering.** The BRD names no status vocabulary at all (requirement-spec §4). The member list (`Dispatched → InTransit → OutForDelivery → Delivered`, with `Returned`/`FailedDelivery` as non-progressing terminal alternates) is an engineering default reflecting typical carrier lifecycle stages, not a BRD-derived fact — revisable once real per-carrier mapping tables are built. The one non-negotiable constraint is the literal terminal value Order already depends on ([ADR-0005](../../adr/0005-unify-order-terminal-event.md)): whatever wire-level string this service publishes for its terminal successful state must be exactly what Order's consumer filters on. Flagged for the Event Design Agent to confirm the exact wire casing/string against `kart-order-service`'s contract before finalizing the event schema.
4. **`ShipmentDispatched` writes one `SYSTEM`-sourced history anchor.** Not stated anywhere upstream whether aggregate creation itself produces a `TrackingStatusHistory` entry. Decision: yes — a single `SYSTEM`-sourced entry at creation time gives the history stream a `t0` anchor, consistent with edge-cases.md's general aversion to a tracking record having "no signal" of its own state at any point. Revisable; does not affect any published event or invariant if changed later.
5. **Per-carrier status-mapping and SLA-ETA tables are reference data, not aggregates.** The per-carrier `CarrierStatusCode → CanonicalDeliveryStatus` mapping table (edge-cases.md, "Inconsistent Status Vocabulary Across Carriers") and the per-carrier/per-service-level SLA fallback table for `Eta` (requirement-spec §2, edge-cases.md "ETA Going Stale Mid-Transit") are both maintained, out-of-band, static reference/configuration data this service's aggregates read from — not modeled as aggregates themselves, since they have no per-instance lifecycle, identity, or invariant of their own beyond "must exist and be kept current," which is an operational concern (the same operational triage queue `UnmappedCarrierStatusFlagged` feeds) rather than a domain one.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner
- [x] Approved to proceed to API/Database/Event Design Agents
