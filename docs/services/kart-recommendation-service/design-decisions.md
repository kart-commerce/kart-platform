---
doc_type: design-decisions
service: kart-recommendation-service
status: approved
generated_by: design-decision-agent
source: docs/services/kart-recommendation-service/requirement-spec.md, docs/services/kart-recommendation-service/edge-cases.md
---

# Design Decisions: kart-recommendation-service

Cross-cutting technology/pattern choices this service's requirement-spec and edge-cases force. Service boundaries, aggregates/domain model, and schema/table design are out of scope here — see the Architecture, DDD, and Database Design Agents for those.

## Decision: Event Transport per Consumed Input

- **Requirement driving this:** requirement-spec §2/§5 confirms three consumed inputs with different volume/replay needs — `OrderDelivered` (Order, per ADR-0005; retry tier since elevated by `kart-order-service/event-contract.md` to 5x exponential/paged-on-call, `order.order-delivered.dlq` — see `event-contract.md`'s own Correction note), `ProductCreated` (Product, 3x retry/`catalog.dlq`, confirmed as an actual dependency by ADR-0013), and clickstream events (no Event Catalog entry, but BRD §15 groups Recommendation with Analytics as needing "replay and high-throughput partitioned consumption"). edge-cases.md's "Clickstream volume overwhelms ingestion" edge case already chose a Kafka topic partitioned by `userId` with consumer-group autoscaling for the clickstream input specifically — that choice is referenced here, not re-derived.
- **Options considered (3):** one Kafka cluster for all three consumed inputs uniformly · RabbitMQ (per the platform's TTL-ladder-retry + per-consumer-DLQ default) for `OrderDelivered`/`ProductCreated`, Kafka for clickstream only · RabbitMQ for all three, treating BRD §15's Kafka mention as clickstream-specific framing only
- **Decision:**
  - Chosen: split transport — `OrderDelivered` and `ProductCreated` stay on RabbitMQ; clickstream moves to Kafka (per BRD §15 and edge-cases.md's already-chosen per-`userId` partitioning + consumer-group autoscaling)
  - Why: the reusable event standards scope Kafka adoption "per consumer group, where justified" by replay/high-throughput need — that need is specific to clickstream's volume (order-of-magnitude higher than transactional events, requirement-spec §3), not to `OrderDelivered`/`ProductCreated`; the "3x retry / `order.dlq`" and "3x retry / `catalog.dlq`" tiers stated in BRD §10 already describe the RabbitMQ TTL-ladder + per-consumer-DLQ pattern verbatim, and those two events are also consumed by Review, Notification, Search, and Analytics, none of which have a stated Kafka need
  - Trade-off accepted: Recommendation runs two consumption stacks (RabbitMQ client + Kafka client) instead of one — more operational surface than a single-transport design; accepted because collapsing `OrderDelivered`/`ProductCreated` onto Kafka would force every other consumer of those same events to migrate too, which is outside this service's scope to decide

## Decision: Idempotency Mechanism Design for `OrderDelivered` Signal Updates

- **Requirement driving this:** edge-cases.md's "Duplicate or redelivered `OrderDelivered` events double-count purchase signal" edge case already chose "dedupe on `orderId` (idempotency key)" as the fix, per requirement-spec §3's idempotent-consumer NFR, but named two possible mechanisms ("a processed-`orderId` record... or equivalent upsert semantics") without picking between them. This decision resolves that mechanism, it does not re-open the fix itself.
- **Options considered (3):** persisted processed-`orderId` ledger checked before applying each update (classic dedup table) · upsert-based signal update keyed by `orderId` (the write itself is naturally idempotent, no separate ledger) · broker-level transactional exactly-once consumer semantics (no application-level dedup)
- **Decision:**
  - Chosen: upsert-based signal update keyed by `orderId`
  - Why: Recommendation's read model is already MongoDB-based (requirement-spec §4's precomputed-read-model invariant); an upsert keyed by `orderId` reuses that same store instead of standing up a second dedup ledger, and needs no broker-level transactional guarantee the platform doesn't otherwise provide (the reusable event standards state at-least-once delivery + TTL-ladder retry as the default, not exactly-once)
  - Trade-off accepted: constrains the eventual recommendation signal representation to something upsert-safe (a set/last-write-wins shape per `orderId`, not a raw incrementing counter) — carried forward as a constraint the DDD Agent's `ProductAffinity` aggregate satisfies directly (`ddd-model.md`'s `recentOrderIds`/`confirmedCount` split), not a gap in this decision itself

## Decision: Resilience Pattern for the Synchronous Live Availability Check

- **Requirement driving this:** edge-cases.md's "Stale recommendations after a product goes out of stock or is discontinued" edge case chose a synchronous live inventory/catalog check at request time, explicitly flagging the risk it poses to the P95 < 150ms / P99 < 400ms NFR (requirement-spec §3) without deciding a resilience pattern for that call.
- **Options considered (3):** timeout budget + circuit breaker on the availability-check call, fail-open (serve the recommendation unfiltered) on timeout/trip · same, but fail-closed (drop any item whose availability couldn't be confirmed in time) on failure · no resilience pattern — treat the availability check as a hard dependency
- **Decision:**
  - Chosen: timeout budget + circuit breaker, fail-open on failure
  - Why: requirement-spec §4's own invariant is that `GET /recommendations/{userId}` must always return a response (never empty/error) — fail-closed risks emptying the result entirely when the check is degraded, and "no pattern" turns availability-check downtime into full read-path downtime, contradicting Recommendation's own 99.9% availability target for a dependency with no stated SLA of its own
  - Trade-off accepted: fail-open means a rare stale/unsellable item can still surface when the availability check itself is down or timed out — accepted because the edge case's own goal (never showing a known-unsellable item in the normal case) is still met, and this is strictly better than the pre-decision baseline of no check at all

## Decision: Caching Strategy for the Availability Filter

- **Requirement driving this:** the synchronous availability check introduced above sits on the hot read path for every `GET /recommendations/{userId}` call, which must stay within P95 < 150ms / P99 < 400ms (requirement-spec §3) — re-querying availability per recommended item per request risks that budget at any real request volume, per edge-cases.md's own flagged trade-off.
- **Options considered (3):** short-TTL Redis cache of per-SKU availability status, checked before falling back to the live call · no cache — call the source system synchronously every time (the resilience decision's baseline) · local in-process cache per service instance
- **Decision:**
  - Chosen: short-TTL Redis cache of per-SKU availability status
  - Why: keeps the live-call rate down to cache misses/expiries only rather than one external call per recommended item per request, protecting the latency NFR the "no cache" baseline already put at risk; Redis is the platform's existing read-side cache tier, consistent with the CQRS read-model conventions (read model rebuildable, no direct writes outside a projection) rather than introducing a new infrastructure piece
  - Trade-off accepted: a short TTL still leaves a small staleness window where a just-delisted product could be served before the cache entry expires — accepted because the BRD gives no staleness bound for Recommendation at all (requirement-spec §3), and this window is far smaller than the "accept staleness, periodic batch recompute" option edge-cases.md already rejected for the underlying signal itself

## Sign-off

- [x] Chosen technologies/patterns reviewed by a human: Automated architecture pipeline — autonomous completion authorized by project owner
- [x] Approved to proceed to Architecture Agent
