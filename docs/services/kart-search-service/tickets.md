---
doc_type: tickets
service: kart-search-service
status: approved
generated_by: ticket-agent
source: [architecture.md, ddd-model.md, api-contract.yaml, database-design.md, event-contract.md, design-decisions.md, requirement-spec.md, edge-cases.md]
---

# Tickets: kart-search-service

Local draft. Not yet created as real GitHub Issues — that requires the target repo to exist (Scaffold Agent) and is a separate, explicit step.

**Input-freshness note:** `requirement-spec.md`, `edge-cases.md`, `design-decisions.md`, `architecture.md`, `ddd-model.md`, `database-design.md`, `event-contract.md`, and `api-contract.yaml` are all `status: approved` — every gap this pass found (the enriched `ProductCreated`/`ProductUpdated` payload, the new `CategoryUpdated`/`ReviewSubmitted`/`ReviewUpdated` consumption, the ranking formula, the in-stock signal source, the rebuild backfill mechanism) is resolved via [ADR-0018](../../adr/0018-search-catalog-signal-sourcing.md) and this service's own docs, with no stale "Open Question" or "TBD" remaining and no contradiction across the eight documents or against `kart-product-service`/`kart-category-service`/`kart-review-service`'s own approved docs. This ticket list decomposes directly from all eight docs' already-decided content.

## Epic: kart-search-service v1

Full-text product search, filters, facets, and blended ranking (BRD §2.1 item 5, §17) — a pure read/query-side service (requirement-spec.md §1) with **no PostgreSQL write side** (`database-design.md`'s Architecture Note — a standard rebuildable OpenSearch projection fed by seven consumed events from three publishers, not the same "sole source of truth" exception `kart-delivery-tracking-service` documents for itself).

| ID | Task | Vertical Slice (Application/Features/) | Depends On | Design Source |
|---|---|---|---|---|
| SRCH-1 | Consume `ProductCreated` — create a `SearchDocument` | `ConsumeProductCreated` | — | `event-contract.md` `ProductCreated` (`search.product-created.dlq`); `ddd-model.md` `SearchDocument` aggregate-creation invariant; `database-design.md` `search_products` mapping, upsert write path, `CategoryLookup` resolution at write time |
| SRCH-2 | Consume `ProductPriceChanged` — guarded price update | `ConsumeProductPriceChanged` | SRCH-1 | `event-contract.md` `ProductPriceChanged` (`search.product-price-changed.dlq`); `ddd-model.md`'s `lastCatalogEventAt` version/timestamp guard; edge-cases.md "Out-of-Order Event Consumption" |
| SRCH-3 | Consume `ProductUpdated` — guarded catalog-field update | `ConsumeProductUpdated` | SRCH-1 | `event-contract.md` `ProductUpdated` (`search.product-updated.dlq`, new consumption per [ADR-0018](../../adr/0018-search-catalog-signal-sourcing.md)); same `lastCatalogEventAt` guard as SRCH-2; re-resolves `category.categoryName` when `changedFields` includes the category |
| SRCH-4 | Consume `ProductDiscontinued` — soft-remove | `ConsumeProductDiscontinued` | SRCH-1 | `event-contract.md` `ProductDiscontinued` (`search.product-discontinued.dlq`); edge-cases.md "Discontinued Product Still Returned by Search" (`availability: Discontinued`, excluded from default results, never hard-deleted); same guarded write path as SRCH-2/SRCH-3, no second removal code path |
| SRCH-5 | Consume `CategoryUpdated` — maintain `CategoryLookup` | `ConsumeCategoryUpdated` | — | `event-contract.md` `CategoryUpdated` (`search.category-updated.dlq`, new consumption per ADR-0018); `ddd-model.md` `CategoryLookup` aggregate + its own `lastUpdatedAt` guard; `database-design.md` `search-category-lookup` index — independent of SRCH-1 (writes a different index; `SearchDocument` writes only *read* from this, never write to it) |
| SRCH-6 | Consume `ReviewSubmitted`/`ReviewUpdated` — maintain the rating ledger and recomputed `SearchDocument.rating` | `ConsumeReviewRatingEvents` | SRCH-1 | `event-contract.md` `ReviewSubmitted`/`ReviewUpdated` (`search.review-submitted.dlq`/`search.review-updated.dlq`, new consumption per ADR-0018); `ddd-model.md`'s per-`reviewId`-map idempotency invariant (not an incremental delta); `database-design.md` `search-rating-ledger` + the field-scoped `rating`-only partial update onto `search_products` |
| SRCH-7 | `GET /v1/search` — multi-match query with filters and ranking | `SearchProducts` | SRCH-1 | `api-contract.yaml` `GET /v1/search`; `ddd-model.md`'s `RankingProfile` formula (normalized text relevance + rating + in-stock + capped sponsored boost); `database-design.md`'s default `availability: Active` filter, `sponsored`/`rating` fields as `function_score` inputs |
| SRCH-8 | Faceted aggregation with query-timeout graceful degradation | `SearchProductsFacets` | SRCH-7 | `api-contract.yaml` `Facets`/`truncated`/`degradedFacets` schema; edge-cases.md "Query Timeout Under High-Cardinality Filters" (max 5 concurrent filters, max 100 buckets/facet, 300ms budget, drop least-selective facet(s) first); requirement-spec.md's "facets reflect the same filtered result set" Domain Invariant |
| SRCH-9 | Blue-green index rebuild pipeline (alias swap) | `RebuildSearchIndex` | SRCH-1, SRCH-5, SRCH-6 | edge-cases.md "Index Rebuild During High Write Volume"; design-decisions.md "Index Rebuild Strategy"; `database-design.md`'s alias-indirection setup and "Rebuild Backfill Mechanism" (scheduled read-replica pull from Product's PostgreSQL, tail live events during replay, atomic alias swap once caught up) — depends on SRCH-1/SRCH-5/SRCH-6 since the replay/tail step reuses those same event-consumer code paths against the new (not-yet-aliased) index |

## Flagged Gaps — Not Decomposed Into Tickets (would invent scope, not decompose it)

- **A richer, Inventory-sourced real-time stock-level ranking signal.** `architecture.md`'s "In-Stock Ranking Signal Source" deliberately scopes v1's in-stock signal to `Variant.status` (`Active`/`Discontinued`), not a live per-warehouse count, and explicitly declines to add a new `kart-inventory-service` dependency to get one. No ticket — building this would require a new published event on Inventory's own side, out of this service's scope to invent unilaterally.
- **Auctioned sponsored-placement bidding.** `ddd-model.md`'s "Ranking" section resolves this as capped, not auctioned, since no bidding/marketplace mechanism exists anywhere in the BRD's 18-service scope. No ticket — there is no auction subsystem to build against.
- **A management endpoint for setting `sponsored: true`.** Search only *consumes* the flag (via `attributes.extendedAttributes.sponsored` on `ProductCreated`/`ProductUpdated`); who is authorized to set it is `kart-product-service`'s/Admin's own write-path concern, not this service's.

## Notes for Sprint Planner Agent

- SRCH-1, SRCH-5 have no dependency and can start in parallel in sprint 1 — SRCH-1 is the aggregate-creation foundation every catalog-event consumer needs; SRCH-5 writes an entirely separate index (`search-category-lookup`) with no shared state.
- SRCH-2, SRCH-3, SRCH-4 all depend only on SRCH-1 (a `SearchDocument` must exist before it can be updated/discontinued) and are otherwise independent of each other — three parallel entry points into the same guarded-write pipeline, the same "shared logic, different trigger" shape `kart-inventory-service/tickets.md`'s INV-2/INV-3/INV-4 already establish for this platform's release-path tickets. Recommend implementing the shared version-guard write path once (as part of SRCH-2) and having SRCH-3/SRCH-4 each wire in a different trigger.
- SRCH-6 depends on SRCH-1 (needs an existing `SearchDocument` to attach a recomputed `rating` field to) but is otherwise independent of SRCH-2/SRCH-3/SRCH-4 (disjoint field set, `database-design.md`) — can run in parallel with them.
- SRCH-7 (the query path) depends on SRCH-1 (there must be indexed documents to query) but not on SRCH-2/SRCH-3/SRCH-4/SRCH-5/SRCH-6 individually — it queries whatever is currently indexed, regardless of which consumer wrote it last. SRCH-8 (facets) extends SRCH-7's same query path — sequence it directly after.
- SRCH-9 (rebuild) is this service's highest-value operational slice and depends on SRCH-1/SRCH-5/SRCH-6 since its live-tail phase reuses their consumer logic against a second, not-yet-aliased index — build it last, once the steady-state consumers are proven correct individually.
- No circular dependencies in this graph. Longest chain is SRCH-1 → SRCH-9 (4 deep, via SRCH-1/SRCH-5/SRCH-6 all feeding SRCH-9) or SRCH-1 → SRCH-7 → SRCH-8 (3 deep).
