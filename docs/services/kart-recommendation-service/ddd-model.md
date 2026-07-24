---
doc_type: ddd-model
service: kart-recommendation-service
status: approved
generated_by: ddd-agent
source: docs/services/kart-recommendation-service/architecture.md, docs/services/kart-recommendation-service/design-decisions.md, docs/services/kart-recommendation-service/requirement-spec.md, docs/services/kart-recommendation-service/edge-cases.md, docs/ddd/ubiquitous-language.md
---

# DDD Model: kart-recommendation-service

**Input-freshness note:** `requirement-spec.md`, `edge-cases.md`, `design-decisions.md`, and `architecture.md` are all `status: approved` with every blocking item resolved — including the two carried-forward Open Questions this stage owns (requirement-spec Open Question 2, recommendation algorithm; the clickstream-behavioral-signal half of Open Question 3's staleness bound) and the one `architecture.md` resolved for itself this same pass (Open Question 1, clickstream publisher). This model is derived directly from that already-decided dependency graph, not a re-derivation of it.

**Architecture note — standard rebuildable CQRS projection, no PostgreSQL write side at all**, the same classification `kart-search-service/ddd-model.md` establishes for itself (not `kart-delivery-tracking-service`'s "sole source of truth" exception): every aggregate below is fully reconstructible by replaying `OrderDelivered`, `ProductCreated`, and the three clickstream events from the beginning of their respective event logs — Order's PostgreSQL write side remains the true source of truth for "what was purchased," Product's for "what exists," and the Client Event Ingestion Gateway's own durable Kafka log for "what a user viewed/clicked/searched." Recommendation's MongoDB collections hold derived signal and a derived served list, never a fact no other system of record could reconstruct.

Four aggregate roots, each its own transaction boundary (the exact test in `ddd-agent.md`/`ddd-cqrs-standards.md`): a write to one never needs to be atomic with a write to another. `ProductAffinity` is written once per anchor SKU per `OrderDelivered`; `UserBehaviorProfile` is written once per user per clickstream event; `TrendingPool` is written by its own periodic recompute job; `RecommendationSet` is written by its own periodic per-user recompute job that only *reads* the other three.

## Recommendation Model (closes requirement-spec Open Question 2 — resolved here, not escalated further)

BRD §2.1 item 18 names the feature ("Personalization, 'customers also bought'") without naming an algorithm. "Customers also bought" is itself the textbook description of **item-based collaborative filtering via purchase co-occurrence** — no BRD text points toward a trained ML model, a content-based (attribute-similarity) approach, or any other alternative, so the BRD's own phrase is treated as sufficient grounding for this engineering default rather than an unresolved product choice (the same posture `kart-search-service/ddd-model.md` took resolving its own ranking formula and sponsored-boost mechanism directly).

**Chosen model:**

```
score(user, candidateSku) = (purchaseAffinity × 0.60) + (behaviorSignal × 0.25) + (trendingBaseline × 0.15)
```

- **`purchaseAffinity`** — for each SKU the user has an `OrderDelivered` record for, sum `ProductAffinity`'s normalized co-occurrence strength toward `candidateSku`; 0 if the user has no purchase history at all.
- **`behaviorSignal`** — the user's own decayed view/click score for `candidateSku` from `UserBehaviorProfile`, normalized 0–1; 0 if no clickstream history exists for this user/SKU pair.
- **`trendingBaseline`** — `candidateSku`'s normalized global popularity score from `TrendingPool`; always available (seeded with a neutral default for a newly catalogued product per the resolved "Newly catalogued products" edge case), the only term a genuine cold-start user (zero purchase, zero behavior) contributes to their score.
- **Cold-start users** (edge-cases.md's "Cold-start user" decision): `purchaseAffinity = behaviorSignal = 0` for every candidate, so `score` degenerates to `trendingBaseline × 0.15`'s relative ordering — equivalent to ranking purely by `TrendingPool`, which is exactly the "non-personalized fallback" the edge case already committed to. The weights are not renormalized for this case (no division by the number of non-zero terms) — a genuinely cold-start user's list is meant to read as "generic popular," not as an artificially inflated single-signal score.
- **Weights (0.60/0.25/0.15) are an initial, revisable baseline** — the same framing `kart-search-service/ddd-model.md`'s own ranking formula uses for its weights — chosen because purchase history is the platform's strongest, least-noisy signal (an actual completed transaction) versus behavior (browsing intent, noisier, includes non-buying curiosity) versus trending (no personalization at all, the weakest possible signal, kept small and non-zero only to guarantee cold-start always resolves to something rather than a hard-coded special case).
- **Drift monitoring** (edge-cases.md's "Recommendation model/algorithm drift" decision) is algorithm-agnostic by design (measures click-through/conversion on whatever gets served) and needs no change now that this formula is fixed.

## Aggregate: ProductAffinity

**Entity:** `ProductAffinity` — identified by `anchorSku` (referenced, owned by `kart-product-service`; never redefined here — same ACL rule `kart-search-service/ddd-model.md` applies to its own `Sku` reference). One document per SKU that has ever co-occurred with another SKU in a delivered order; holds that SKU's own row of the (sparse, asymmetric-storage) co-occurrence matrix.

**Value objects:**
- `Sku` — referenced, not redefined (owned by `kart-product-service`).
- `RelatedSkuAffinity` — `{ relatedSku: Sku, recentOrderIds: Set<OrderId>, confirmedCount: int, lastUpdatedAt }`, one entry per SKU that has co-occurred with the anchor.

**Fields:** `anchorSku`, `relatedSkus: map<Sku, RelatedSkuAffinity>`, `lastUpdatedAt`.

**Invariants:**
- **Created/updated only by consuming `OrderDelivered`** — for every unordered pair `(A, B)` of SKUs within one delivered order's line items, both `ProductAffinity{anchorSku: A}.relatedSkus[B]` and `ProductAffinity{anchorSku: B}.relatedSkus[A]` are upserted (symmetric co-occurrence; "also bought" is not directional).
- **Idempotent under `OrderDelivered` redelivery by construction, not by a separate ledger** — resolving design-decisions.md's "upsert-based signal update keyed by `orderId`" decision the same way `kart-search-service/ddd-model.md`'s `RatingSignal` resolved its own identical redelivery problem: a raw incrementing counter is not safely idempotent under at-least-once delivery (BRD §3), so each `RelatedSkuAffinity.recentOrderIds` set-adds (`$addToSet`) the triggering `orderId` rather than incrementing directly; a redelivered `orderId` already present in the set is a no-op. `confirmedCount` (the actual number `purchaseAffinity` reads) is `confirmedCount + size(recentOrderIds)` — see database-design.md's compaction mechanism for how `recentOrderIds` is kept bounded (folded into `confirmedCount` and pruned after a retention window) rather than growing without limit for a popular pair.
- **No cross-anchor transaction.** One order touching N SKUs produces up to N×(N-1) `RelatedSkuAffinity` upserts across N different `ProductAffinity` documents — each individual upsert is its own transaction (the aggregate-boundary test: two different anchors' documents are never required to commit together), consistent with the platform's Eventual consistency NFR for this service (requirement-spec §3).

**Domain events:** None published (Recommendation publishes nothing, requirement-spec §2). Consumed: `OrderDelivered` (external, owned by `kart-order-service`, referenced via ACL — this aggregate never models Order's own Saga/state machine, only reads `orderId` + the order's SKU list as an opaque trigger).

## Aggregate: UserBehaviorProfile

**Entity:** `UserBehaviorProfile` — identified by `userId` (referenced, owned by `kart-identity-service`; never redefined here). One document per user who has ever produced a clickstream event.

**Value objects:**
- `UserId` — referenced only (ACL), owned by Identity.
- `SkuBehaviorScore` — `{ sku: Sku, viewScore: double, clickScore: double, lastEventAt }`, one entry per SKU the user has viewed, clicked, or searched into.

**Fields:** `userId`, `skuScores: map<Sku, SkuBehaviorScore>`, `lastEventAt`.

**Invariants:**
- **Created/updated only by consuming `ProductViewed`/`ProductClicked`/`SearchPerformed`** (event-contract.md) — `ProductViewed` increments `viewScore`, `ProductClicked` increments `clickScore` (weighted higher than a view, since a click is stronger buying-intent signal than a view), `SearchPerformed` contributes to every SKU in that event's own `resultSkus` at a smaller weight than a direct view (a search result the user never viewed or clicked is the weakest behavioral signal of the three).
- **Time-decayed, not a running total that only grows** — every increment is applied against the *current* score after applying exponential decay for elapsed time since `lastEventAt` (half-life: 14 days, an engineering default reflecting that browsing interest fades faster than purchase-based affinity, which never decays), so `behaviorSignal` in the scoring formula above reflects recent interest, not lifetime-accumulated interest.
- **Idempotency is best-effort, not a hard invariant** — unlike `OrderDelivered`, clickstream events carry no correctness-critical consequence from an occasional duplicate (requirement-spec §3/§4 state no BRD invariant for behavioral-signal accuracy the way the purchase-signal dedup edge case does for `OrderDelivered`), and clickstream volume (BRD §15's "firehose," edge-cases.md) makes a hard per-event dedup ledger a disproportionate cost for a soft ranking signal already tolerant of Eventual consistency. A short-lived (event-id, few-minute TTL) dedup cache absorbs the common case (consumer-group rebalance replay) without a durable ledger.

**Domain events:** None published. Consumed: `ProductViewed`, `ProductClicked`, `SearchPerformed` (external, owned by the Client Event Ingestion Gateway per `architecture.md`'s "Clickstream Publisher Resolution" — infrastructure, not a bounded context; these three event names/schemas are nonetheless formalized in `event-contract.md` as this service's own event-contract entries, the same way `kart-recommendation-service` formalizes `OrderDelivered`'s/`ProductCreated`'s already-external schemas without re-owning them).

## Aggregate: TrendingPool

**Entity:** `TrendingPool` — a singleton read model (one document, `poolId: "global"`) holding the platform-wide fallback/candidate list used for cold-start users and to seed newly catalogued products (edge-cases.md's "Cold-start user" and "Newly catalogued products" decisions).

**Value objects:**
- `TrendingEntry` — `{ sku: Sku, popularityScore: double, seededFrom: "Computed" | "NeutralSeed" }`.

**Fields:** `poolId`, `items: List<TrendingEntry>` (capped at a bounded top-N, e.g. 500, per database-design.md), `computedAt`.

**Invariants:**
- **Recomputed on a periodic 15-minute cycle** from aggregated `OrderDelivered`/clickstream volume over a rolling recent window (architecture.md's already-proposed bound) — `popularityScore` is a normalized rank over that window, not a lifetime total (so a product that was popular a year ago but isn't anymore naturally falls out).
- **`ProductCreated` seeds a `TrendingEntry` immediately, out of band from the 15-minute recompute** — `{ sku, popularityScore: <fixed neutral constant>, seededFrom: "NeutralSeed" }`, so a brand-new product is visible in the fallback pool the instant it's catalogued rather than waiting up to 15 minutes for the next scheduled recompute, closing the "Newly catalogued products" edge case's own invariant (requirement-spec §4) that a new product must never be permanently unrecommendable. The next scheduled recompute either promotes it to a `Computed` score (once it has accumulated real signal) or leaves the neutral seed in place (if it hasn't).
- **Never empty once the service has processed at least one `ProductCreated`** — `GET /recommendations/{userId}`'s "always return a response" invariant (requirement-spec §4) depends on `TrendingPool` always having at least the neutrally-seeded candidate set to fall back to.

**Domain events:** None published. Consumed: `ProductCreated` (external, owned by `kart-product-service`, per [ADR-0013](../../adr/0013-recommendation-productcreated-consumption.md) — referenced via ACL, never redefining Product's own `Variant`/`ProductStatus`).

## Aggregate: RecommendationSet

**Entity:** `RecommendationSet` — identified by `userId` (referenced, owned by `kart-identity-service`). One document per user, the exact document `GET /recommendations/{userId}` serves.

**Value objects:**
- `RecommendedItem` — `{ sku: Sku, score: double, source: "Personalized" | "Fallback" }`.

**Fields:** `userId`, `items: List<RecommendedItem>` (ranked, capped per `api-contract.yaml`'s response limit), `generatedAt`.

**Invariants:**
- **Written only by the recompute pipeline** — reads `ProductAffinity` (for the user's own purchased SKUs), `UserBehaviorProfile`, and `TrendingPool`, applies the Recommendation Model formula above, and upserts the user's `RecommendationSet` wholesale (never a partial/incremental patch — the same "replace wholesale" pattern `kart-notification-service/ddd-model.md`'s `OptOutMatrix` already uses for its own derived-from-elsewhere state).
- **Recompute is event-triggered and debounced to at most once per 5 minutes per user** — an `OrderDelivered`, a `ProductCreated`-driven `TrendingPool` change, or a clickstream event all mark the affected user(s) dirty; a scheduler flushes each dirty user's recompute at most once per rolling 5-minute window, closing `architecture.md`'s staleness SLA uniformly across all three input types (Open Question 3) without a recompute storm from a high-frequency clickstream user.
- **`items` is never empty** — if a user has no `RecommendationSet` document yet (never computed, e.g. brand-new `userId` with zero signal of any kind), the read path (see `api-contract.yaml`) serves `TrendingPool` directly rather than a 404/empty body, satisfying requirement-spec §4's "always return a response" invariant even in the gap before this user's first recompute has ever run.
- **The synchronous availability filter (Inventory/Product live check) is applied at *read time*, not baked into the stored document** — `RecommendationSet.items` may reference a SKU that has since gone out of stock or been discontinued; `architecture.md`'s resolved synchronous filter (with Redis-cached fail-open circuit breaker, `design-decisions.md`) removes such items from the response on the way out, so the stored aggregate itself is allowed to be one recompute cycle stale on availability without violating any correctness invariant — availability freshness is a read-path concern, not a `RecommendationSet` write-path one.

**Domain events:** None published (requirement-spec §2/§5; confirmed unchanged — Recommendation remains a terminal node in the platform's event graph).

## Cross-Aggregate Interaction

`ProductAffinity`, `UserBehaviorProfile`, and `TrendingPool` are never written in the same transaction as each other or as `RecommendationSet`. The only interaction is **read**: the `RecommendationSet` recompute job reads current snapshots of the other three to compute one user's blended score list. If any one of the three has no data yet for a given user/SKU (e.g. a user with purchases but no clickstream history), its corresponding term in the scoring formula is simply `0` — a missing upstream signal degrades one term's contribution, never blocks the recompute (mirroring `kart-search-service/ddd-model.md`'s "a missing upstream dependency degrades one field, never blocks the write" posture for its own `CategoryLookup` read).

## CanRead/CanWrite/CanDelete, Row-Level, and Audit Invariants (BRD §24.1.2/§24.1.4/§24.3 — decided here, not left implicit)

- **`RecommendationSet` has a genuine per-user ownership dimension** — unlike `kart-search-service`'s public `SearchDocument`, a `RecommendationSet` is per-`userId` personalized content. **`CanRead` on `GET /recommendations/{userId}`: the caller's own `token.sub` must equal the path `userId`, with Admin/Support Agent able to read any `userId`'s set** (requirement-spec §3's already-stated resolution, restated here as the aggregate-level invariant it actually is) — a plain ownership comparison, no persisted grant table, the same bucket BRD §24.1.2 places Cart/Wishlist/User Service in.
- **No externally-reachable `CanWrite`/`CanDelete` exists for any of the four aggregates** — every write is this service's own internal consumer/recompute pipeline (`OrderDelivered`, `ProductCreated`, the three clickstream events, and the periodic `TrendingPool`/`RecommendationSet` recompute jobs), never a caller-invoked command, the same posture `kart-search-service/ddd-model.md` establishes for its own aggregates.
- **Row-level security mechanism**: `RecommendationSet`'s query-builder filters on `userId` at this service's data-access boundary (BRD §24.1.4's MongoDB mechanism), with the Support Agent/Admin bypass branch as its own explicit, centralized exception (mirroring `kart-identity-service`'s `app.current_principal_kind IN ('service','system')` branch) — never an unguarded query path. `ProductAffinity`, `UserBehaviorProfile` (keyed by `userId` but never directly queried by any external caller — see `api-contract.yaml`, which exposes no endpoint over either), and `TrendingPool` (a singleton, no per-user dimension at all) need no row-level policy of their own; they are internal signal state, not a caller-addressable resource.
- **No PII column exists.** Every field across all four aggregates is an opaque `Sku`/`userId`/`orderId` reference or a derived numeric score — never a contact/identity field comparable to User Service's `addresses`/`phone` or Identity's credential columns (requirement-spec §3's already-stated expectation, now confirmed against the actual field list above).
- **Audit-actor fields (BRD §24.3)**: no PostgreSQL `DbContext` exists (all-MongoDB, per the Architecture Note above), so `kart-shared`'s EF Core `SaveChanges` interceptor has nothing to hook — the same carve-out `kart-delivery-tracking-service`/`kart-search-service` document for their own all-MongoDB write paths. Every write to every collection here originates from this service's own internal consumers/recompute jobs, never a human/API caller; each collection carries `createdAt`/`updatedAt` stamped by the ingestion/projection pipeline via `kart-shared`'s `ICurrentPrincipalAccessor` with a well-known `system:*` principal id per writer (`system:order-delivered-consumer`, `system:product-created-consumer`, `system:clickstream-consumer`, `system:trending-pool-recompute`, `system:recommendation-set-recompute`), never `NULL` — resolving requirement-spec §3's own carried-forward "must be confirmed, not assumed" note now that the field list is fixed.

## Referenced Elsewhere (owned by another bounded context — accessed via ACL, not redefined here)

| Term | Owning Context | How this service uses it |
|---|---|---|
| Sku / Product / Variant | `kart-product-service` | `ProductAffinity`/`TrendingPool`/`RecommendationSet` reference SKUs opaquely; `GET /products/{id}` (architecture.md) is consulted only for live discontinued-status filtering at read time, never to model Product's own catalog aggregate |
| UserId | `kart-identity-service` | Every `userId` field is a reference only; this service never models authentication, sessions, or account state |
| OrderDelivered / Order | `kart-order-service` | Consumed only as the purchase-signal trigger (`orderId` + line-item SKUs); never models Order's own Saga/state machine |
| WarehouseStock / `GET /inventory/{sku}` | `kart-inventory-service` | Consulted only for live stock-level filtering at read time (architecture.md); never models Inventory's own `Reservation`/`WarehouseStock` aggregates |

## Modeling Decisions & Assumptions (resolved here, not escalated — engineering defaults, revisable)

1. **Four aggregates, not one or two.** Applying the transaction-boundary test directly: `ProductAffinity` writes are per-anchor-SKU (up to N per order), `UserBehaviorProfile` writes are per-user-per-event, `TrendingPool` writes are a single periodic batch, and `RecommendationSet` writes are per-user-per-recompute — no two of these ever need to commit together, so collapsing any pair into one aggregate would force an unnecessary joint transaction the way `kart-search-service/ddd-model.md`'s own two-aggregate split (`SearchDocument`/`CategoryLookup`) already reasons about avoiding a similar fan-out write.
2. **Client Event Ingestion Gateway is infrastructure, not a fifth bounded context.** Resolved at the Architecture stage (see `architecture.md`); restated here only so the three clickstream event names this service's own `event-contract.md` formalizes aren't mistaken for events this service itself owns/publishes.
3. **`ProductAffinity`'s bounded `recentOrderIds` + `confirmedCount` split (not an unbounded per-pair order-id set, not a separate dedup ledger)** is this stage's own resolution of design-decisions.md's "upsert-based signal update keyed by `orderId`" decision for a *counting* (not overwriting) aggregate — `database-design.md` details the compaction mechanism this invariant depends on.
4. **Recommendation Model weights (0.60/0.25/0.15) and the 14-day behavioral half-life** are engineering defaults, explicitly flagged as revisable once real click-through/conversion data exists (feeding back through the already-decided Analytics-based drift-monitoring mechanism, edge-cases.md) — not a business/product decision requiring further escalation, the same posture `kart-search-service/ddd-model.md`'s own ranking-weight resolution takes.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner
- [x] Approved to proceed to API/Database/Event Design Agents
