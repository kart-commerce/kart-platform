---
doc_type: design-decisions
service: kart-search-service
status: approved
generated_by: design-decision-agent
source: docs/services/kart-search-service/requirement-spec.md, docs/services/kart-search-service/edge-cases.md
---

# Design Decisions: kart-search-service

Cross-cutting technology/design-pattern choices this service's requirement-spec.md and edge-cases.md force. Several decisions here generalize a fix already chosen in edge-cases.md into a named cross-cutting pattern — those are cited, not re-derived. Service boundaries, aggregate/domain model, and schema/table design are explicitly left to the Architecture, DDD, and Database Design Agents that follow this stage.

## Decision: Communication Style & Freshness-Tuning Mechanism for Catalog-to-Index Propagation

- **Requirement driving this:** requirement-spec §3 NFR Consistency row (**P95 index-catch-up lag < 5s, P99 < 15s**, measured Outbox-insert-to-searchable) and Domain Invariant §4 (index staleness must stay within "seconds, not milliseconds"); edge-cases.md's "Stale Search Results After Catalog Change" already chose the mechanism (async consumer, no synchronous write path) — cited here, not re-derived.
- **Options considered (3):** synchronous dual-write to the index on the catalog write path · async RabbitMQ consumer with a tuned OpenSearch refresh interval and consumer batch size (the option edge-cases.md chose) · async consumer via a Kafka topic partitioned by SKU for lower end-to-end latency
- **Decision:**
  - Chosen: async RabbitMQ consumer, with OpenSearch refresh interval and consumer batch size tuned to hit the P95 < 5s / P99 < 15s bound — generalizes edge-cases.md's "Stale Search Results After Catalog Change" decision into this service's standing communication-style choice for the whole indexing pipeline, not just that one edge case
  - Why: a synchronous write would violate Search's read-optimized, independently-fed service boundary (requirement-spec §2/Domain Invariant §4, "siblings, not dependent on each other"); RabbitMQ reuses the platform's existing topology/DLQ defaults (`docs/standards/event-standards.md`) instead of forcing a Kafka migration this service has no other stated need for (BRD §15 scopes Kafka adoption to Analytics/Recommendation first)
  - Trade-off accepted: the P95/P99 figures are this spec's own engineering default (requirement-spec Open Question 1, resolved), not a load-tested number — the Architecture Agent may need to retune refresh interval/batch size once real indexing throughput is measured; that's a refinement of this baseline, not a reopening of the communication-style choice itself

## Decision: Concurrency Control for Out-of-Order and Removal Index Writes

- **Requirement driving this:** requirement-spec §3 NFR Reliability row ("at-least-once delivery + idempotent consumers"); edge-cases.md's "Out-of-Order Event Consumption" (version/timestamp-guard + per-SKU routing keys) and "Discontinued Product Still Returned by Search" (soft-remove via the same write path) — the latter edge case explicitly reuses the former's mechanism rather than introducing a second removal code path, so both are covered by one concurrency-control decision here.
- **Options considered (3):** version/timestamp-guard on index writes (apply only if newer than what's indexed), combined with per-SKU routing keys on the existing topic-exchange convention (chosen) · per-SKU ordered routing/dedicated consumer so one instance handles all events for a SKU strictly in order · detect-and-rebuild the affected document on conflict
- **Decision:**
  - Chosen: version/timestamp-guard on all index writes (upserts from `ProductCreated`/`ProductPriceChanged` and soft-removes from `ProductDiscontinued` alike), combined with per-SKU routing keys per `docs/standards/kart-conventions.md`'s routing-key pattern
  - Why: cheapest fit against the existing RabbitMQ topology, no broker change required; using one guard mechanism for every index-mutating event (including removal) avoids a second, divergent code path for `ProductDiscontinued` specifically
  - Trade-off accepted: does not give the strict per-key ordering a Kafka partition would (BRD §14/§15 named limitation) — Search is a plausible future candidate for the Kafka migration path if ordering needs tighten; a stale-in-flight write can still transiently overwrite in the wrong order until the guard's version check rejects it

## Decision: Resilience Pattern for Faceted Query Timeout and Degradation

- **Requirement driving this:** requirement-spec §3 Latency NFR (P95 < 150ms, P99 < 400ms read path); edge-cases.md's "Query Timeout Under High-Cardinality Filters" already chose the concrete bound (max 5 concurrent facet filters, max 100 value-buckets per facet, 300ms query-time budget, drop least-selective facet(s) first, `truncated: true` flag on partial results) — cited here as the resilience pattern this service standardizes on, not re-derived.
- **Options considered (3):** hard cap on facet count/values per query plus a query-time timeout budget with graceful degradation (drop least-selective facets, return partial results) — the option chosen · precomputed/cached facet buckets for common filter combinations on a TTL · fail the whole request once the timeout budget is exceeded, no partial-result path
- **Decision:**
  - Chosen: timeout-budget-with-graceful-degradation, per edge-cases.md — degrade by dropping least-selective (highest-cardinality) facet filters first, return partial results with `truncated: true`, never fail the request outright for this reason
  - Why: keeps `/search` inside its latency NFR in the worst case and matches the platform's stated no-cascading-failure principle (BRD §3 Fault Tolerance row); failing outright would turn a performance edge case into a read-path outage for Search's stated 99.9% availability target
  - Trade-off accepted: the specific numbers (5 filters, 100 buckets, 300ms) are this spec's own defensible baseline (requirement-spec Open Question 3, resolved), not a BRD-stated figure, and may need retuning once the Architecture Agent load-tests against the real 100M-SKU index; a truncated response is a worse UX than full facets, accepted for a bounded latency guarantee

## Decision: Index Rebuild Strategy — Blue-Green Alias Swap

- **Requirement driving this:** Domain Invariant §4 (the index is a sibling of, not dependent on, the MongoDB read model, and must be independently rebuildable); edge-cases.md's "Index Rebuild During High Write Volume" already chose the mechanism (blue-green reindex via alias swap) — cited here, not re-derived.
- **Options considered (3):** blue-green reindex (build new index, replay catalog history, tail live events, atomic alias swap) — the option chosen · in-place reindex with write-blocking · dual-write to old and new index during a transition window
- **Decision:**
  - Chosen: blue-green reindex via alias swap — replay catalog history into the new index while tailing live events, then swap the alias once caught up
  - Why: keeps `/search` continuously available during a rebuild, matching the read-path Availability/Latency NFRs (requirement-spec §3); write-blocking would breach the read-path latency NFR outright
  - Trade-off accepted: needs an event-replay or catalog-snapshot source, since RabbitMQ has no native replay (BRD §14) — a periodic snapshot/backfill mechanism becomes a second dependency alongside the event stream; this is carried forward as an infrastructure requirement for the Architecture Agent, not solved here

## Decision: Caching Strategy for `/search` Responses and Facets

- **Requirement driving this:** Domain Invariant §4 ("faceted counts returned alongside search results must reflect the same filtered result set they're presented with — not a separately-cached or stale aggregate"); Latency NFR (P95 < 150ms, P99 < 400ms).
- **Options considered (3):** no application-level response/facet caching layer — every `/search` call queries OpenSearch live, relying only on OpenSearch's own internal query/shard-level caching (chosen) · short-TTL Redis cache of full `/search` responses keyed by normalized query+filter signature · precomputed/cached facet buckets for common filter combinations on a TTL (the option edge-cases.md's timeout decision already considered and did not choose for facets)
- **Decision:**
  - Chosen: no application-level response or facet caching layer; rely on OpenSearch's own internal caching only
  - Why: Domain Invariant §4 explicitly rules out a "separately-cached or stale aggregate" for facets — introducing a Redis (or equivalent) result cache would reopen exactly the staleness problem the invariant forecloses, adding a second, response-level staleness clock the requirement-spec never asks for on top of the already-bounded index-freshness one (Decision 1)
  - Trade-off accepted: every `/search` call pays a live query cost against the 100M-SKU index instead of a cache-hit shortcut, unlike the caching layers Product/Recommendation use for their own reads — accepted because the Latency NFR is engineered to hold via the facet-query resilience pattern (Decision 3) instead; if load-testing later shows the NFR can't be met without a cache, that is a genuine Architecture Agent revisit against a standing invariant, not something this stage should pre-decide around

## Decision: Observability & Instrumentation

**Decision:** Serilog (structured logging) + OpenTelemetry SDK (distributed tracing + metrics), per the platform's reusable observability-standards.md and this repo's kart-conventions.md Observability section. Logs export via OTLP → Grafana Loki; traces via OTLP → Grafana Tempo; metrics scraped by Prometheus from `/metrics`; Grafana provides dashboards and alerting. Wired once via the shared `Kart.Shared.Observability` package, not reimplemented per service.

**Options considered:**
- Ad-hoc per-service logging/APM tool choice — rejected: fragments dashboards/alerting across 18 services and breaks single-trace-id correlation across the platform.
- Platform-standard Serilog + OpenTelemetry + Grafana LGTM stack — adopted: one mental model and one Grafana pane across every service.

**Why:** Search is not one of the four 100%-trace-coverage saga services, so it runs the reusable standard's default sampling; a request-scoped `queryId` is the correlation field for `GET /search` spans/logs (Search has no per-user or per-entity ownership dimension to key on instead, §3), while the indexing-consumer pipeline carries `sku` to match what `ProductCreated`/`ProductPriceChanged`/`ProductDiscontinued` actually key on. One concrete signal worth a dashboard panel: index-catch-up lag (Outbox-insert-to-searchable), since Decision 1 above already commits this service to a P95 < 5s / P99 < 15s bound — the Prometheus histogram for that lag, with a trace exemplar per bucket, is what turns that NFR from a paper commitment into something an on-call engineer can actually watch and alert on.

## Not Decided Here

- **Serialization format for consumed events/payloads** — neither requirement-spec.md nor edge-cases.md states a service-specific forcing requirement beyond the platform's existing event-schema-versioning default (`docs/standards/event-standards.md`); no divergence reason exists, so nothing to add here.
- **Ranking/relevance scoring formula and sponsored-placement policy (capped vs. auctioned) — since resolved.** Was carried forward here as a non-blocking business/product tuning decision (requirement-spec Open Question 2). Now resolved at the DDD Agent stage (`ddd-model.md`'s `RankingProfile` value object): capped additive sponsored boost, not an auction — no bidding/marketplace mechanism exists anywhere in the BRD's 18-service scope for an auctioned model to run against, so "capped" is the only buildable default; see `ddd-model.md` for the full formula and rationale.
- **`ProductDiscontinued` formal payload/schema — since resolved.** Formalized by the DDD Agent stage at `kart-product-service/ddd-model.md`/`event-contract.md`: `sku, discontinuedAt`, 3x retry, `search.product-discontinued.dlq` on this service's own consumer side. This document's Decision 2 (how Search's own write path treats a discontinuation signal once received) is unaffected.
- **Index/document schema, sharding, and OpenSearch mapping design** — explicitly left to the Architecture and Database Design Agents per this stage's scope; only the rebuild strategy (Decision 4) and write-guard mechanism (Decision 2) are cross-cutting patterns fixed here. See `database-design.md`.

## Decision: Global Exception Handling & Consistent Response Model

**Decision:** A single global exception-handling middleware (ASP.NET Core `IExceptionHandler`/`UseExceptionHandler`) is the only place this service catches and translates unhandled exceptions into an HTTP response — no `Handler`/controller/domain code wraps business logic in try/catch purely to log-and-rethrow or log-and-return an error. Every error response (validation failure or unhandled exception) is shaped as an RFC 7807 `ProblemDetails` envelope extended with the platform's standard fields (`traceId`, `errorCode`); every success response follows the same consistent envelope convention as every other Kart service. Both the middleware and the `ProblemDetails` factory are wired once via the shared `Kart.Shared.ErrorHandling` package, not reimplemented locally.

**Options considered:**
- Per-handler/controller try/catch translating exceptions to a response inline — rejected: duplicates translation logic per endpoint, risks inconsistent status-code/response-shape choices across handlers, and produces double-logging (or missed logging) when a local catch and the global handler both react to the same exception.
- Platform-standard global exception handler + `Kart.Shared.ErrorHandling`-wired `ProblemDetails` envelope — adopted: one place to change the error shape platform-wide, and a response contract every client (web, admin, partner API) can parse identically regardless of which of the 18 services it's calling.

**Why:** matches the same "one platform-wide implementation, not built locally by each service" pattern already applied to `Kart.Shared.Observability` and `Kart.Shared.Auditing` above — reimplementing exception translation per service is the identical per-service-drift failure mode those decisions already reject. Domain/business errors continue to use the Result/Either pattern (`agent-reusables/docs/standards/api-standards.md`) rather than exceptions; the global handler exists for the genuinely exceptional case (an unhandled infrastructure fault), and logs it exactly once — at `Error` level, tagged with `traceId`/`service` and this service's own primary correlation field named in its Observability & Instrumentation decision above — through the same Serilog/OTel pipeline, never a second, ad-hoc log line from a local catch block.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner
- [x] Approved to proceed to Architecture Agent
