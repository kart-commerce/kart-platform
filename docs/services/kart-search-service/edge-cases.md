---
doc_type: edge-cases
service: kart-search-service
status: approved
generated_by: edge-case-analyzer-agent
source: docs/services/kart-search-service/requirement-spec.md
---

# Edge Cases: kart-search-service

## Edge Case: Stale Search Results After Catalog Change

- **What happens:** A customer sees an outdated price or a not-yet-created product missing from search results for a window after `ProductPriceChanged`/`ProductCreated` fires.
- **Why it happens:** Search is deliberately eventually consistent (requirement-spec NFR "Consistency" row, BRD §2.2 forced decision) — the event has to traverse Outbox → RabbitMQ → consumer → OpenSearch refresh before it's queryable.
- **Solutions available (3):** synchronous dual-write to index on the catalog write path · async consumer with a tuned OpenSearch refresh interval · async consumer plus a client-visible "results as of" staleness hint
- **Decision:**
  - Chosen: async consumer over RabbitMQ with a tuned OpenSearch refresh interval; no synchronous write path
  - Why: BRD §2.2 explicitly forces the eventual-consistency conversation for Search, and a synchronous write would violate Search's read-optimized service boundary
  - Trade-off accepted: an unavoidable staleness window whose exact bound is unresolved (requirement-spec Open Question 1 has no numeric SLA yet)

## Edge Case: Index Rebuild During High Write Volume

- **What happens:** A full OpenSearch reindex (ranking-signal change, mapping change, or corruption recovery) must run while live `ProductCreated`/`ProductPriceChanged` events keep arriving.
- **Why it happens:** The index is a derived read model that is a "sibling" of, not dependent on, the MongoDB read model (requirement-spec Domain Invariant) — it must be independently rebuildable, but a naive rebuild can miss or double-apply events arriving mid-rebuild.
- **Solutions available (3):** blue-green reindex (build new index, replay history, tail live events, atomic alias swap) · in-place reindex with write-blocking · dual-write to old and new index during a transition window
- **Decision:**
  - Chosen: blue-green reindex via alias swap — replay catalog history into the new index while tailing live events, then swap the alias once caught up
  - Why: keeps `/search` continuously available, matching the read-path Availability/Latency NFRs; write-blocking would breach the read-path latency NFR
  - Trade-off accepted: needs an event-replay or catalog-snapshot source, since RabbitMQ has no native replay (BRD §14) — a periodic snapshot/backfill mechanism becomes a second dependency alongside the event stream

## Edge Case: Out-of-Order Event Consumption

- **What happens:** A `ProductPriceChanged` event is applied to the index after a newer one that superseded it, or a price-change event is processed before the `ProductCreated` event for the same SKU, leaving the index stale or in a half-created state.
- **Why it happens:** RabbitMQ's at-least-once delivery and retry/backoff ladder (requirement-spec Retry/DLQ row: 3x retry, `catalog.dlq`) give no ordering guarantee across redeliveries or between related events for the same SKU.
- **Solutions available (3):** version/timestamp-guard on index writes (apply only if newer than what's indexed) · per-SKU ordered routing so one consumer instance handles all events for a SKU in order · detect-and-rebuild the affected document on conflict
- **Decision:**
  - Chosen: version/timestamp-guard on writes, combined with per-SKU routing keys on the existing topic-exchange convention (kart-conventions.md routing-key pattern)
  - Why: cheapest fit against the existing RabbitMQ topology, no broker change required, and directly prevents stale overwrites without needing strict ordering
  - Trade-off accepted: does not give the strict per-key ordering a Kafka partition would (a named RabbitMQ limitation, BRD §14/§15) — Search is a plausible future candidate for the Kafka migration path if ordering needs tighten

## Edge Case: Query Timeout Under High-Cardinality Filters

- **What happens:** A search query combining several facet filters (category, price range, rating, free-text) against a 100M-SKU catalog times out or exceeds the P95 < 150ms / P99 < 400ms latency NFR.
- **Why it happens:** Server-side faceted aggregation (BRD §17) has no stated cardinality bound (requirement-spec Open Question 3), so nothing stops a query from requesting facet breakdowns at full catalog scale.
- **Solutions available (3):** hard cap on facet count/values per query · precomputed/cached facet buckets for common filter combinations on a TTL · query-time timeout that degrades to partial facets instead of failing the request
- **Decision:**
  - Chosen: hard cap on facet count/values per query plus a query-time timeout that degrades to partial/omitted facets rather than failing the whole response
  - Why: keeps `/search` within its latency NFR in the worst case, and degrading gracefully matches the platform's stated no-cascading-failure principle (BRD §3 Fault Tolerance row)
  - Trade-off accepted: the exact cap value is a business call, not an engineering default — left unresolved and escalated, consistent with requirement-spec Open Question 3
