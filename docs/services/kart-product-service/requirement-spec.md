---
doc_type: requirement-spec
service: kart-product-service
status: approved
generated_by: requirement-agent
source: docs/requirements/kart-requirements.md
---

# Requirement Spec: kart-product-service

## 1. Scope

Covers one BRD service: **Product** (BRD §2.1 item 3, "Product catalog, variants, attributes"). No merge, no ADR — this is a single bounded context on its own.

Product is the catalog system-of-record: it owns product identity, variants, attributes, and the base/list price. It is also one of the platform's highest-fan-out event publishers — Search, Recommendation, Wishlist, Offer/Pricing, and Analytics all react to its events (BRD §10; Analytics per ADR-0004's platform-wide full fan-in default).

## 2. Functional Requirements

### Catalog

- Serve product detail reads (`GET /products/{id}`, BRD §5.4), backed by a denormalized MongoDB read model (BRD §5.4, §6.2).
- Own product creation, publishing `ProductCreated` (sku, attributes) on success (BRD §10). The BRD names no inbound write endpoint for this (only `GET /products/{id}` appears at §5.4) — **resolved** (formerly Open Questions #4, single-service engineering default, no ADR needed): Product exposes its own write API (§5 API Surface, `POST /products`, `PUT`/`PATCH /products/{id}`) as the system-of-record write path; BRD §24.1 names "catalog management" as an `Admin`-role grant and "bulk catalog upload" as a `Partner API`-role grant, so both the Admin back-office surface (`/admin/*`) and the Partner API are expected callers of this write surface, not a replacement for it — both routes call into Product's own API rather than writing to Product's database directly, consistent with the platform's universal "a service's own store is never written by another service" pattern already in effect everywhere else in the BRD (e.g. §6.1's per-service DB column).
- Own product base/list price as the system-of-record, publishing `ProductPriceChanged` (sku, oldPrice, newPrice) on change (BRD §10, resolved reading — see Open Questions #1).
- Support variants and attributes as a first-class part of the catalog model (BRD §2.1 item 3 names this explicitly as core scope). The BRD gives no schema detail for either; **resolved** (formerly Open Questions #3, single-service engineering default, no ADR needed) with a concrete hybrid EAV/JSONB schema — see "Variant & Attribute Data Model" below.
- Support discontinuing a SKU/variant via a soft-delete `status` field (now a concretely-placed field on the variant row, per the schema below) plus a proposed `ProductDiscontinued` event (not BRD-stated — see `edge-cases.md`'s "Discontinued/orphaned variant" edge case and API Surface below). This follows the same "propose, flag, don't silently invent" precedent `kart-offer-service` used for `CouponRedemptionVoided`/`PromotionDeactivated`; not final until the DDD Agent stage formalizes it the way ADR-0008 later formalized Offer's proposed events.
- Publish `ProductUpdated` on non-price catalog edits (name, description, attributes, category, status) made via `PUT`/`PATCH /products/{id}` (BRD §16 names this event in cache-invalidation prose but it was absent from the Event Catalog — **resolved**, formerly Open Questions #6, single-service default: see API Surface below).

### Variant & Attribute Data Model (resolves Open Questions #3 — blocking, now closed)

The BRD names "variants, attributes" as core scope (§2.1 item 3) but gives zero schema detail. Concrete decision, grounded in the BRD's own stated 100M-SKU scale (§4.1), read-heavy/browse-locality NFR (§6.1), and the read model's existing `_id: "sku-..."` keying convention (§6.2):

- **Product** (parent/grouping entity, PostgreSQL write side): `id`, canonical `name`, `description`, `category_id`, `brand`, `status`. Groups one or more sellable variants. Aggregate-boundary question (whether Variant is a child entity inside the Product aggregate or its own aggregate referencing Product by ID) is deliberately left to the DDD Agent — that is its job, not this spec's.
- **Variant = the actual sellable, priced unit** (matches the SKU-uniqueness invariant in §4 and the read model's own SKU-keyed example at §6.2): `sku` (globally unique, PostgreSQL unique constraint, write-side enforced), `parent_product_id` (FK), `price`/`currency` (the base/list price lives here, since price is quoted per-SKU, not per-parent-product), `status` (`active` / `discontinued` — feeds the proposed `ProductDiscontinued` event above).
- **Attributes: hybrid EAV/JSONB, not pure EAV and not pure free-form JSON.** A small, fixed set of common, high-cardinality-filtered attributes (`size`, `color`) are first-class indexed columns directly on the variant row, because browse/facet queries need fast indexed equality/range filtering on exactly these at 100M-SKU scale (BRD §6.1's stated read-heavy reasoning). Everything else — material, wattage, fit, and any other category-specific spec — lives in a schemaless `attributes JSONB` column, since a fixed relational schema can't accommodate every category's differing attribute set without either an unmaintainably sparse wide table or per-category tables.
  - Why not pure EAV: one-row-per-attribute multiplies row count many-fold for exactly the attributes browse/search need to filter on fastest, and doesn't index as well as native columns.
  - Why not pure JSONB: an indexed equality/range filter on `size`/`color` across 100M rows needs a real column index, not GIN-scan-every-document.
  - Trade-off accepted: promoting a new attribute from the JSONB bag to a first-class indexed column later (e.g. if `material` turns out to need fast filtering too) requires a schema migration, not just a new JSON key — mitigated by keeping the first-class list intentionally small and revisiting it at the DDD/Architecture Agent stage if browse/facet query patterns demand more.
- **Read model:** `product_read_model` embeds an array of variant subdocuments (each carrying `sku`, `price`, `status`, the indexed common attributes, and the JSONB attribute bag) inside the parent product document — consistent with BRD §6.2's existing denormalization-to-avoid-cross-shard-joins pattern, still sharded by `category.id` (§6.2) for browse-query locality.

### Read-model / caching integration

- Serve product detail reads from Redis cache-aside in front of the MongoDB read model, populated on miss with a TTL (BRD §16).
- Invalidate the Redis cache explicitly on price-change events rather than relying on TTL alone, so stale prices are not served after a `ProductPriceChanged` (BRD §16).
- Denormalize category name, price, and rating summary directly into the `product_read_model` MongoDB document to avoid cross-shard joins on the read path (BRD §6.2).
- Shard the MongoDB read model (and Search's collection) by `category.id` for browse-query locality (BRD §6.2).

### Ratings integration

- Recalculate a product's rating summary in response to `ReviewSubmitted` (BRD §10 Event Catalog lists Product as a consumer "for rating recalc"). BRD §5.4's condensed service table lists Product's Consumes column as "—", which reads as a contradiction in isolation — **resolved** (formerly Open Questions #2, cross-cutting — spans Product and Review, now formally closed by ADR): Product does consume `ReviewSubmitted`. §5.4 is explicitly the BRD's condensed/summary table, and it is independently confirmed incomplete elsewhere for consumer columns (e.g. Category's `CategoryUpdated`, User's `UserAccountUpdated`/`UserRegistered` inbound events are likewise absent from other services' §5.4 rows despite being real). This is now formally settled by ADR-0014 (`docs/adr/0014-review-rating-aggregate-ownership.md`): Review Service owns the canonical rating aggregate (BRD §2.1 item 14); Product's "rating recalc" is a denormalized, eventually-consistent projection of the same `ReviewSubmitted` stream into `product_read_model.ratingSummary`, not a second canonical computation. `kart-review-service`'s own approved `requirement-spec.md` already stated this as settled fact independently; this ADR is now the authoritative citation for both sides. See Open Questions for the narrower remaining question (staleness bound, non-blocking).

### Fan-out awareness

- `ProductCreated` is consumed by Search, Recommendation, and Analytics (BRD §10; Analytics per ADR-0004's platform-wide full fan-in default, which also independently confirms this row).
- `ProductPriceChanged` is consumed by Search, Wishlist, Offer/Pricing, and Analytics (BRD §10, §5.4 — Pricing's row lists `ProductPriceChanged` under Consumes; Analytics per ADR-0004).

## 3. Non-Functional Requirements

Pulled from the BRD's global NFR table (§3) and capacity/caching sections, scoped to this service:

| Attribute | Target | Applies here because |
|---|---|---|
| Availability | 99.9% (secondary path) | BRD's 99.99% tier is explicitly scoped to "order path" (§3); Product read path is not on the Order Saga's critical path (§5.5 diagram shows Product only reachable from the Gateway, not from Order's saga calls) |
| Latency | P95 < 150ms, P99 < 400ms (read path) | `GET /products/{id}` is a read-path endpoint; product reads dominate the platform's 20:1 read:write ratio (§4.4) |
| Throughput | Read-heavy, scales independently of write (BRD §6.1 table explicitly names Product as read-heavy) | Catalog size is 100M SKUs (§4.1) with reads driven by browse/search traffic, not proportional to catalog writes |
| Consistency | Strong (PostgreSQL write path), Eventual (MongoDB read path) | Explicit CQRS split named for Product in §6.1 ("Product, Search, Category \| Read-heavy \| ... MongoDB/denormalized is source of truth for reads") |
| Reliability | At-least-once delivery + idempotent consumers | Applies to `ProductCreated`/`ProductPriceChanged` publication and `ReviewSubmitted` consumption (global NFR, §3) |
| Retry/DLQ | 3x retry, `catalog.dlq` (BRD §10, both `ProductCreated` and `ProductPriceChanged` rows) | Looser than the `Payment*` 5x/paged tier — BRD explicitly frames catalog events as tolerating seconds of staleness (§10 footnote, §2.2) |
| Storage | ~2 TB MongoDB (denormalized), sharded (§4.3, §6.2) | Direct capacity target for Product's read model |

## 4. Domain Invariants

- Product owns the canonical/base list price; Pricing only computes derived quotes (tax, currency, promotions applied) and never announces base price changes — settled by kart-offer-service's requirement-spec.md (Open Questions #1 there), not independently re-litigated here.
- Price is owned at the variant/SKU level, not the parent-product level (see "Variant & Attribute Data Model," §2) — a SKU is the sellable, priced unit; the parent product is a grouping entity only.
- Product's rating summary is a **denormalized projection, not the canonical aggregate** — Review Service owns canonical rating computation (BRD §2.1 item 14); Product's copy must eventually reflect all `ReviewSubmitted` events for that SKU but is not the system-of-record for rating correctness. Formally settled by ADR-0014 (`docs/adr/0014-review-rating-aggregate-ownership.md`). The BRD does not state a staleness bound for how quickly the projection must catch up — see Open Questions (non-blocking, Architecture Agent stage).
- The MongoDB read model must always be rebuildable from the PostgreSQL write side plus replayed events — the general CQRS safety property the BRD states for the platform (§7), applied here since Product is named as one of the CQRS-split services (§6.1). This is also why discontinuation is modeled as a soft-delete `status` flag rather than a hard delete (see `edge-cases.md`'s "Discontinued/orphaned variant" edge case) — a hard delete would make history unreplayable.
- Every SKU is presumed unique across the catalog (inferred from "Product catalog" framing and the `_id: "sku-..."` read-model example at §6.2). **Resolved** (single-service engineering default, no ADR needed — see `edge-cases.md`'s "SKU uniqueness enforcement at 100M-SKU scale" edge case): enforced via a PostgreSQL unique constraint on the variant/SKU write-side table, independent of the MongoDB read model's `category.id` shard key.
- Catalog edit history: Product retains price-change history implicitly via each `ProductPriceChanged` event's `oldPrice`/`newPrice` payload fields (BRD §10) — a consumer needing "price as of time T" can reconstruct it from the replayed event stream without Product maintaining a separate audit table. **Resolved** (formerly Open Questions #5, single-service engineering default): this is sufficient for the one concrete downstream need the BRD names (Wishlist's old-vs-new price comparison, already satisfied by the event payload itself). Whether a *dedicated* audit/rollback table beyond the replayable event stream is also warranted at 100M-SKU scale is a data-lifecycle/retention-policy call with no further BRD detail to ground it — legitimately carried to the DDD/Architecture Agent stage, not decided here (non-blocking).

## 5. API Surface (from BRD, starting point only)

| Endpoint/Event | Direction | Notes |
|---|---|---|
| `GET /products/{id}` | Inbound API | BRD §5.4 — the only endpoint the BRD names for this service |
| `POST /products` | Inbound API | **New — resolves Open Questions #4 (formerly missing write API, blocking).** Creates a product and its initial variant/SKU; publishes `ProductCreated`. Callers: Admin's `/admin/*` back-office surface and the Partner API (bulk catalog upload), per BRD §24.1's role grants — both call into this API, they do not write Product's database directly. |
| `PUT /products/{id}` / `PATCH /products/{id}` | Inbound API | **New — resolves Open Questions #4.** Updates product/variant attributes, price, or status. A price-field change publishes `ProductPriceChanged`; any other field change publishes `ProductUpdated`. Setting `status` to discontinued publishes the proposed `ProductDiscontinued` (see `edge-cases.md`). Exact verb/resource shape (e.g. whether variants get their own sub-resource) is the API Design Agent's job, not this spec's — this row only establishes that a write surface exists and where it publishes to. |
| `ProductCreated` | Published | Consumed by Search, Recommendation, and Analytics (BRD §10; Analytics per ADR-0004's full fan-in default) |
| `ProductPriceChanged` | Published | Consumed by Search, Wishlist, Offer/Pricing, and Analytics (BRD §10, §5.4; Analytics per ADR-0004) — publisher resolved to Product, see Open Questions #1 |
| `ProductUpdated` | Published | **Resolved (formerly Open Questions #6, single-service default).** A genuine event distinct from `ProductPriceChanged`, published on non-price catalog edits (name, description, attributes, category, status) made via the new `PUT`/`PATCH` endpoint above. Drives the same Redis cache-invalidation path BRD §16 already names it for. Auto-consumed by Analytics per ADR-0004's full fan-in default; whether any other service (e.g. Search, for non-price index refresh) should also consume it is not BRD-stated and is carried to the Event Design Agent (non-blocking) — this row only settles that the event itself is real and what triggers it. |
| `ProductDiscontinued` | Published (proposed, not BRD-stated) | Fired when a variant's `status` is set to discontinued via `PATCH /products/{id}`. Proposed the same way Offer's `CouponRedemptionVoided`/`PromotionDeactivated` were proposed (ADR-0008 precedent) — not final until the DDD Agent stage formalizes it. Unblocks `kart-wishlist-service`'s and `kart-search-service`'s own open questions on this exact gap (see `edge-cases.md`). |
| `ReviewSubmitted` | Consumed | Published by Review, "for rating recalc" (BRD §10). **Resolved (formerly Open Questions #2)** — Product does consume this event; §5.4's "—" was the incomplete condensed reading. Formally settled by ADR-0014 (`docs/adr/0014-review-rating-aggregate-ownership.md`): Review owns the canonical rating aggregate, Product's consumption produces a denormalized read-model copy only. |

Final contract is the API Design Agent's job, not this spec's.

## 6. Open Questions / Flagged Ambiguities

All items originally carried as blocking are now resolved. None remain open in a way that blocks sign-off; the items below are either resolved-and-cited, or explicitly non-blocking handoffs to a later pipeline stage.

**Resolved:**

1. **`ProductPriceChanged` publisher contradiction — RESOLVED.** BRD §10's Event Catalog row lists Publisher as "Pricing," which contradicts §5.4's condensed service table (Product's Publishes column lists `ProductPriceChanged`; Pricing's row lists it under Consumes). kart-offer-service's requirement-spec.md already resolved this (its Open Questions #1), later codified platform-wide by **ADR-0008** (`0008-event-catalog-completeness-round-2.md`), which corrected BRD §10's Publisher column itself. Product publishes it, Pricing only consumes it to react to catalog price moves when computing quotes. Not re-opened.
2. **Product's consumer surface contradiction ("—" vs. `ReviewSubmitted`) — RESOLVED, cross-cutting, closed by ADR.** BRD §5.4's condensed table lists Product's Consumes column as "—," but §10's Event Catalog lists Product as a consumer of `ReviewSubmitted` "for rating recalc." Formally settled by ADR-0014 (`docs/adr/0014-review-rating-aggregate-ownership.md`): §10 governs over §5.4's incomplete condensed summary (the same precedent ADR-0007/0008 already established for other consumer-scope gaps); Product does consume `ReviewSubmitted`; Review Service owns the canonical rating aggregate (BRD §2.1 item 14), Product's copy is a denormalized projection only. See §2 (Ratings integration), §4 (Domain Invariants), and §5 (API Surface) above.
3. **Variant/attribute schema unspecified — RESOLVED, single-service engineering default, no ADR needed.** BRD §2.1 names "variants, attributes" as core scope but gave zero data-model detail. Decided: a hybrid EAV/JSONB schema — variant rows are the priced/sellable SKU unit with first-class indexed columns for `size`/`color` plus a schemaless `attributes JSONB` column for everything else. See "Variant & Attribute Data Model" in §2 above for the full decision, rationale, and trade-off. The DDD Agent still owns the aggregate-boundary question (Variant as child entity vs. separate aggregate) — that is its job, not this spec's, and is not a blocking gap left behind here.
4. **Catalog write API missing from the BRD — RESOLVED, single-service engineering default, no ADR needed.** Only `GET /products/{id}` was named (§5.4). Decided: Product exposes its own `POST /products` and `PUT`/`PATCH /products/{id}` write API (§5) as the system-of-record write path, called by both Admin's `/admin/*` surface and the Partner API (BRD §24.1's "catalog management" / "bulk catalog upload" grants), never bypassed by either. See §2 and §5 above.
5. **Catalog versioning / price history — RESOLVED, single-service engineering default, no ADR needed.** The one concrete downstream need the BRD names (Wishlist's old-vs-new price comparison) is already satisfied by `ProductPriceChanged`'s own `oldPrice`/`newPrice` payload fields (BRD §10) — no separate Product-side history table is required for that. Whether a dedicated audit/rollback table beyond the replayable event stream is *also* warranted at 100M-SKU scale has no further BRD grounding to decide now; that narrower question is a legitimate, non-blocking carry-forward to the DDD/Architecture Agent stage (see §4, Domain Invariants).
6. **`ProductUpdated` event undefined — RESOLVED, single-service engineering default, no ADR needed.** BRD §16 named it in cache-invalidation prose only. Decided: it is a real, distinct event (not a prose slip for one of the other two), published on non-price catalog edits via the new write API, driving the same cache-invalidation path BRD §16 describes. See §5 (API Surface) above. Whether services beyond Analytics (auto-consumer per ADR-0004) should also consume it is a narrower, legitimately non-blocking question carried to the Event Design Agent.

**Carried forward (non-blocking — legitimate handoffs to a later pipeline stage, not gaps):**

7. **Rating-projection consistency bound.** Now that Q2 is resolved (Product does consume `ReviewSubmitted`, per ADR-0014 (`docs/adr/0014-review-rating-aggregate-ownership.md`)), the BRD still states no staleness SLA for how quickly `product_read_model.ratingSummary` must reflect a new review. This is a numeric target, not a scope question — Architecture Agent's job, alongside the general CQRS eventual-consistency window (BRD §7).
8. **Product edit audit/rollback depth beyond the replayable event stream** (narrowed from former Q5). Whether a dedicated history table is warranted at 100M-SKU scale, and its retention policy, is a data-lifecycle decision for the DDD/Architecture Agent stage — the one concrete requirement the BRD implies (Wishlist's price comparison) is already satisfied without it (see Q5 above).
9. **Full multi-service consumer wiring for `ProductUpdated`** (narrowed from former Q6). The event's existence and trigger are now decided (Q6 above); whether Search or other read-side consumers should also subscribe to it (vs. relying only on `ProductCreated`/`ProductPriceChanged`) is an Event Design Agent-level wiring decision, not a scope ambiguity.

## Sign-off

- [x] Blocking open questions resolved (Q2, Q3, Q4)
- [x] Reviewed by: Automated architecture pipeline — see docs/adr and this run's decision log
- [x] Approved to proceed to Architecture Agent
