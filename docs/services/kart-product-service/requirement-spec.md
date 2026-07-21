---
doc_type: requirement-spec
service: kart-product-service
status: pending-approval
generated_by: requirement-agent
source: docs/requirements/kart-requirements.md
---

# Requirement Spec: kart-product-service

## 1. Scope

Covers one BRD service: **Product** (BRD §2.1 item 3, "Product catalog, variants, attributes"). No merge, no ADR — this is a single bounded context on its own.

Product is the catalog system-of-record: it owns product identity, variants, attributes, and the base/list price. It is also one of the platform's highest-fan-out event publishers — Search, Recommendation, Wishlist, and Pricing all react to its events (BRD §10).

## 2. Functional Requirements

### Catalog

- Serve product detail reads (`GET /products/{id}`, BRD §5.4), backed by a denormalized MongoDB read model (BRD §5.4, §6.2).
- Own product creation, publishing `ProductCreated` (sku, attributes) on success (BRD §10). BRD does not list a corresponding inbound write endpoint (e.g. `POST /products`) — see Open Questions.
- Own product base/list price as the system-of-record, publishing `ProductPriceChanged` (sku, oldPrice, newPrice) on change (BRD §10, resolved reading — see Open Questions #1).
- Support variants and attributes as a first-class part of the catalog model (BRD §2.1 item 3 names this explicitly as core scope), though the BRD gives no schema detail for either — see Open Questions.

### Read-model / caching integration

- Serve product detail reads from Redis cache-aside in front of the MongoDB read model, populated on miss with a TTL (BRD §16).
- Invalidate the Redis cache explicitly on price-change events rather than relying on TTL alone, so stale prices are not served after a `ProductPriceChanged` (BRD §16).
- Denormalize category name, price, and rating summary directly into the `product_read_model` MongoDB document to avoid cross-shard joins on the read path (BRD §6.2).
- Shard the MongoDB read model (and Search's collection) by `category.id` for browse-query locality (BRD §6.2).

### Ratings integration

- Recalculate a product's rating summary in response to `ReviewSubmitted` (BRD §10 Event Catalog lists Product as a consumer "for rating recalc"). This conflicts with BRD §5.4's condensed service table, which lists Product's Consumes column as "—" — see Open Questions #2.

### Fan-out awareness

- `ProductCreated` is consumed by Search and Recommendation (BRD §10).
- `ProductPriceChanged` is consumed by Search, Wishlist, and Pricing (BRD §10, §5.4 — Pricing's row lists `ProductPriceChanged` under Consumes).

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
- A product's rating summary must eventually reflect all `ReviewSubmitted` events for that SKU (inferred from BRD §10's "Product (rating recalc)" consumer note and the `ratingSummary` field embedded in the read model at §6.2; the BRD does not state a staleness bound for this).
- The MongoDB read model must always be rebuildable from the PostgreSQL write side plus replayed events — the general CQRS safety property the BRD states for the platform (§7), applied here since Product is named as one of the CQRS-split services (§6.1).
- Every SKU is presumed unique across the catalog (inferred from "Product catalog" framing and the `_id: "sku-..."` read-model example at §6.2; the BRD does not state a uniqueness constraint or how it is enforced for a 100M-SKU catalog — see Open Questions).

## 5. API Surface (from BRD, starting point only)

| Endpoint/Event | Direction | Notes |
|---|---|---|
| `GET /products/{id}` | Inbound API | BRD §5.4 — the only endpoint the BRD names for this service |
| `ProductCreated` | Published | Consumed by Search, Recommendation (BRD §10) |
| `ProductPriceChanged` | Published | Consumed by Search, Wishlist, Pricing (BRD §10, §5.4) — publisher resolved to Product, see Open Questions #1 |
| `ReviewSubmitted` | Consumed | Published by Review, "for rating recalc" (BRD §10) — contradicts §5.4's Consumes column, see Open Questions #2 |
| `ProductUpdated` | Referenced only | Named in BRD §16's cache-invalidation prose but absent from the Event Catalog (§10) and API table (§5.4) — see Open Questions #6 |

Final contract is the API Design Agent's job, not this spec's.

## 6. Open Questions / Flagged Ambiguities

**Resolved (non-blocking — inherited from a prior spec in this pipeline):**

1. **`ProductPriceChanged` publisher contradiction — RESOLVED.** BRD §10's Event Catalog row lists Publisher as "Pricing," which contradicts §5.4's condensed service table (Product's Publishes column lists `ProductPriceChanged`; Pricing's row lists it under Consumes). kart-offer-service's requirement-spec.md already resolved this (its Open Questions #1): Product publishes it, Pricing only consumes it to react to catalog price moves when computing quotes. Treated as settled fact here; not re-opened.

**Carried forward (blocking — need a human answer before variant/attribute modeling can proceed):**

2. **Product's consumer surface is contradictory.** BRD §5.4's condensed table lists Product's Consumes column as "—" (nothing), but §10's Event Catalog lists Product as a consumer of `ReviewSubmitted` "for rating recalc." Both readings can't be true. If Product does consume `ReviewSubmitted`, its API/Event surface and read-model rebuild logic must account for it; if it doesn't, the rating summary in the read model (§6.2 example) must be populated some other way (e.g. Review Service pushes directly, or Search denormalizes it). Escalating rather than picking one.
3. **Variant/attribute schema is entirely unspecified.** BRD §2.1 names "variants, attributes" as core scope but gives zero data-model detail: is a variant a distinct SKU row with a parent-product linkage, an embedded sub-document, or a separate aggregate? Are attributes fixed columns, EAV, or free-form JSON? This materially affects the DDD Agent's aggregate design and is not a detail that can be deferred silently — flagging as a blocking gap.
4. **Catalog write API is missing from the BRD.** Only `GET /products/{id}` is named (§5.4). There is no stated endpoint for creating/updating a product (despite `ProductCreated` firing from somewhere) or for triggering `ProductPriceChanged`. Whether product mutation goes through Product's own API, through Admin Service's `/admin/*` (§5.4), or both, is unstated.

**Carried forward (non-blocking — resolved by a later pipeline stage, not here):**

5. **Catalog versioning / price history** — BRD does not state whether product edits (especially price changes) are versioned or retained for audit, despite Wishlist depending on old-vs-new price comparison (`WishlistPriceAlertTriggered`, §5.4) and a 100M-SKU catalog implying real audit/rollback needs. Carried to the DDD/Architecture Agent stages.
6. **`ProductUpdated` event — undefined.** BRD §16's caching section names a `ProductUpdated` event for cache invalidation, but it does not appear in the Event Catalog (§10) or API Surface (§5.4). Unclear whether this is a third real event alongside `ProductCreated`/`ProductPriceChanged` that the BRD forgot to catalog, or a prose slip meaning one of the two existing events. Carried to the Event Design Agent stage.
7. **Rating-recalc consistency bound** — if Product does consume `ReviewSubmitted` (pending Q2), the BRD states no staleness SLA for how quickly the read-model `ratingSummary` must reflect it. Carried to the Architecture Agent stage alongside the general CQRS eventual-consistency window (BRD §7).

## Sign-off

- [ ] Blocking open questions resolved (Q2, Q3, Q4)
- [ ] Reviewed by:
- [ ] Approved to proceed to Architecture Agent
