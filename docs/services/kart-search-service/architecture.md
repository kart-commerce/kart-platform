---
doc_type: architecture
service: kart-search-service
status: pending-approval
generated_by: architecture-agent
source: docs/services/kart-search-service/requirement-spec.md, docs/services/kart-search-service/edge-cases.md, docs/services/kart-search-service/design-decisions.md
---

# Architecture: kart-search-service

## Boundary Rationale

`kart-search-service` is the bounded context that answers "what matches this query, ranked how" — full-text search, filters, faceted aggregation, and relevance ranking over the product catalog (BRD §2.1 item 5; requirement-spec §1). It is a **pure read/query-side context**: it owns no write model, publishes no domain events, and its entire responsibility is projecting catalog state into a queryable OpenSearch index (requirement-spec §1, §2).

Two structural facts fix this boundary precisely, not just "it's a service because the BRD says so":

- **Search is a sibling, not a dependent, of Product's MongoDB read model.** Both are independently fed off the same catalog event stream (`ProductCreated`/`ProductPriceChanged`, published by `kart-product-service` — see its [architecture.md](../kart-product-service/architecture.md), which names Search as one of its four fan-out consumer groups). Domain Invariant (requirement-spec §4) is explicit that a stale or down MongoDB read model must never block Search indexing — this is a hard boundary rule, not an implementation detail, and it is why this document treats "consume Product's events directly" (not "read Product's Mongo collection") as the only inbound integration mechanism on the query-serving path.
- **Search is not a participant in the Order Saga (BRD §12) and sits in the 99.9% secondary-availability tier**, not the 99.99% order-path tier (requirement-spec §3). It is a query-only fan-out consumer of the catalog event stream, the same posture `kart-offer-service` and `kart-product-service` already establish for read-heavy, non-saga services.

No dependency on `kart-category-service` is added here. **[ADR-0011](../../adr/0011-category-read-model-scope.md)** already records that neither Product's nor Search's own approved docs name themselves as a consumer of `CategoryUpdated` today, and reserves the decision to add one for whichever side needs it later — inventing that edge here would silently resolve a question ADR-0011 deliberately left open. If Search's facet aggregation on category later needs live category-name freshness, that is a new finding for a future revision of this document, not something to pre-decide now.

## Dependencies

| Direction | Peer | Mechanism | Type | Notes |
|---|---|---|---|---|
| Inbound (client) | Client/Web/Mobile via API Gateway | `GET /search` | **Sync** (REST) | Query-only read path (requirement-spec §5). NFR: P95 < 150ms, P99 < 400ms (requirement-spec §3). Query-time budget management is covered under "Facet Query Resilience" below. |
| Inbound (consumed) | Product | `ProductCreated` | **Async** | 3x retry, `catalog.dlq` (BRD §10, requirement-spec §3). Upsert into the index. |
| Inbound (consumed) | Product | `ProductPriceChanged` | **Async** | 3x retry, `catalog.dlq` (BRD §10; publisher corrected from "Pricing" to Product by **[ADR-0008](../../adr/0008-event-catalog-completeness-round-2.md)**). Applied via the version/timestamp-guard write path (edge-cases.md's "Out-of-Order Event Consumption") to reject stale-ordered redeliveries. |
| Inbound (consumed, proposed) | Product | `ProductDiscontinued` | **Async** | Not yet a formal BRD §10 catalog row — proposed by `kart-product-service` (requirement-spec §2/§5/§6 item 4; its own `edge-cases.md`'s "Discontinued/orphaned variant"). Search's commitment is to consume it as a soft-remove signal (`available: false`, excluded from default result sets, document retained) via the same version/timestamp-guard path as price/create upserts — no second removal code path (edge-cases.md's "Discontinued Product Still Returned by Search"). Retry/DLQ tier not yet formally registered; **provisionally treated at the same tier as its sibling catalog events (3x, `catalog.dlq`)** until the Event Design Agent formalizes the event platform-wide — a placeholder, not a final answer. |
| Outbound (batch, rebuild-only) | Product | Bulk catalog-snapshot export (paginated bulk read or scheduled full-catalog dump from Product's PostgreSQL write side) | **Sync** (batch pull, off the request-serving path) | Resolves the infrastructure requirement design-decisions.md's "Index Rebuild Strategy" decision explicitly carried forward to this stage: RabbitMQ has no native event replay (BRD §14), so the blue-green reindex (edge-cases.md's "Index Rebuild During High Write Volume") needs a point-in-time catalog snapshot to seed the new index before tailing live events. This pulls from Product's write side, **not** its MongoDB read model, keeping it consistent with the Domain Invariant that Search never depends on Product's Mongo collection being present or current. Invoked only during a rebuild (infrequent, operator-triggered or scheduled), never on the `/search` query path — see Distributed-Monolith Risk below for why this does not count as runtime coupling. |

No events are published by Search (requirement-spec §5; BRD §5.4 lists no outbound events for this service) — it is a pure consumer/query context.

## Resolved Integration-Contract Questions

### Consistency-Lag SLA and Indexing Pipeline Defaults

Requirement-spec §3/§6 item 1 already concretizes the BRD's unquantified "seconds, not milliseconds" bound (BRD §2.2) as **P95 index-catch-up lag < 5s, P99 < 15s**, measured from Outbox insert to the document being searchable — this is cited, not re-derived, here. What this stage adds is the starting infrastructure configuration needed to hit that bound, carried forward from design-decisions.md's "Communication Style & Freshness-Tuning Mechanism" decision as an Architecture Agent tuning question:

- OpenSearch index `refresh_interval`: **1s** (near-real-time refresh, not OpenSearch's 30s+ bulk-ingest default), so a document becomes searchable within one refresh cycle of being indexed.
- RabbitMQ consumer batch size: **up to 500 events per flush, with a 250ms max batch-linger timeout** — whichever bound is hit first — so a single slow-arriving event doesn't hold up an otherwise-full batch, and a low-traffic period doesn't wait indefinitely for a batch to fill.
- These are starting baselines for the Database Design/Event Design stages and load-testing to validate or retune once real indexing throughput is measured against the 100M-SKU catalog (BRD §4.1) — consistent with design-decisions.md's own framing that retuning these constants is a normal refinement, not a reopening of the async-consumer communication-style choice itself.

### Facet Query Resilience — Timeout Budget and Graceful Degradation

Requirement-spec §6 item 3 and edge-cases.md's "Query Timeout Under High-Cardinality Filters" already fix the concrete bound — cited, not re-derived: **max 5 concurrent facet filters per query, max 100 returned value-buckets per facet, and a 300ms query-time budget** (inside the overall P99 < 400ms latency NFR). On exceeding the budget, the query degrades by dropping the least-selective (highest-cardinality) facet filter(s) first and returns partial results with a `truncated: true` flag, rather than failing the request outright. This is Search's standing resilience pattern for the entire `/search` query path (design-decisions.md's "Resilience Pattern for Faceted Query Timeout and Degradation"), not a one-off fix for a single edge case — every facet-bearing query goes through this budget/degradation path, including ones that never actually hit the 300ms ceiling.

### Index Rebuild Backfill Source (resolves design-decisions.md's carried-forward infrastructure requirement)

Design-decisions.md's "Index Rebuild Strategy" decision explicitly deferred one open item to this stage: blue-green reindex needs "an event-replay or catalog-snapshot source, since RabbitMQ has no native replay." Resolved above in the Dependencies table as a batch, rebuild-only bulk export from Product's PostgreSQL write side. This is a genuinely new dependency edge this stage adds to the graph — it did not exist in requirement-spec.md or edge-cases.md — but it is scoped narrowly: it runs only during an operator-triggered or scheduled full reindex (mapping change, ranking-signal change, or corruption recovery), never as part of serving a live `/search` request, and it targets Product's write side specifically so it does not reintroduce a dependency on Product's Mongo read model that the Domain Invariant forbids.

## Distributed-Monolith Risk

**None identified on the request-serving path.** `GET /search` never calls out synchronously to any other service — it queries OpenSearch only, with facet-query degradation (above) bounding worst-case latency instead of a synchronous fan-out. Search's only inbound synchronous dependency is the client-facing Gateway call itself.

**The new bulk-export edge (Product, batch/rebuild-only) is deliberately not counted as runtime coupling.** It is invoked at a low, operator-controlled frequency (index rebuilds, not per-request), and a slow or unavailable Product bulk-export endpoint during a rebuild delays that rebuild — it does not degrade or fail any live `/search` query, because the old index/alias continues serving reads until the new one is caught up and the alias swap happens (edge-cases.md's "Index Rebuild During High Write Volume"). This is the same reasoning `kart-product-service`'s own architecture.md uses to exclude its Admin/Partner write-path coupling from being flagged as a distributed-monolith risk: a narrow, acknowledged coupling with no chained dependency and no live-request-path exposure, not the "chatty synchronous coupling that should be async" anti-pattern this stage exists to catch.

**Async event consumption carries the platform's standard eventual-consistency risk, already bounded, not open.** A slow or backed-up RabbitMQ consumer only widens Search's own already-quantified staleness window (P95 < 5s/P99 < 15s) — it does not cascade into Product, Wishlist, Offer, or Analytics, since each of those has its own independent consumer of the same fan-out events (per `kart-product-service/architecture.md`'s per-consumer-group queue design).

**`ProductDiscontinued`'s retry/DLQ tier is a flag for the Event Design Agent stage**, the same way `kart-review-service/architecture.md` flags `ReviewUpdated`'s unregistered tier: until the Event Design Agent formalizes `ProductDiscontinued` platform-wide, Search provisionally treats it as the same tier as its sibling catalog events (3x, `catalog.dlq`) — a placeholder, not a final answer, and not itself a distributed-monolith concern since it's async either way.

**Overall assessment:** Search is architecturally clean relative to the rest of the platform — a pure fan-out consumer with one narrow, low-frequency, non-request-path batch dependency for rebuilds, and zero synchronous outbound dependency of any kind on the live query-serving path.

## Sign-off

- [ ] Reviewed by: _pending human review_
- [ ] Approved to proceed to DDD Agent
