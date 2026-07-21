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
  - Trade-off accepted: a bounded staleness window is unavoidable — now quantified as P95 < 5s / P99 < 15s (requirement-spec NFR §3, Open Question 1, resolved), tuned via the OpenSearch refresh interval and consumer batch size; if real-world lag exceeds this bound under load, that's an Architecture Agent capacity question, not a reopening of this decision

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
  - Chosen: hard cap on facet count/values per query (max 5 concurrent facet filters, max 100 returned value-buckets per facet) plus a 300ms query-time budget — inside the P99 < 400ms latency NFR (requirement-spec §3) — after which the query degrades by dropping the least-selective facet filter(s) first (highest-cardinality facet dropped before lower-cardinality ones) and returns partial results with a `truncated: true` flag, rather than failing the whole request
  - Why: keeps `/search` within its latency NFR in the worst case, and degrading gracefully matches the platform's stated no-cascading-failure principle (BRD §3 Fault Tolerance row); dropping least-selective facets first preserves the filters most likely to narrow results meaningfully for the user
  - Trade-off accepted: this closes requirement-spec Open Question 3 as a single-service engineering default rather than a business/product call — the specific numbers (5 filters, 100 buckets, 300ms) are this spec's own defensible baseline, not a BRD-stated figure, and may need retuning once the Architecture Agent load-tests against the real 100M-SKU index; retuning the constant is a normal refinement, not reopening this decision. A truncated response is a worse UX than full facets, accepted in exchange for a bounded latency guarantee

## Edge Case: Discontinued Product Still Returned by Search

- **What happens:** A product that has been discontinued/delisted upstream keeps appearing in `/search` results because Search's index has no removal signal for it.
- **Why it happens:** BRD §5.4/§10 name only `ProductCreated` and `ProductPriceChanged` as Search's consumed events — no removal/discontinuation event existed in the BRD's own Event Catalog (requirement-spec Open Question 4, now resolved: `kart-product-service` has proposed a `ProductDiscontinued` event, requirement-spec §2/§5).
- **Solutions available (3):** consume `ProductDiscontinued` and hard-delete the document from the index · consume `ProductDiscontinued` and soft-remove it (flag as unavailable/excluded from default query results, document retained) · ignore the gap and rely on a periodic full reconciliation sweep against Product's read model
- **Decision:**
  - Chosen: consume `ProductDiscontinued` and soft-remove — flag the indexed document `available: false` and exclude it from default `/search` result sets (still retrievable by direct SKU lookup/admin tooling if ever needed), rather than a hard delete
  - Why: mirrors the write-side choice `kart-product-service` already made for the same event (soft-delete via a `status` field, not a hard delete, to keep history replayable — see its `edge-cases.md`'s "Discontinued/orphaned variant" edge case) — keeping Search's own removal semantics consistent with the upstream signal's own semantics avoids a hard-delete-vs-soft-delete mismatch across the two services describing the same lifecycle transition. It also reuses the same version/timestamp-guard write path already decided for the "Out-of-Order Event Consumption" edge case above, rather than introducing a second removal code path
  - Trade-off accepted: soft-removed documents remain in the index and consume storage/shard capacity indefinitely unless a separate periodic purge job is introduced later — acceptable because storage cost is cheap relative to the correctness risk of a hard delete racing an out-of-order in-flight `ProductPriceChanged` for the same SKU (which would silently resurrect a discontinued product with a mismatched exclusion flag)
