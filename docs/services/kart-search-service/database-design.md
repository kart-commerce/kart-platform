---
doc_type: database-design
service: kart-search-service
status: approved
generated_by: database-design-agent
source: docs/services/kart-search-service/ddd-model.md, docs/services/kart-search-service/architecture.md, docs/services/kart-search-service/design-decisions.md, docs/services/kart-search-service/requirement-spec.md, docs/services/kart-search-service/edge-cases.md, docs/services/kart-search-service/api-contract.yaml, docs/requirements/kart-requirements.md
---

# Database Design: kart-search-service

## Architecture Note: OpenSearch Only, No PostgreSQL Write Side — a Standard Rebuildable Projection, Not `kart-delivery-tracking-service`'s Exception

Per `ddd-model.md`'s own header, this is **not** the same "no write side" exception `kart-delivery-tracking-service/database-design.md` documents for itself. That service's MongoDB collections are its *sole* durable source of truth (nothing else models a shipment's tracking state). Here, every field's true source of truth lives elsewhere — `kart-product-service`'s PostgreSQL (`product_groups`/`variants`), `kart-category-service`'s PostgreSQL, and `kart-review-service`'s own write side — and OpenSearch holds a fully disposable, rebuildable projection of all three, fed by events plus the batch bulk-export path (`architecture.md`'s "Index Rebuild Backfill Source"). This is `ddd-cqrs-standards.md`'s standard "read model always rebuildable from the write model(s) + event log" case, just with OpenSearch as the read-model technology instead of MongoDB, and three upstream write models instead of one. Treated with the lighter "read-model/projection changes can be marked approved directly" sign-off weight (`database-design-agent.md`), not write-model weight — there is nothing here a migration could break that isn't already independently durable in Product's/Category's/Review's own databases.

## Storage (OpenSearch) — Two Indices, Matching `ddd-model.md`'s Two-Aggregate Split

```
# ── search_products (alias: search-products-active) ────────────────────────
# Backs the SearchDocument aggregate (ddd-model.md). One document per SKU,
# _id = sku directly — every access path (GET /v1/search's query, the
# version/timestamp-guarded upsert on every consumed event) is either a
# full-text/aggregation query across the whole index or a point upsert by
# sku, never a secondary-key lookup.
PUT /search-products-000001
{
  "settings": {
    "number_of_shards": 8,
    "number_of_replicas": 1,
    "refresh_interval": "1s",          # near-real-time — architecture.md's Consistency-Lag SLA
    "index.max_result_window": 10000    # api-contract.yaml's pagination-window cap, enforced at the datastore layer too, not just the API layer
  },
  "mappings": {
    "properties": {
      "sku":            { "type": "keyword" },   # duplicated from _id — multi-match boosting needs it as a queryable field, not just a document identifier (BRD §17 "boosting on exact SKU/brand match")
      "name":           { "type": "text" },
      "description":    { "type": "text" },
      "brand":          {
        "type": "text",
        "fields": { "keyword": { "type": "keyword" } }   # analyzed for multi-match, .keyword sub-field for the exact-match boost clause (BRD §17)
      },
      "category": {
        "properties": {
          "categoryId":   { "type": "keyword" },  # facet + filter + shard-routing value, see Sharding below
          "categoryName": { "type": "keyword" }   # display only (ddd-model.md CategoryLookup denormalization), never queried/filtered on
        }
      },
      "price": {
        "properties": {
          "amount":   { "type": "scaled_float", "scaling_factor": 100 },  # 2-decimal money precision at lower storage cost than double (BRD §6.2's Money shape)
          "currency": { "type": "keyword" }
        }
      },
      "availability":   { "type": "keyword" },   # Active | Discontinued (ddd-model.md); default query always filters to Active — see "Default Query Filter" below
      "size":           { "type": "keyword" },   # facet; null-omitted at write time when Product's own value is null (mirrors Product's own partial-index treatment)
      "color":          { "type": "keyword" },   # facet; same null-omission
      "sponsored":      { "type": "boolean" },   # promoted out of extendedAttributes at write time — see "Sponsored Flag: Promoted to a First-Class Field" below
      "extendedAttributesRaw": { "type": "flattened" },  # schemaless catch-all, mirrors Product's own EAV/JSONB hybrid (kart-product-service/database-design.md) — never facet-queried, present only so a future requirement can add a new facet without a mapping migration
      "rating": {
        "properties": {
          "avg":   { "type": "double" },   # RankingProfile's ratingComponent input (ddd-model.md) — derived, not independently mutated, see "Rating Ledger" below
          "count": { "type": "integer" }
        }
      },
      "lastCatalogEventAt": { "type": "date" },  # ddd-model.md's version/timestamp guard comparison field
      "lastUpdatedAt":      { "type": "date" }
    }
  }
}

# Alias indirection (edge-cases.md "Index Rebuild During High Write Volume";
# design-decisions.md's blue-green rebuild decision): `/search` always queries
# the alias, never a literal index name, so a rebuild (mapping change,
# ranking-signal change, corruption recovery) can build a new
# `search-products-NNNNNN` index, replay + tail live events into it, then
# atomically repoint the alias — zero read-path downtime.
POST /_aliases
{ "actions": [ { "add": { "index": "search-products-000001", "alias": "search-products-active" } } ] }
```

```
# ── search_category_lookup ──────────────────────────────────────────────────
# Backs the CategoryLookup aggregate (ddd-model.md). One document per
# categoryId — a small, low-cardinality side index (bounded by distinct
# category count, not SKU count), consulted (never joined at query time) by
# the SearchDocument write path to resolve category.categoryName.
PUT /search-category-lookup
{
  "settings": { "number_of_shards": 1, "number_of_replicas": 1 },
  "mappings": {
    "properties": {
      "categoryId":   { "type": "keyword" },
      "categoryName": { "type": "keyword" },
      "lastUpdatedAt": { "type": "date" }   # CategoryUpdated's occurredAt guard (ddd-model.md)
    }
  }
}
```

```
# ── search_rating_ledger ─────────────────────────────────────────────────────
# Filling a gap ddd-model.md leaves implicit: where RatingSignal.perReviewRatings
# actually lives. NOT part of search_products' own mapping — a popular SKU can
# carry thousands of individual review ratings (BRD §6.2's own worked example:
# ratingSummary.count 1899), and none of that per-review detail is ever
# searched, filtered, or faceted on. Colocating it inside search_products would
# force a full-document reindex of every unrelated searchable field (name,
# description, price...) on every single new review — exactly the segment-
# merge cost this separate, narrow index avoids. One document per sku.
PUT /search-rating-ledger
{
  "settings": { "number_of_shards": 4, "number_of_replicas": 1 },
  "mappings": {
    "properties": {
      "sku": { "type": "keyword" },
      "perReviewRatings": { "type": "flattened" }   # { <reviewId>: <rating> } — write-side bookkeeping only, never queried directly; read back in full only to recompute avg/count on the next ReviewSubmitted/ReviewUpdated for that sku
    }
  }
}
```

### Consumer Write Paths (implements `ddd-model.md`'s invariants, doesn't re-derive them)

- **`ProductCreated`** → upsert into `search_products` (all fields from the enriched payload, ADR-0018); look up `search_category_lookup` by `categoryId` to populate `category.categoryName` (`null` if not yet present, ddd-model.md's Cross-Aggregate Interaction); `sponsored` promoted from `attributes.extendedAttributes.sponsored` (default `false`); `rating` initialized `{avg: 0, count: 0}` (no reviews yet); `lastCatalogEventAt`/`lastUpdatedAt` set to the write time. No guard needed — creation is unconditional.
- **`ProductPriceChanged`**, **`ProductUpdated`** → conditional update (`if incoming.occurredAt > stored.lastCatalogEventAt`), matching `kart-product-service/database-design.md`'s own optimistic guard style: `POST search-products-active/_update/{sku}` with a script asserting the guard before applying `$set`-equivalent field writes. `ProductUpdated` additionally re-resolves `category.categoryName` via `search_category_lookup` if `changedFields` includes the category.
- **`ProductDiscontinued`** → same conditional-update path, `$set: { availability: "Discontinued", lastCatalogEventAt: discontinuedAt, lastUpdatedAt }` only — no other field touched (edge-cases.md's soft-remove decision).
- **`CategoryUpdated`** → conditional update on `search_category_lookup` only (`if incoming.occurredAt > stored.lastUpdatedAt`) — never touches `search_products` directly (ddd-model.md's Cross-Aggregate Interaction: no fan-out write to every affected SKU on a category rename).
- **`ReviewSubmitted`/`ReviewUpdated`** → read-modify-write against `search_rating_ledger`'s `{sku}` document (`perReviewRatings[reviewId] = rating` / `= newRating`, idempotent by construction per ddd-model.md), then recompute `avg = mean(values)`, `count = size(map)` from the ledger's current contents and `$set: { rating, lastUpdatedAt }` onto the corresponding `search_products` document — a **field-scoped partial update touching only `rating`/`lastUpdatedAt`**, the same disjoint-field-set pattern `kart-product-service/database-design.md` already uses for its own identical `ratingSummary` projector, so this write can never race or clobber a concurrent catalog-origin update to the same document (disjoint fields, no shared version field needed for this pair specifically — the catalog-origin guard above is unaffected since it only ever compares `lastCatalogEventAt`, which this path never writes).

### Sponsored Flag: Promoted to a First-Class Field

`ddd-model.md` treats `sponsored` as a value read from within `attributes.extendedAttributes` (Product's own schemaless bag). At the OpenSearch-mapping level, a `flattened`-typed field cannot be referenced from a `function_score` scoring clause the way a first-class typed field can (`RankingProfile`'s `sponsoredBoost` component, `ddd-model.md`) — so this stage promotes it to its own top-level `sponsored: boolean` field at write time, extracted from the incoming event's `attributes.extendedAttributes.sponsored`, while every *other* `extendedAttributes` key remains in the untouched `extendedAttributesRaw` catch-all. This is the identical hybrid pattern `kart-product-service/database-design.md` already uses at the write side (first-class `size`/`color` columns plus a schemaless `extended_attributes` JSONB bag) — applied here for the one schemaless key that this service's own ranking formula needs to query against directly, not a new design principle.

### Default Query Filter — `availability: Active`

Every `/search` query (`api-contract.yaml`) applies an implicit `term` filter `availability: Active` before any user-supplied filter or the free-text match — `Discontinued` documents are retained (never hard-deleted, `ddd-model.md`) but never appear in a default result set (edge-cases.md "Discontinued Product Still Returned by Search"). Direct-SKU/admin lookup bypassing this filter is out of this contract's scope (`api-contract.yaml` exposes no such endpoint today — not a BRD-stated requirement).

## Rebuild Backfill Mechanism — Clarifying `architecture.md`'s Bulk-Export Dependency

`architecture.md`'s Dependencies table names a "paginated bulk read or scheduled full-catalog dump from Product's PostgreSQL write side" without fixing which of the two. Resolved here, since `kart-product-service/api-contract.yaml` (checked directly) exposes no bulk/export/internal endpoint of any kind today, and adding one there is out of this service's scope to unilaterally require: **the backfill source is a scheduled read against a read-replica of `kart-product-service`'s PostgreSQL** (`variants`/`product_groups`), not a REST call against any endpoint Product's own team must build or maintain. This is standard operational infrastructure (a read-replica for exactly this class of "read-heavy, off-the-critical-path" bulk consumer), keeps the two services' deployment lifecycles decoupled (no new contract for Product's API Design Agent to version), and still satisfies the Domain Invariant this mechanism exists to preserve: it reads Product's write-side data (not its MongoDB read model), off the request-serving path, at low/operator-controlled frequency. If a future revision of `kart-product-service/api-contract.yaml` adds a purpose-built export endpoint, switching to it is a drop-in replacement for this job's data source, not a redesign of the rebuild pipeline itself.

## Sharding

**`search-products-*`: routed by `category.categoryId`** — BRD §6.2 states `category.id` as the sharding key "for Product/Search collections," applied here via OpenSearch's `_routing` parameter (every upsert into `search_products` is routed by `category.categoryId`, and every `/search` query that names a `category` filter passes the same routing value to avoid a cross-shard fan-out for the common "browse within a category" case). A query with no `category` filter (a pure free-text or price/rating-only query) fans out across all 8 shards, same as any unrouted OpenSearch query — this is the accepted cost of not knowing the category ahead of time, unchanged from how Product's own MongoDB sharding behaves for a non-category-scoped query.

**`search-category-lookup`: unsharded (single shard)** — bounded by distinct category count (`kart-category-service/database-design.md`'s own "smaller, less-contended" framing), several orders of magnitude below SKU count; no sharding scheme is warranted at this cardinality.

**`search-rating-ledger`: routed by `sku`** — every access path (the review-event write, the avg/count recompute read) is a point operation keyed by `sku`; routing by `sku` keeps each read-modify-write local to one shard, avoiding the cross-shard coordination a category-based routing scheme would force for an aggregate this document doesn't otherwise touch.

## Indexing Rationale

| Index / Field | Query it supports | Why needed |
|---|---|---|
| `search_products.name`, `.description`, `.brand` (+`.keyword`) | `GET /v1/search`'s multi-match with SKU/brand exact-match boosting (BRD §17) | The core full-text query this entire service exists to serve; `.keyword` sub-fields exist specifically for the exact-match boost clause, not for filtering |
| `search_products.category.categoryId`, `.size`, `.color` (`keyword`) | Faceted aggregation + filtering (requirement-spec §2, capped at 5 concurrent filters/100 buckets per edge-cases.md) | Direct facet/filter fields — `keyword` (not analyzed) so aggregation buckets are exact values, not tokenized fragments |
| `search_products.price.amount` | Price-range facet/filter, `sort=price_asc/price_desc` | Range queries and sort both need a numeric field; `scaled_float` keeps 2-decimal precision at lower storage cost than `double` for a 100M-document index |
| `search_products.rating.avg` | `sort=rating_desc`; `RankingProfile`'s `ratingComponent` | Numeric sort/scoring input |
| `search_products.sponsored` | `RankingProfile`'s `sponsoredBoost` (`function_score` filter clause) | A `flattened` field cannot be referenced in a scoring function — promoted to first-class specifically for this (see "Sponsored Flag" above) |
| `search_products.availability` | The implicit default-query filter (above) | Every query filters on this; a `keyword` term filter is the cheapest possible query clause |
| `search-category-lookup._id` (=`categoryId`) | The `SearchDocument` write path's category-name resolution (ddd-model.md Cross-Aggregate Interaction) | Point lookup by id — no other access pattern exists against this index |
| `search-rating-ledger._id` (=`sku`) | The rating-event write path's read-modify-write | Point lookup/update by sku — no other access pattern exists against this index |

## Partitioning/Sharding at Scale

No further partitioning beyond the shard counts above is called for by any capacity assumption named upstream (BRD §4.1's 100M-SKU catalog is the basis for `search_products`' 8-shard count — sized for even category-routed distribution, not a precise capacity-tested figure; **flagged, not blocking**: real shard count/sizing is a load-testing exercise once actual query-volume and per-shard document-count data exist, the same "revisable baseline, not a load-tested number" posture `architecture.md`'s own OpenSearch `refresh_interval`/batch-size defaults already take).

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner
- [x] Approved (read-model/projection design — lighter sign-off weight per "Architecture Note" above; no write-model schema exists for this service to break)
