---
doc_type: adr
status: accepted
---

# ADR-0018: Search's Catalog/Rating/Category Signal Sourcing — `ProductCreated`/`ProductUpdated` Payload Growth, Plus Search Confirmed as a `CategoryUpdated`/`ReviewSubmitted`/`ReviewUpdated` Consumer

## Status

Accepted

## Context

Running `kart-search-service` through the Architecture/DDD/API/Database/Event Design stages surfaced three structural gaps between what `kart-search-service/requirement-spec.md` (already approved) scoped Search to consume and what BRD §17's actual functional requirements (multi-match search on name/description/brand; facets on category/price/rating; ranking blended from rating/in-stock/sponsored signals) need Search's index to contain. None of the three gaps is fixable inside `kart-search-service`'s own docs alone — each requires either growing an already-published event's payload or confirming Search as a new consumer of an event another service already owns, exactly the "affects another service's required contract" bar that already justified ADR-0006, ADR-0010, ADR-0013, and ADR-0014.

**Gap 1 — `ProductCreated`'s payload cannot build an initial search document.** `kart-product-service/event-contract.md`'s currently-approved payload for `ProductCreated` is `sku, attributes` only (BRD §10, unchanged since the BRD's original two-field spec). It carries no `name`, `description`, `category`, `brand`, `price`, or `status` — every field BRD §17's multi-match/facet/ranking requirements actually need. `kart-search-service/requirement-spec.md`'s own Domain Invariant §4 forbids working around this with a synchronous enrichment call to `GET /v1/products/{sku}`, because that endpoint reads from `product_read_model` (MongoDB) — exactly the dependency the invariant names ("the search index must never depend on the MongoDB product read model being present or current... a stale or down MongoDB read model must not block search indexing"). A per-event synchronous call to Product's PostgreSQL write side instead would fare no better against the invariant's actual intent (an indexing pipeline whose progress blocks on Product's live availability, not just its event stream) — `kart-search-service/architecture.md`'s own already-approved reasoning for keeping the bulk-catalog-snapshot export batch-only, off the request-serving path, applies with equal force here. The only mechanism consistent with "fed independently from the same event pipeline" is for the event itself to carry what Search needs.

**Gap 2 — `ProductUpdated`'s payload cannot propagate a value, only a field name.** `kart-product-service/ddd-model.md` deliberately kept `ProductUpdated`'s payload to `sku, changedFields, occurredAt` — field *names* that changed, not their new values — reasoning that "a consumer needing the current value already has `GET /v1/products/{sku}` available." That reasoning held when Analytics (a change-frequency counter, indifferent to the actual new value) was the only consumer. It does not hold for Search, which needs the actual new value of `name`/`description`/`category`/`brand`/`attributes` to keep its index inside the already-approved P95<5s/P99<15s freshness bound (`kart-search-service/requirement-spec.md` §3) — and, per Gap 1's reasoning, cannot fetch it via `GET /v1/products/{sku}` either.

**Gap 3 — no event carries rating or category-name data to Search at all.** BRD §17 names rating as a ranking signal and category as a facet dimension, but:
- Rating is exclusively owned by `kart-review-service` (ADR-0014: "Review is the sole canonical system-of-record for the rating aggregate"). `ReviewSubmitted`/`ReviewUpdated` are consumed today only by Product (for its own denormalized `ratingSummary` projection) and Analytics (`kart-review-service/requirement-spec.md` §5, `architecture.md` Dependencies table) — Search is not a confirmed consumer of either, and no other event carries rating data to Search.
- Category name is owned by `kart-category-service` (ADR-0011). `kart-product-service`'s own write-side (`product_groups.category_id`) stores only the category *id*, never a name column — so even Gap 1/2's payload growth on Product's events can supply `categoryId` but not a reliably-sourced `categoryName`. `kart-category-service/event-contract.md` already anticipated exactly this: "If Product or Search later confirm themselves as consumers [of `CategoryUpdated`]... that consumer's own retry/DLQ tier is that service's call to make" — the door was left open by design, not closed.

All three gaps share the same shape ADR-0013 already resolved for Recommendation/`ProductCreated`: a downstream service's genuine structural need for an upstream event it isn't yet a confirmed consumer of (or whose payload is too thin), resolved by adding the consumption/payload rather than inventing a workaround that violates an already-approved invariant.

## Decision

**1. `ProductCreated`'s payload grows (additive, non-breaking per `event-standards.md`'s versioning rule — the same bar already applied to this event's sibling `ProductPriceChanged`'s `occurredAt` addition and to `ProductDiscontinued`'s formalization) to:**

```
sku, name, description, categoryId, brand, price { amount, currency }, status, attributes { size, color, extendedAttributes }
```

This is the full initial snapshot of a `Variant` plus its parent `Product`'s shared fields at creation time (`kart-product-service/ddd-model.md`'s own field list) — everything a consumer needs to materialize a complete initial projection without a second call anywhere. `categoryName` is deliberately **not** added here (see Decision 3 — Category is the correct source for that field, not Product, since Product's own write side never stores it).

**2. `ProductUpdated`'s payload grows the same way, to:**

```
sku, changedFields, occurredAt, name, description, categoryId, brand, status, attributes { size, color, extendedAttributes }
```

Always carries the current full value of every field named above, regardless of which specific one(s) `changedFields` names as having changed — simpler for any full-projection consumer (Search) than a value keyed only to the changed subset, and harmless for Analytics (the existing consumer), which continues to read only `changedFields`/`occurredAt` and ignores the rest, exactly as unknown-field-tolerant consumption already requires (`kart-conventions.md`'s API-versioning section states this invariant for REST responses; the same tolerance is assumed of every event consumer platform-wide). `price` is deliberately excluded from `ProductUpdated` — price transitions remain exclusively `ProductPriceChanged`'s job, unchanged.

**3. `kart-search-service` is confirmed as a consumer of `CategoryUpdated`** (`kart-category-service/event-contract.md`, payload `categoryId, name, parentId, path, operation, occurredAt`, unchanged), maintaining its own `categoryId → categoryName` lookup independently of Product — sourced from category's own owning context (ADR-0011), not copied secondhand through a field Product's write side doesn't actually have.

**4. `kart-search-service` is confirmed as a third consumer of `ReviewSubmitted`/`ReviewUpdated`** (`kart-review-service`, payloads unchanged: `orderId, sku, rating, reviewId, userId` / `orderId, sku, oldRating, newRating`), maintaining its own `ratingSummary`-equivalent projection for the ranking signal — the identical pattern `kart-product-service` already uses for its own `ratingSummary` (ADR-0014: "two projections of one event stream, not a client-server relationship"), applied a second time for the identical need. Review remains the sole canonical rating owner; this adds a third independent denormalized reader, not a second write authority.

**Each service's own retry/DLQ tier for its newly-added consumer queue is that service's own call, not re-decided here** (the same boundary ADR-0013's Consequences section already drew): `kart-product-service`'s publish-side tier for `ProductCreated`/`ProductUpdated` is unchanged (3x, per-consumer DLQ, `kart-product-service/event-contract.md`); `kart-search-service`'s own consumer-side DLQs (`search.product-created.dlq`, `search.product-updated.dlq`, `search.category-updated.dlq`, `search.review-submitted.dlq`, `search.review-updated.dlq`) are fixed in `kart-search-service/event-contract.md`.

## Consequences

- `kart-product-service/event-contract.md` and `ddd-model.md` are updated to reflect the grown `ProductCreated`/`ProductUpdated` payloads. Both remain `status: approved` — this is an additive, backward-compatible payload change (no field removed, renamed, or retyped; `kart-conventions.md`'s breaking-change definition is not triggered), the same weight already given to the `occurredAt`/`ProductDiscontinued` additions in that same document, not a re-review-from-scratch event.
- `kart-analytics-service/event-contract.md` and `kart-recommendation-service/requirement-spec.md`/`architecture.md` cite `ProductCreated`'s payload literally as `sku, attributes` in prose; those citations are corrected to the grown shape for accuracy. Neither service's own decisions, consumption logic, or retry tier change — both already ignore fields they don't need, and neither reads a field this growth removes or renames.
- `kart-review-service/requirement-spec.md` and `architecture.md` add `kart-search-service` to `ReviewSubmitted`/`ReviewUpdated`'s named consumer list, alongside Product and Analytics. No change to Review's own publish-side tier, moderation workflow, or ADR-0014's ownership resolution.
- `kart-category-service`'s own docs need **no edit** — `event-contract.md`'s existing "if Product or Search later confirm themselves as consumers" language already anticipated this outcome without foreclosing it; this ADR is the confirmation that language was waiting for.
- `kart-search-service`'s own design package (`architecture.md`, `ddd-model.md`, `database-design.md`, `event-contract.md`) is written directly against the resolved payload/consumer shapes above — no placeholder or "pending Event Design Agent" language remains for any of the three gaps this ADR closes.
- Accepted risk: `kart-search-service` now independently maintains two denormalized copies it does not own the canonical source of (`categoryName` via `CategoryUpdated`, `ratingSummary`-equivalent via `ReviewSubmitted`/`ReviewUpdated`) — the same eventually-consistent-projection risk profile `kart-product-service` already accepts for its own identical copies, bounded by the same platform-standard retry/DLQ machinery, not a new risk class.
