---
doc_type: ddd-model
service: kart-search-service
status: approved
generated_by: ddd-agent
source: docs/services/kart-search-service/architecture.md, docs/services/kart-search-service/design-decisions.md, docs/services/kart-search-service/requirement-spec.md, docs/services/kart-search-service/edge-cases.md, docs/ddd/ubiquitous-language.md, docs/adr/0018-search-catalog-signal-sourcing.md
---

# DDD Model: kart-search-service

**Input-freshness note:** `requirement-spec.md`, `edge-cases.md`, `design-decisions.md`, and `architecture.md` are all `status: approved` with every blocking item resolved — including the three consumer-set/payload gaps `architecture.md` closed via [ADR-0018](../../adr/0018-search-catalog-signal-sourcing.md) (enriched `ProductCreated`/`ProductUpdated`, new `CategoryUpdated`/`ReviewSubmitted`/`ReviewUpdated` consumption). This model is derived directly from that already-decided dependency graph, not a re-derivation of it.

**Architecture note — this is a standard rebuildable CQRS projection, not the "no write side" exception.** Unlike `kart-delivery-tracking-service` (whose MongoDB collections are its *sole* durable source of truth, since nothing else models a shipment's tracking state), `kart-search-service`'s OpenSearch index is a foreign-fed, disposable, rebuildable projection in the fully standard `ddd-cqrs-standards.md` sense: the true source of truth for every catalog field lives in `kart-product-service`'s PostgreSQL write side (and, for the two fields Search denormalizes independently, `kart-category-service`'s and `kart-review-service`'s own write sides). Search owns no aggregate any other bounded context could ever need to load transactionally — every "aggregate" below is a read-side projection with its own internal consistency rules, the same modeling stance `kart-delivery-tracking-service/ddd-model.md` already established for a structurally similar (event-fed, no-own-write-model) service, applied here without inheriting that document's specific "sole source of truth" classification.

Two aggregate roots, each its own transaction boundary (the exact test in `ddd-agent.md`/`ddd-cqrs-standards.md`: if two "things" can't be saved in one transaction, they're two aggregates, not one) — `SearchDocument` is written once per inbound catalog/rating/category event, `CategoryLookup` is written once per inbound `CategoryUpdated`; neither ever needs the other inside the same transaction (a `SearchDocument` write reads `CategoryLookup` to resolve a display name, but that is a read of already-committed state, not a joint write).

## Aggregate: SearchDocument

**Entity:** `SearchDocument` — identified by `Sku` (value object, reused unchanged from `kart-product-service`'s own definition per ubiquitous-language.md's ACL rule — Search never redefines what a SKU is, only indexes documents keyed by it). One document per SKU, the entire unit `GET /search` queries and ranks over.

**Value objects:**
- `Sku` — referenced, not redefined (owned by `kart-product-service`).
- `Money` — `{ amount, currency }`, mirrors `kart-product-service`'s own value object; the last value carried on `ProductCreated`/`ProductPriceChanged`.
- `CategoryRef` — `{ categoryId, categoryName }`. `categoryId` comes from Product's own events; `categoryName` is resolved by looking up `CategoryLookup` (below) at write time — **never** copied from a Product-event field, since Product's write side has no such column (`kart-product-service/database-design.md`; [ADR-0018](../../adr/0018-search-catalog-signal-sourcing.md)).
- `Availability` — `Active | Discontinued`, mirrors `kart-product-service`'s `VariantStatus` one-directionally (edge-cases.md: discontinuation is never reversed here either — a reinstated SKU is modeled as a new `ProductCreated` for what is, from Search's perspective, a new document).
- `RatingSignal` — `{ avg: double, count: int, perReviewRatings: map<ReviewId, int> }`. Recomputed **deterministically from `perReviewRatings`** on every accepted `ReviewSubmitted`/`ReviewUpdated` (`avg = mean(values)`, `count = size(map)`) rather than incrementally mutated — see Invariants below for why.
- `FacetableAttributes` — `{ size, color, extendedAttributes }`, mirrors `kart-product-service`'s `ProductAttributes` value object unchanged in shape. `extendedAttributes.sponsored` (boolean, default `false`) is this service's own read of a field Product already treats as an opaque schemaless bag — Search assigns it ranking meaning (see `RankingProfile` below) without owning or redefining the attribute itself.
- `RankingProfile` — not a stored field, a **query-time scoring policy** applied identically to every request (see "Ranking — Resolved Scoring Formula" below). Modeled as a value object because it is an immutable, versionable rule set (revisable as a whole, never partially mutated), not because any one `SearchDocument` carries its own profile.

**Fields:** `sku`, `name`, `description`, `category: CategoryRef`, `brand`, `price: Money`, `availability: Availability`, `attributes: FacetableAttributes`, `rating: RatingSignal`, `lastCatalogEventAt` (the `occurredAt`/creation-time of the last accepted `ProductCreated`/`ProductPriceChanged`/`ProductUpdated`/`ProductDiscontinued`), `lastUpdatedAt` (this service's own last-write timestamp, any source).

**Invariants:**
- **A `SearchDocument` may only come into existence by consuming `ProductCreated`** (requirement-spec §2, architecture.md). Before that, no document exists for a SKU — there is no "pending" placeholder state, the same modeling stance `kart-delivery-tracking-service/ddd-model.md` Modeling Decision 2 already took for its own creation-trigger aggregate.
- **Catalog-origin writes (`ProductPriceChanged`, `ProductUpdated`, `ProductDiscontinued`) are guarded by `lastCatalogEventAt`**: an incoming event is applied only if its own `occurredAt` (or, for `ProductDiscontinued`, `discontinuedAt`) is strictly newer than the stored `lastCatalogEventAt` — otherwise it is rejected as a stale-ordered redelivery (edge-cases.md's "Out-of-Order Event Consumption," design-decisions.md's Decision 2). `ProductCreated` itself needs no guard — it is the document's creation event, nothing precedes it.
- **`RatingSignal` is recomputed from `perReviewRatings`, never mutated by an incremental delta.** A running `avg`/`count` mutated by `+rating` (`ReviewSubmitted`) or `+(newRating-oldRating)` (`ReviewUpdated`) is not safely idempotent under RabbitMQ's at-least-once redelivery (BRD §3) — neither event's payload carries a version/ordering field to guard against a duplicate application the way catalog events do (`orderId, sku, rating, reviewId, userId` / `orderId, sku, oldRating, newRating` — no `occurredAt`). Storing the authoritative per-`reviewId` rating and deriving `avg`/`count` from the map's current contents makes every write idempotent by construction: a redelivered `ReviewSubmitted` for an already-present `reviewId` overwrites the same value (no double-count); a `ReviewUpdated` is applied by overwriting `perReviewRatings[reviewId]` with `newRating` (not by applying a delta), so redelivery of the same update is likewise a no-op. This is a deliberately more defensive mechanism than `kart-product-service/database-design.md`'s own field-scoped `$set` for the identical signal (that document does not state a per-review dedup mechanism); adopting the stronger one here is a strictly-safer engineering default, not a contradiction of Product's own choice for its own copy.
- **`category.categoryName` is refreshed only from `CategoryLookup`, on any catalog-origin write that touches `categoryId`** (`ProductCreated`, or a `ProductUpdated` whose `changedFields` includes the category) — never from a Product event's own field, since none carries a name (see `CategoryRef` above).
- **`Discontinued` is one-directional and excludes the document from default `/search` results** (`available: false`, edge-cases.md's "Discontinued Product Still Returned by Search") — still retrievable by direct SKU lookup, never hard-deleted (requirement-spec §2 Domain Invariant, CQRS-rebuildability).
- **Facet counts returned alongside a query's results must reflect that same filtered result set** (requirement-spec §4 Domain Invariant) — enforced at query time (`api-contract.yaml`/`database-design.md`), not a stored-document invariant, but stated here since it constrains how `SearchDocument`'s indexed fields may be queried (aggregations must run against the same filter context as the hits they accompany, never a separately-cached facet table).
- **Index staleness relative to the source catalog stays within P95 < 5s / P99 < 15s**, measured from the source event's own origination (Outbox insert / `occurredAt`) to this document being searchable (requirement-spec §3) — a freshness bound on the write path as a whole, not a single-document field.

**Domain events:** None published (requirement-spec §5; Search is a pure consumer/query context). Consumed — all external, owned by other bounded contexts, referenced via ACL, never redefined:
- `ProductCreated`, `ProductPriceChanged`, `ProductUpdated`, `ProductDiscontinued` (`kart-product-service`) — the four catalog-origin writes above.
- `ReviewSubmitted`, `ReviewUpdated` (`kart-review-service`) — drive `RatingSignal` only, via `CategoryLookup`'s sibling mechanism described above; never touch any other field.
- `CategoryUpdated` (`kart-category-service`) — does not write `SearchDocument` directly; updates `CategoryLookup` (below), which `SearchDocument` writes read from.

## Aggregate: CategoryLookup

**Entity:** `CategoryLookup` — identified by `CategoryId` (referenced, owned by `kart-category-service`; never redefined here). One entry per category node this service has ever seen referenced by an indexed `SearchDocument`.

**Value objects:**
- `CategoryId` — referenced only (ACL), owned by Category.

**Fields:** `categoryId`, `categoryName`, `lastUpdatedAt` (the `occurredAt` of the last accepted `CategoryUpdated` for this id).

**Invariants:**
- Guarded by `lastUpdatedAt` the same way `SearchDocument`'s catalog-origin fields are — a `CategoryUpdated` older than the stored value is rejected as a stale redelivery.
- This is deliberately modeled as a **separate, small aggregate, not a field embedded per-`SearchDocument`**: many `SearchDocument`s share one `categoryId`, and `CategoryUpdated`'s own payload (`categoryId, name, parentId, path, operation, occurredAt`) describes one category node, not the set of SKUs under it — writing `CategoryLookup` once and having `SearchDocument` writes read from it avoids a fan-out write to every affected `SearchDocument` on every category rename (`kart-category-service/edge-cases.md`'s own "Subtree re-parenting invalidates downstream category data" decision explicitly defers exactly this "consumers resolve the affected range themselves" resolution to each consumer — this is Search's own resolution of it). A `SearchDocument`'s own `category.categoryName` field is therefore a **denormalized, eventually-consistent snapshot** taken at the `SearchDocument`'s own last catalog-origin write, not live-joined at query time — a renamed category's existing indexed SKUs show the old name until each SKU's own next `ProductUpdated`/`ProductPriceChanged`, unless the (non-blocking, see below) reconciliation sweep refreshes them sooner.
- **Non-blocking, flagged forward:** a category rename does not, by itself, force a re-index of every `SearchDocument` under that subtree — this document does not design that fan-out mechanism, since neither `requirement-spec.md`/`edge-cases.md` nor `kart-category-service`'s own docs name a required freshness bound for this specific field beyond "eventually." If a future requirement needs bounded-staleness category-name propagation, that is a new finding for a future revision, not a gap in today's design (the same "flagged, not blocking" posture `kart-delivery-tracking-service/database-design.md` already used for its own out-of-scope reference-data question).

**Domain events:** None published. Consumed: `CategoryUpdated` (external, `kart-category-service`) only.

## Cross-Aggregate Interaction

`CategoryLookup` and `SearchDocument` are never written in the same transaction. The only interaction is a **read**: a `SearchDocument` write triggered by `ProductCreated` or a category-touching `ProductUpdated` reads `CategoryLookup`'s current value for the event's `categoryId` to populate `category.categoryName` at write time. If no `CategoryLookup` entry exists yet for that id (e.g. `CategoryUpdated` for a brand-new category hasn't arrived yet, or never will if Category's own creation flow doesn't always publish before Product references it), `categoryName` is left `null` and the document is still indexed and searchable on every other field — a missing display label degrades one facet's UI presentation, never blocks indexing (consistent with requirement-spec's Domain Invariant that a stale/absent upstream dependency must never block search indexing).

## Ranking — Resolved Scoring Formula (closes requirement-spec Open Question 2 / design-decisions.md's carried-forward item)

BRD §17 names three blended signals (textual relevance, rating, in-stock status) plus a "controlled sponsored placement boost," without weights or a formula. Requirement-spec §6 Open Question 2 explicitly carried the formula itself to this stage while fixing the one non-negotiable constraint ("blended signals, not hard filters"). Resolved here as an initial, revisable baseline — not escalated further, since no BRD section or approved doc gives a reason to treat the *formula's* specific weights as a business/revenue decision distinct from the sponsored-placement *policy* question below:

```
finalScore = (textRelevanceNorm × 0.50)
           + (ratingComponent   × 0.20)
           + (inStockComponent  × 0.15)
           + sponsoredBoost                 // additive, capped at +0.15
```

- **`textRelevanceNorm`** — OpenSearch's native multi-match `_score` (BM25, boosted for exact SKU/brand match per BRD §17), min-max normalized against the current result window's top score so it composes on the same 0–1 scale as the other components (`api-contract.yaml`/`database-design.md` — implemented via `function_score`, not a separate re-ranking pass).
- **`ratingComponent`** — `rating.avg / 5.0` when `rating.count >= 5`; otherwise a neutral `0.5`. The count threshold is this stage's own engineering default, guarding against a single 5-star (or 1-star) review swinging a new product's rank as hard as an item with hundreds of reviews — not a BRD-stated number, revisable once real review-volume data exists.
- **`inStockComponent`** — `1.0` if `availability == Active` (the only value that reaches ranking at all, since `Discontinued` documents are excluded from default results before ranking runs — see architecture.md's "In-Stock Ranking Signal Source"). Kept as a named, separate component rather than folded away, so a future richer Inventory-sourced stock-level signal can replace this term without restructuring the formula.
- **`sponsoredBoost`** — `+0.15` if `attributes.extendedAttributes.sponsored == true`, else `0`. **Capped, not auctioned** (resolves requirement-spec Open Question 2's other half): no bidding/marketplace mechanism exists anywhere in the BRD's 18-service platform scope for an auctioned model to run against — inventing one would be a wholly new service/feature no BRD section asks for. A fixed, capped boost is the only buildable default within this service's own scope, and the cap (0.15, smaller than every other weighted component) keeps a sponsored placement from ever overriding a much stronger organic match, matching BRD §17's own "controlled" qualifier. Who is permitted to set `sponsored: true` (a business/pricing policy for Product/Admin's own write path) is explicitly out of this document's scope — Search only consumes the flag, it does not decide who may set it.

This is an initial, revisable baseline (`design-decisions.md`'s own framing for engineering-default constants applies identically here) — real click-through/conversion data may justify re-weighting later; that is a normal refinement, not a reopening of "blended, not hard-filtered."

## Referenced Elsewhere (owned by another bounded context — accessed via ACL, not redefined here)

| Term | Owning Context | How this service uses it |
|---|---|---|
| Sku / Product / Variant / ProductAttributes | `kart-product-service` | Every catalog field on `SearchDocument` is a denormalized copy sourced from Product's own events; this service never models `Product`'s or `Variant`'s own aggregate boundary, write-side schema, or archival cascade. |
| Category / CategoryId | `kart-category-service` | `CategoryLookup` mirrors only `categoryId → categoryName`; this service never models Category's taxonomy hierarchy, `AncestorPath`, or write-side invariants. |
| Rating / ReviewSubmitted / ReviewUpdated | `kart-review-service` | `RatingSignal` is a denormalized projection of Review's own canonical aggregate (ADR-0014); this service never models Review's moderation workflow, edit window, or verified-purchase gate. |

## Modeling Decisions & Assumptions (resolved here, not escalated — engineering defaults, revisable)

1. **Two aggregates (`SearchDocument`, `CategoryLookup`), not one.** Applying the transaction-boundary test directly: a category rename writes one `CategoryLookup` entry, never the (potentially very large) set of `SearchDocument`s referencing it — embedding category data as a live-joined reference rather than a per-document write-time snapshot avoids exactly that fan-out.
2. **`RatingSignal` recomputed from a per-`reviewId` map, not an incremental running total.** See `SearchDocument`'s Invariants above — chosen specifically because neither `ReviewSubmitted` nor `ReviewUpdated` carries an ordering/version field, so a delta-mutation approach cannot be made idempotent against RabbitMQ's at-least-once redelivery the way the catalog events' `occurredAt`-guarded approach can.
3. **`sponsored` reuses Product's existing `extendedAttributes` bag rather than requiring a new event or field.** Both `ProductCreated`'s and `ProductUpdated`'s (grown, ADR-0018) payloads already carry `attributes` — no further cross-service change is needed for this flag to reach Search; ranking meaning is assigned entirely on Search's own side.
4. **Ranking formula and sponsored-placement mechanism resolved directly** (see "Ranking" above) rather than left open — this run's autonomous-completion mandate treats the formula's specific weights as a defensible engineering default, and "capped vs. auctioned" as resolvable against the platform's actual buildable scope (no auction mechanism exists anywhere in the BRD), not a business call requiring further escalation.
5. **In-stock signal sourced from `Availability`, not a new Inventory dependency** — see `architecture.md`'s "In-Stock Ranking Signal Source"; restated here only insofar as it fixes `SearchDocument.availability` as the field the `RankingProfile`'s `inStockComponent` reads.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner
- [x] Approved to proceed to API/Database/Event Design Agents
