---
doc_type: tickets
service: kart-recommendation-service
status: approved
generated_by: ticket-agent
source: [architecture.md, ddd-model.md, api-contract.yaml, database-design.md, event-contract.md, design-decisions.md, requirement-spec.md, edge-cases.md]
---

# Tickets: kart-recommendation-service

Local draft. Not yet created as real GitHub Issues — that requires the target repo to exist (Scaffold Agent) and is a separate, explicit step.

**Input-freshness note:** `requirement-spec.md`, `edge-cases.md`, `design-decisions.md`, `architecture.md`, `ddd-model.md`, `database-design.md`, `event-contract.md`, and `api-contract.yaml` are all `status: approved` — every gap this pass found (the clickstream publisher/event definitions, the recommendation algorithm, the staleness SLA, and the stale `OrderDelivered` retry-tier citation inherited from BRD §10 before `kart-order-service`'s own later elevation) is resolved directly in this service's own docs, with no stale "Open Question"/"TBD" remaining and no contradiction across the eight documents or against `kart-order-service`'s/`kart-product-service`'s/`kart-inventory-service`'s own approved docs. This ticket list decomposes directly from all eight docs' already-decided content.

## Epic: kart-recommendation-service v1

Personalized "customers also bought" recommendations (BRD §2.1 item 18) — a pure read-side, consumer-only service (requirement-spec.md §1) with **no PostgreSQL write side** (`database-design.md`'s Architecture Note — a standard rebuildable MongoDB projection fed by two RabbitMQ events and three Kafka events, not the same "sole source of truth" exception `kart-delivery-tracking-service` documents for itself).

| ID | Task | Vertical Slice (Application/Features/) | Depends On | Design Source |
|---|---|---|---|---|
| REC-1 | Consume `OrderDelivered` — update `ProductAffinity` co-occurrence pairs and `purchased_skus_by_user` | `ConsumeOrderDelivered` | — | `event-contract.md` `OrderDelivered` (`recommendation.order-delivered.dlq`, 5x exponential/paged-on-call); `ddd-model.md` `ProductAffinity`'s redelivery-safe `recentOrderIds`/`confirmedCount` upsert; `database-design.md`'s per-pair upsert write path + `purchased_skus_by_user` lookup index |
| REC-2 | Consume `ProductCreated` — neutral-seed `TrendingPool` | `ConsumeProductCreated` | — | `event-contract.md` `ProductCreated` (`recommendation.product-created.dlq`, per [ADR-0013](../../adr/0013-recommendation-productcreated-consumption.md)); `ddd-model.md` `TrendingPool`'s immediate out-of-band neutral-seed invariant; edge-cases.md "Newly catalogued products" |
| REC-3 | Consume `ProductViewed`/`ProductClicked`/`SearchPerformed` — update `UserBehaviorProfile` | `ConsumeClickstreamEvents` | — | `event-contract.md`'s three clickstream event rows (`kart.recommendation.clickstream-events.dlq`); `ddd-model.md`'s time-decayed `viewScore`/`clickScore` invariant and best-effort idempotency posture; `architecture.md`'s Clickstream Publisher Resolution |
| REC-4 | `TrendingPool` periodic recompute (15-minute cycle) | `RecomputeTrendingPool` | — | `architecture.md`'s proposed 15-minute bound; `ddd-model.md`'s `TrendingPool` recompute invariant; `database-design.md`'s wholesale-replace write path — independent of REC-1/REC-2/REC-3 (reads their accumulated data, writes its own document) |
| REC-5 | `RecommendationSet` debounced per-user recompute (event-triggered, ≤ once per 5 min per user) | `RecomputeRecommendationSet` | REC-1, REC-3, REC-4 | `ddd-model.md`'s Recommendation Model formula (purchase affinity 0.60 / behavior 0.25 / trending 0.15) and debounced-recompute staleness-SLA invariant (closes requirement-spec Open Question 3's clickstream half); `database-design.md`'s wholesale-replace write path |
| REC-6 | `GET /v1/recommendations/{userId}` — serve `RecommendationSet`, `TrendingPool` fallback for a not-yet-computed user | `GetRecommendations` | REC-5 | `api-contract.yaml`'s only endpoint; `ddd-model.md`'s "always return a response" invariant; requirement-spec §4 Domain Invariant |
| REC-7 | Live availability filter — batched `GET /inventory?skus=...`/`GET /products?ids=...`, Redis cache, timeout + circuit breaker, fail-open | `FilterUnavailableRecommendations` | REC-6 | edge-cases.md "Stale recommendations after out-of-stock/discontinued"; `design-decisions.md`'s resilience + caching decisions; `architecture.md`'s N+1-mitigation follow-on and Distributed-Monolith Risk mitigation; `api-contract.yaml`'s `availabilityFilterApplied` field |
| REC-8 | `ProductAffinity` `recentOrderIds` compaction (scheduled daily) | `CompactProductAffinityLedger` | REC-1 | `database-design.md`'s Compaction Mechanism (24-hour retention window, folds into `confirmedCount`); `ddd-model.md`'s Modeling Decision 3 |

## Flagged Gaps — Not Decomposed Into Tickets (would invent scope, not decompose it)

- **A richer, ML-trained recommendation model.** `ddd-model.md`'s Recommendation Model section resolves v1 as item-based collaborative filtering (co-occurrence) blended with a behavioral signal and a trending baseline — an explicitly revisable engineering-default baseline, not a trained model. No ticket — building a trained-model serving/training pipeline is a materially different scope no BRD section asks for.
- **A richer, per-warehouse real-time stock-level ranking input.** `architecture.md`/`ddd-model.md` scope the availability filter to a binary in-stock/discontinued check via existing Inventory/Product reads; no ticket for a deeper stock-level signal, the same carve-out `kart-search-service/tickets.md` already makes for its own in-stock ranking signal.
- **A dedicated recommendation-impression event.** `architecture.md`'s Dependencies table notes the Analytics-based drift-monitoring mechanism rides on the existing clickstream event stream (via `ProductClicked.sourceContext`), needing no new Recommendation-published event. No ticket — Recommendation continues to publish nothing (requirement-spec §2/§5).

## Notes for Sprint Planner Agent

- REC-1, REC-2, REC-3 have no dependency on each other or on anything else and can start in parallel in sprint 1 — three independent consumer entry points into three disjoint MongoDB collections, the same "shared nothing, different trigger" shape `kart-search-service/tickets.md`'s SRCH-1/SRCH-5 already establish for this platform's read-side services.
- REC-4 has no dependency and can also start in parallel with REC-1/REC-2/REC-3 — it recomputes from whatever `OrderDelivered`/clickstream volume has accumulated so far, and independently upserts neutral seeds are handled by REC-2, not this job.
- REC-5 depends on REC-1, REC-3, and REC-4 (it reads `ProductAffinity`/`purchased_skus_by_user`, `UserBehaviorProfile`, and `TrendingPool` — all three must exist, even if initially empty, before a meaningful recompute can run) but not on REC-2 directly (REC-2's effect reaches REC-5 only via REC-4's `TrendingPool`, or via REC-4/immediate-seed data being read).
- REC-6 depends only on REC-5 (there must be a `RecommendationSet` write path, and a `TrendingPool` fallback path, before the read endpoint has anything to serve) — it does not depend on REC-1/REC-2/REC-3 individually, the same "queries whatever is currently there" posture `kart-search-service/tickets.md`'s SRCH-7 takes.
- REC-7 extends REC-6's same read path — sequence it directly after, the same pattern SRCH-7/SRCH-8 use for query-then-facets.
- REC-8 depends only on REC-1 (it compacts data REC-1 writes) and is otherwise independent of every other ticket — safe to build last, as pure storage hygiene with no read-path-visible effect.
- No circular dependencies in this graph. Longest chain is REC-1/REC-3/REC-4 → REC-5 → REC-6 → REC-7 (4 deep).

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner
- [x] Approved
