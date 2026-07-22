---
doc_type: design-decisions
service: kart-delivery-tracking-service
status: approved
generated_by: design-decision-agent
source: docs/services/kart-delivery-tracking-service/requirement-spec.md, docs/services/kart-delivery-tracking-service/edge-cases.md
---

# Design Decisions: kart-delivery-tracking-service

Cross-cutting technology/pattern choices this service's requirement-spec and edge-cases force. Service boundaries, aggregates/domain model, and schema/table design are out of scope here — see the Architecture, DDD, and Database Design Agents for those.

## Decision: Idempotency Mechanism Design for the Webhook Dedup Store

- **Requirement driving this:** edge-cases.md's "Duplicate Carrier Webhook Delivery" already chose content-hash dedup (`trackingId` + canonical status + carrier event timestamp) with a 7-day default TTL plus early-eviction eligibility once a `trackingId` reaches a terminal status and a 30-day grace period passes — but left the storage technology for that dedup table itself open. requirement-spec §2/§5.4 fixes MongoDB as this service's only persistence store (no PostgreSQL write side is named for Delivery Tracking).
- **Options considered (3):** Redis with native key TTL · a new MongoDB collection with a computed `expiresAt` field backed by a TTL index, colocated with the existing tracking store · an in-process/in-memory cache per service instance
- **Decision:**
  - Chosen: MongoDB collection with a computed `expiresAt` field backed by a TTL index, colocated with the existing tracking datastore.
  - Why: requirement-spec §2/§5.4 already fixes MongoDB as this service's only datastore; reusing it for the dedup hash avoids standing up Redis as a second infrastructure dependency purely for a lookup table, and a TTL index natively expresses both eviction rules edge-cases.md already fixed (7-day baseline, extended via a recomputed `expiresAt` once terminal+30-day applies) without a separate cleanup job.
  - Trade-off accepted: dedup lookups pay MongoDB's latency rather than an in-memory cache's — acceptable because this lookup happens once per inbound webhook, not on the `GET /tracking/{id}` P95<150ms read path (requirement-spec §3); an in-process cache was rejected outright since it doesn't survive restarts or work once ingestion is horizontally scaled.

## Decision: Concurrency Control for the Status-Regression Guard

- **Requirement driving this:** requirement-spec §4 Domain Invariant ("status should not regress to an earlier stage"); edge-cases.md's "Out-of-Order Carrier Status Updates" chose comparing an incoming status against a lifecycle ordinal and discarding regressions, but didn't fix how that compare-and-reject stays atomic when two webhook deliveries for the same `trackingId` are processed concurrently (e.g., two carrier retries landing on separate ingestion workers at once).
- **Options considered (3):** atomic single-document conditional update (MongoDB `findOneAndUpdate` with an ordinal-guard filter, e.g. `{trackingId, statusOrdinal: {$lt: incomingOrdinal}}`) · pessimistic per-`trackingId` distributed lock (e.g. Redis mutex) held across a read-compare-write sequence · optimistic app-level version field with read-then-write and retry-on-conflict loop
- **Decision:**
  - Chosen: atomic single-document conditional update, relying on MongoDB's native single-document atomicity guarantee.
  - Why: the current status and its ordinal already live in the same tracking document (requirement-spec §2's single-MongoDB-store decision) — one conditional `findOneAndUpdate` enforces "reject regression" in a single round trip, with no separate lock service and no retry loop needed.
  - Trade-off accepted: this mechanism only holds because status and ordinal are co-located in one document; it wouldn't generalize to a future invariant spanning multiple documents without a lock or transaction — acceptable today because the status/ordinal write and the append-only status-history write (edge-cases.md's audit trail) are independent operations with no cross-document invariant between them.

## Decision: Durable Ingestion Buffering Pattern Between Webhook Receipt and Internal Processing

- **Requirement driving this:** requirement-spec §6 Open Question #4(a)-(b): a carrier webhook must be "durably enqueue[d]" before returning `200` (returning `5xx` on enqueue failure so the carrier's own redelivery does the work), and only once durably accepted does it get "translated to an internal event" and "the same at-least-once/`tracking.dlq` machinery as any other internally-published event" — i.e., dedup/ordinal-check/mapping happen after durable acceptance, not inside the webhook request itself.
- **Options considered (3):** publish the HMAC-verified raw ingestion payload directly onto an internal RabbitMQ queue synchronously inside the webhook handler, ack `200` only once the broker confirms the publish, with a separate consumer performing dedup/ordinal-check/mapping/publish · write the payload to a MongoDB "inbox" collection inside the handler (transactional-outbox-style) and drain it with a polling worker · perform the entire pipeline (dedup, ordinal check, mapping, publish) synchronously in the webhook request with no intermediate buffer
- **Decision:**
  - Chosen: publish directly onto an internal RabbitMQ queue from the webhook handler (after HMAC verification, before dedup/ordinal/mapping), consumed asynchronously by the processing pipeline.
  - Why: reuses the platform's existing RabbitMQ durable-queue + DLQ + TTL-retry-ladder machinery (agent-reusables event standards) instead of building and operating a bespoke Mongo inbox + poller, and directly satisfies Open Question #4(b)'s requirement that a durably-accepted webhook get "the same...machinery as any other internally-published event" — no separate translation layer to build.
  - Trade-off accepted: adds one more queue hop before dedup/ordinal logic runs, so even a duplicate or regressing webhook briefly occupies queue capacity before being discarded — accepted as a small, bounded cost of decoupling "durably accepted" (the webhook response's concern) from "correctly processed" (the async consumer's concern), which is exactly the split Open Question #4 already draws.

## Decision: Resilience Pattern for the Carrier Polling Fallback Client

- **Requirement driving this:** edge-cases.md's "Carrier Webhook Failure or Silence" chose a scheduled per-carrier polling fallback (6-hour staleness threshold, terminal-status shipments excluded) as new outbound integration surface, explicitly flagged for the Architecture Agent's capacity planning — but didn't choose a resilience pattern for the outbound polling calls themselves.
- **Options considered (3):** per-carrier circuit breaker + bounded per-call timeout, with bulkhead isolation so one carrier's polling client never shares failure state or a worker pool with another's · fixed retry-with-backoff per poll attempt, no circuit breaker · no resilience wrapper — rely on the HTTP client's default timeout only
- **Decision:**
  - Chosen: per-carrier circuit breaker + bounded per-call timeout, isolated per carrier (bulkhead).
  - Why: a carrier already silent on webhooks (the trigger for polling at all) is also a plausible candidate for a degraded/unreliable polling API — a circuit breaker stops repeated slow-timeout calls to that one carrier from consuming scheduler capacity needed to poll every other carrier's stale shipments on time; per-carrier bulkhead isolation ensures one bad carrier's open circuit can't affect any other carrier's polling.
  - Trade-off accepted: adds a resilience-library dependency and per-carrier tunable thresholds (failure count to open, half-open probe interval) with no real per-carrier reliability data yet to tune them against — flagged, alongside the polling client build-out itself, for the Architecture Agent's capacity planning rather than fixed with invented numbers here.

## Decision: Caching Strategy for `GET /tracking/{id}` Reads

- **Requirement driving this:** requirement-spec §3 NFR sets P95<150ms/P99<400ms for this read; §4 Domain Invariant requires the exposed status to reflect "real-time tracking" (BRD §2.1) and never regress; requirement-spec §6 item 5 explicitly leaves the numeric staleness/consistency SLA open, carried forward to the Architecture Agent as non-blocking rather than fixed here.
- **Options considered (2):** no cache — every read served directly from MongoDB by `trackingId` · a short-TTL cache (e.g., Redis) in front of the read to protect the latency budget under load
- **Decision:**
  - Chosen: no cache layer; `GET /tracking/{id}` always reads MongoDB directly, keyed by `trackingId`.
  - Why: any cache TTL would silently fix a staleness bound requirement-spec §6 item 5 explicitly declines to set yet (carried to the Architecture Agent once real infrastructure numbers exist) — introducing one here would invent a number this stage has no basis for; a single-document point lookup by `trackingId` (the same key the concurrency-control decision above already relies on) is expected to meet the stated latency budget without one.
  - Trade-off accepted: if read volume later proves this endpoint needs a cache to hold the latency budget under load, that is deferred to the Architecture Agent as a capacity-driven addition — not ruled out permanently, just not invented here without a stated need.

## Sign-off

- [x] Chosen technologies/patterns reviewed by a human — Automated architecture pipeline, autonomous completion authorized by project owner
- [x] Approved to proceed to Architecture Agent
