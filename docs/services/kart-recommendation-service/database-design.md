---
doc_type: database-design
service: kart-recommendation-service
status: approved
generated_by: database-design-agent
source: docs/services/kart-recommendation-service/ddd-model.md, docs/services/kart-recommendation-service/architecture.md, docs/services/kart-recommendation-service/design-decisions.md, docs/services/kart-recommendation-service/requirement-spec.md, docs/services/kart-recommendation-service/edge-cases.md, docs/services/kart-recommendation-service/api-contract.yaml
---

# Database Design: kart-recommendation-service

## Architecture Note: MongoDB Only, No PostgreSQL Write Side — a Standard Rebuildable Projection, Not `kart-delivery-tracking-service`'s Exception

Per `ddd-model.md`'s own header, this is the same classification `kart-search-service/database-design.md` gives itself, not `kart-delivery-tracking-service`'s "sole source of truth" exception: every field here is derivable by replaying `OrderDelivered` (from `kart-order-service`'s own PostgreSQL-backed event log), `ProductCreated` (from `kart-product-service`'s), and the three clickstream events (from the Client Event Ingestion Gateway's own durable Kafka log) from the beginning. All four collections below are `ddd-cqrs-standards.md`'s standard "read model always rebuildable from the write model(s) + event log" case, with MongoDB as the read-model technology and three upstream event sources instead of one. Treated with the lighter "read-model/projection changes can be marked approved directly" sign-off weight (`database-design-agent.md`) — there is nothing here a migration could break that isn't already independently durable elsewhere.

## Storage (MongoDB) — Four Collections, Matching `ddd-model.md`'s Four-Aggregate Split

```
// ── product_affinity ────────────────────────────────────────────────────────
// Backs the ProductAffinity aggregate (ddd-model.md). One document per SKU
// that has ever co-occurred with another SKU in a delivered order.
// _id = anchorSku. Access pattern: point upsert on OrderDelivered consumption
// (one upsert per co-occurring SKU pair per order), point read on
// RecommendationSet recompute (read the user's own purchased SKUs' rows).
{
  _id: "<anchorSku>",
  relatedSkus: {
    "<relatedSku>": {
      recentOrderIds: ["<orderId>", ...],   // bounded working set — see Compaction below
      confirmedCount: <int>,                 // derived count, the field purchaseAffinity actually reads
      lastUpdatedAt: ISODate(...)
    },
    ...
  },
  lastUpdatedAt: ISODate(...)
}
```

```
// ── user_behavior_profile ───────────────────────────────────────────────────
// Backs the UserBehaviorProfile aggregate (ddd-model.md). One document per
// user who has ever produced a clickstream event. _id = userId. Access
// pattern: point upsert per consumed ProductViewed/ProductClicked/
// SearchPerformed event; point read on RecommendationSet recompute.
{
  _id: "<userId>",
  skuScores: {
    "<sku>": {
      viewScore: <double>,    // time-decayed (14-day half-life, ddd-model.md)
      clickScore: <double>,
      lastEventAt: ISODate(...)
    },
    ...
  },
  lastEventAt: ISODate(...)
}
```

```
// ── trending_pool ───────────────────────────────────────────────────────────
// Backs the TrendingPool aggregate (ddd-model.md). Singleton — exactly one
// document, _id: "global". Access pattern: full-document read on every
// RecommendationSet recompute (cold-start/fallback source) and on every
// GET /recommendations/{userId} for a userId with no RecommendationSet yet
// (api-contract.yaml); full-document replace on the 15-minute recompute;
// single-entry upsert on ProductCreated (neutral seeding, out of band from
// the 15-minute cycle).
{
  _id: "global",
  items: [
    { sku: "<sku>", popularityScore: <double>, seededFrom: "Computed" | "NeutralSeed" },
    ...   // capped at top 500 (bounded candidate pool — see Indexing Rationale)
  ],
  computedAt: ISODate(...)
}
```

```
// ── recommendation_set ──────────────────────────────────────────────────────
// Backs the RecommendationSet aggregate (ddd-model.md) — the document
// GET /recommendations/{userId} serves directly. One document per user with
// at least one completed recompute. _id = userId. Access pattern: point read
// on every GET /recommendations/{userId}; wholesale point replace on the
// debounced (at most once per 5 min per user) recompute job.
{
  _id: "<userId>",
  items: [
    { sku: "<sku>", score: <double>, source: "Personalized" | "Fallback" },
    ...   // capped at a generous top-N (e.g. 200) at write time — api-contract.yaml's
          // `limit` (max 50) trims further at read time, so recompute cost isn't paid
          // per-request for every possible `limit` value a caller might ask for
  ],
  generatedAt: ISODate(...)
}
```

### Consumer/Recompute Write Paths (implements `ddd-model.md`'s invariants, doesn't re-derive them)

- **`OrderDelivered`** → for every unordered SKU pair `(A, B)` in the delivered order's line items, upsert both `product_affinity{_id: A}.relatedSkus.B` and `product_affinity{_id: B}.relatedSkus.A`: `$addToSet` the triggering `orderId` into `recentOrderIds`, recompute `confirmedCount` (see Compaction below). Redelivery-safe by construction (`ddd-model.md`) — a duplicate `orderId` is a no-op `$addToSet`. Marks both SKUs' purchasing users dirty for `recommendation_set` recompute.
- **`ProductCreated`** → single-entry upsert into `trending_pool.items` with `{sku, popularityScore: <neutral constant, e.g. the current median score>, seededFrom: "NeutralSeed"}`, immediately (not waiting for the 15-minute cycle) — closes the "Newly catalogued products" edge case.
- **`ProductViewed`/`ProductClicked`/`SearchPerformed`** → read-decay-increment against `user_behavior_profile{_id: userId}.skuScores.<sku>`: apply exponential decay to the existing `viewScore`/`clickScore` for elapsed time since `lastEventAt`, then add the event's own weight (`ProductClicked` > `ProductViewed` > `SearchPerformed`'s per-result-SKU contribution, per `ddd-model.md`). Marks `userId` dirty for `recommendation_set` recompute.
- **Trending Pool recompute (15-minute scheduled job)** → recomputes `popularityScore` for every SKU with recent `OrderDelivered`/clickstream volume over a rolling window, replaces `trending_pool.items` wholesale (bounded to top 500 by score), preserving any `NeutralSeed` entry that hasn't yet accumulated enough volume to get a `Computed` score.
- **RecommendationSet recompute (debounced, event-triggered, ≤ once per 5 min per dirty `userId`)** → reads `user_behavior_profile{_id: userId}` (if present), the `product_affinity` rows for every SKU the user has an `OrderDelivered` record for (resolved via a lightweight, this-service-local purchased-SKU index — see below), and `trending_pool`; applies the Recommendation Model formula (`ddd-model.md`); `$set`-replaces `recommendation_set{_id: userId}.items`/`generatedAt` wholesale.
- **Read path (`GET /recommendations/{userId}`)** → point read `recommendation_set{_id: userId}`; if absent, serve `trending_pool.items` directly (top `limit`, all `source: "Fallback"`) instead of an empty/404 response (requirement-spec §4). Applies the live availability filter (below) before returning.

### `PurchasedSkusByUser` — a Small Local Lookup Index, Not a Fifth Aggregate

`ddd-model.md` does not name a separate aggregate for "which SKUs has this user purchased" — that fact is Order's own, not Recommendation's to own. Resolving a purely mechanical gap the DDD model leaves implicit (the same way `kart-notification-service/ddd-model.md`'s `OrderUserIndex` resolves its own analogous "needed for a write path, not itself a domain concept" gap): a small `purchased_skus_by_user` collection (`{_id: userId, skus: Set<Sku>}`), upserted (`$addToSet`) alongside the `product_affinity` write on every `OrderDelivered`, exists solely so the `RecommendationSet` recompute job can resolve "which `product_affinity` rows does this user's own purchase history make relevant" without a cross-collection scan. Not a DDD aggregate in its own right (no invariant beyond upsert-on-consume) — a lookup projection, the same non-aggregate classification `kart-search-service/ddd-model.md` gives `CategoryLookup`'s sibling mechanisms.

## Compaction Mechanism — Bounding `recentOrderIds` (resolves `ddd-model.md`'s Modeling Decision 3)

`recentOrderIds` cannot grow without bound for a popular SKU pair (potentially thousands of contributing orders). Resolved as: a scheduled daily compaction job scans `product_affinity` documents, and for any `RelatedSkuAffinity` whose `recentOrderIds` contains an entry older than a **24-hour retention window** (matching the platform's realistic redelivery/retry window — `OrderDelivered`'s own 5x exponential-backoff retry tier, per `kart-order-service/event-contract.md`'s elevation over ADR-0005's original BRD-inherited number, still resolves within minutes to at most a few hours, never days), folds that entry into `confirmedCount` (`confirmedCount += 1`) and removes it from the set. This bounds `recentOrderIds` to "however many distinct orders arrived in the last 24 hours for this one pair" (small, even for a popular pair) while preserving exact redelivery-safety within the window duplicates could actually arrive in — an `orderId` compacted out and then (implausibly) redelivered weeks later would double-count, a risk accepted as negligible given the platform's own stated retry tiers never span that long.

## Cache (Redis) — Live Availability Filter

Per `design-decisions.md`'s "Caching Strategy for the Availability Filter" decision:

```
key: availability:{sku}
value: { inStock: <bool>, discontinued: <bool> }
ttl: 60s
```

Populated on cache miss by the live `GET /inventory/{sku}` + `GET /products/{id}` calls (batched at the API layer as `GET /inventory?skus=...`/`GET /products?ids=...` per `architecture.md`'s N+1 mitigation — one Redis `MGET` plus one batched call per cache-miss set, not one round-trip per candidate SKU). On a timeout or circuit-trip against either upstream, the read path serves the candidate list unfiltered (fail-open, `design-decisions.md`) and sets `api-contract.yaml`'s `availabilityFilterApplied: false` on the response — never blocks or empties the result.

## Indexing Rationale

| Collection / Field | Query it supports | Why needed |
|---|---|---|
| `product_affinity._id` (`anchorSku`) | `OrderDelivered` consumer's per-pair upsert; recompute job's per-purchased-SKU read | Point lookup/upsert by SKU — no other access pattern exists against this collection |
| `user_behavior_profile._id` (`userId`) | Clickstream consumer's per-event upsert; recompute job's per-user read | Point lookup/upsert by user — no other access pattern exists |
| `trending_pool._id` (`"global"`) | Every read-path fallback; every recompute job's read; `ProductCreated`'s neutral-seed upsert | Singleton document, no index beyond the default `_id` needed — a single-document collection has no cardinality to index against |
| `recommendation_set._id` (`userId`) | `GET /recommendations/{userId}`'s point read; recompute job's wholesale replace | Point lookup/replace by user — the entire reason this collection exists, matching `api-contract.yaml`'s only endpoint's access path exactly |
| `purchased_skus_by_user._id` (`userId`) | `RecommendationSet` recompute job's "which `product_affinity` rows matter for this user" resolution | Point lookup by user, avoiding a collection scan over `product_affinity` to answer a per-user question |

No compound or secondary index is needed anywhere in this service — every collection's sole access pattern is a point operation keyed by its own `_id`, unlike `kart-search-service`'s multi-field faceted queries.

## Sharding

**`product_affinity`: sharded by `_id` (`anchorSku`)** — every access (both the `OrderDelivered` upsert and the recompute job's read) is a point operation keyed by SKU; hashed-`_id` sharding spreads write load evenly regardless of any single SKU's popularity skew (a naive range shard on `anchorSku` string prefix would risk a hot shard for alphabetically clustered SKU schemes).

**`user_behavior_profile`, `recommendation_set`: sharded by `_id` (`userId`)** — every access is a point operation keyed by user; hashed-`_id` sharding for the same even-distribution reasoning, at platform user-base scale.

**`trending_pool`: unsharded (single document)** — a singleton has no cardinality to shard across.

**`purchased_skus_by_user`: sharded by `_id` (`userId`)**, same reasoning as `user_behavior_profile`.

## Row-Level Security Policy (BRD §24.1.4)

Restates `ddd-model.md`'s already-decided invariant at the storage layer, does not re-derive it: **`recommendation_set` is the only collection with a genuine per-caller ownership dimension** — every read is filtered on `userId` at this service's single, shared, unbypassable query-builder (the BRD §24.1.4 MongoDB mechanism), with the Support Agent/Admin cross-user-read exception as that query-builder's own explicit bypass branch (mirroring `kart-identity-service`'s `app.current_principal_kind IN ('service','system')` branch). `product_affinity`, `trending_pool`, and `purchased_skus_by_user` are never directly queried by any external caller (`api-contract.yaml` exposes no endpoint over any of them) — internal signal state with no caller-facing row-level question to answer, the same carve-out `kart-search-service/database-design.md` gives its own internal-only indices.

## Sensitive / PII Column Classification (BRD §24.1.5)

**No sensitive/PII columns exist.** Every field across all four collections plus `purchased_skus_by_user` is an opaque `sku`/`userId`/`orderId` reference or a derived numeric score (`popularityScore`, `viewScore`, `clickScore`, `confirmedCount`, `score`) — no column here is comparable to `kart-user-service`'s `addresses`/`phone` or `kart-identity-service`'s credential columns. Confirms `requirement-spec.md` §3's own carried-forward "must be confirmed, not assumed" note now that the field list is fixed (matching `ddd-model.md`'s identical conclusion).

## Partitioning/Sharding at Scale

The shard keys above are sized for the platform's stated user-base/catalog scale (no BRD-given precise figure for Recommendation specifically, per `requirement-spec.md` §3's Throughput row) — **flagged, not blocking**: exact shard/chunk sizing is a load-testing exercise once real per-user signal volume exists, the same "revisable baseline, not a load-tested number" posture `kart-search-service/database-design.md` already takes for its own shard counts.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner
- [x] Approved (read-model/projection design — lighter sign-off weight per "Architecture Note" above; no write-model schema exists for this service to break)
