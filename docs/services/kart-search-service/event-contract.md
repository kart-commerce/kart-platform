---
doc_type: event-contract
service: kart-search-service
status: approved
generated_by: event-design-agent
source: docs/services/kart-search-service/ddd-model.md, docs/services/kart-search-service/design-decisions.md, docs/services/kart-search-service/architecture.md, docs/services/kart-search-service/database-design.md, docs/services/kart-search-service/edge-cases.md, docs/adr/0018-search-catalog-signal-sourcing.md, docs/services/kart-product-service/event-contract.md, docs/services/kart-category-service/event-contract.md, docs/services/kart-review-service/architecture.md
---

# Event Contract: kart-search-service

Exchange: `ecommerce.events` (RabbitMQ topic exchange, per [kart-conventions.md](../../standards/kart-conventions.md)). Routing key convention: `service.entity.action`. Every consumer queue gets its own DLQ per the reusable event standard (`event-standards.md`) — **never shared**, matching the per-consumer-group DLQ correction every publisher this service consumes from has already made for its own event contract.

## Published Events

**None.** Search is a pure consumer/query context (requirement-spec §1/§5; BRD §5.4 lists no outbound events for this service; confirmed unchanged through `ddd-model.md`, which publishes no domain event from either of its two aggregates).

## Consumed Events

| Event | Routing Key | Publisher | Payload (key fields) | Retry (this service's own consumer queue) | DLQ (this service's own consumer queue) | Notes |
|---|---|---|---|---|---|---|
| `ProductCreated` | `product.product.created` | `kart-product-service` | `sku, name, description, categoryId, brand, price, status, attributes` (enriched by [ADR-0018](../../adr/0018-search-catalog-signal-sourcing.md); originally `sku, attributes`) | 3x | `search.product-created.dlq` | Aggregate-creation trigger for `SearchDocument` (`ddd-model.md`). Matches `kart-product-service/event-contract.md`'s own publish-side tier for this consumer group exactly. |
| `ProductPriceChanged` | `product.price.changed` | `kart-product-service` | `sku, oldPrice, newPrice, occurredAt` (unchanged) | 3x | `search.product-price-changed.dlq` | Applied via `lastCatalogEventAt`'s version/timestamp guard (`ddd-model.md`) — rejects a redelivery older than the document's stored value. |
| `ProductUpdated` | `product.product.updated` | `kart-product-service` | `sku, changedFields, occurredAt, name, description, categoryId, brand, status, attributes` (enriched by [ADR-0018](../../adr/0018-search-catalog-signal-sourcing.md); originally `sku, changedFields, occurredAt`) | 3x | `search.product-updated.dlq` | **New consumption**, not in requirement-spec.md's original scope — added at the Architecture stage (`architecture.md`) once the enriched payload made it usable without a forbidden Mongo-read-model callback. Same `lastCatalogEventAt` guard as `ProductPriceChanged`. |
| `ProductDiscontinued` | `product.product.discontinued` | `kart-product-service` | `sku, discontinuedAt` (unchanged; formalized platform-wide at `kart-product-service`'s own DDD/Event Design stage) | 3x | `search.product-discontinued.dlq` | Soft-remove trigger (`availability: Discontinued`, edge-cases.md) via the same guarded write path as the other catalog events — no second removal code path. |
| `CategoryUpdated` | `category.category.updated` | `kart-category-service` | `categoryId, name, parentId, path, operation, occurredAt` (unchanged) | 3x | `search.category-updated.dlq` | **New consumption**, added by [ADR-0018](../../adr/0018-search-catalog-signal-sourcing.md). Writes only `CategoryLookup` (`ddd-model.md`) — never fans out to every `SearchDocument` referencing the category; `parentId`/`path` are received but not consumed further by this service (Search only needs the leaf `categoryId → name` mapping, not subtree-move semantics — a narrower need than Category's own payload was grown for, per that service's own event-contract.md). |
| `ReviewSubmitted` | `review.review.submitted` | `kart-review-service` | `orderId, sku, rating, reviewId, userId` (unchanged) | 2x | `search.review-submitted.dlq` | **New consumption**, added by [ADR-0018](../../adr/0018-search-catalog-signal-sourcing.md). Matches `kart-review-service`'s own publish-side tier for this event exactly (2x, per that service's `architecture.md`). Drives `search_rating_ledger` + the recomputed `SearchDocument.rating` field only (`database-design.md`) — never any other field. |
| `ReviewUpdated` | `review.review.updated` | `kart-review-service` | `orderId, sku, oldRating, newRating` (unchanged) | 2x | `search.review-updated.dlq` | **New consumption**, added by [ADR-0018](../../adr/0018-search-catalog-signal-sourcing.md). Retry tier is **provisional** — inherited from `kart-review-service/architecture.md`'s own placeholder for this event's publish-side tier ("not a final answer," pending that service's own Event Design Agent confirmation); this service's consumer-side tier mirrors it rather than inventing an independent number, and will be revisited if/when Review's own tier changes. |

## Retry-Tier Justification

- **Catalog events (`ProductCreated`/`ProductPriceChanged`/`ProductUpdated`/`ProductDiscontinued`), 3x, no paging:** matches every other confirmed consumer of these events platform-wide (`kart-product-service/event-contract.md`'s own table). A permanently-lost delivery to this service's queue leaves one SKU's search document stale or (for `ProductCreated`) never indexed — a degraded search-result freshness/completeness outcome, never a correctness gap Product's own PostgreSQL write side can't recover from on the next successful delivery or the next full rebuild (`architecture.md`'s blue-green reindex). No money-moving or oversell risk, so the `Payment*` 5x/paged tier does not apply.
- **`CategoryUpdated`, 3x, no paging:** matches Category's own stated tier for this event exactly (`kart-category-service/event-contract.md`) — a lost delivery leaves `CategoryLookup` stale for one category id, degrading a facet's display label only, never blocking indexing or querying (`ddd-model.md`'s Cross-Aggregate Interaction: a missing/stale `categoryName` is a `null`/stale display value, not a missing document).
- **`ReviewSubmitted`/`ReviewUpdated`, 2x, no paging:** matches Review's own stated tier for both events (`kart-review-service/architecture.md`) — a lost delivery leaves this service's own `RatingSignal` projection missing one review's contribution, a strictly cosmetic ranking-signal staleness (Review's own PostgreSQL/read-model remains the canonical, unaffected source of truth, ADR-0014). Lower than the catalog tier because Review's own publish-side tier is itself lower (2x vs. 3x) — this service's consumer-side tier is not independently re-derived against a different risk profile than Review's own publish side already assumed, the same "match the publisher's own stated tier for a low-stakes read-side copy" reasoning `kart-product-service/event-contract.md` applies to its identical consumption of the same two events.

## Bulk Catalog-Snapshot Export (Rebuild-Only — Not an Event, Documented Here for Completeness)

`architecture.md`'s "Index Rebuild Backfill Source" names a batch, paginated pull from `kart-product-service`'s PostgreSQL write side, used only during an operator-triggered or scheduled full reindex. This is a synchronous batch REST/internal call, not a RabbitMQ event — it belongs conceptually beside this contract (as the non-event half of Search's inbound data sourcing) but has no routing key, retry ladder, or DLQ of its own; retry-on-failure for this path is an ordinary batch-job retry, not RabbitMQ's TTL-ladder mechanism, and a failed rebuild attempt does not degrade the currently-live index/alias (edge-cases.md's "Index Rebuild During High Write Volume").

## Naming-Convention Compliance

All seven consumed events follow the `<Entity><PastTenseVerb>` convention (`event-standards.md`), unchanged from their respective publishers' own contracts — this service introduces no new event names of its own (it publishes none). Routing keys follow `service.entity.action` (`kart-conventions.md`), using each publisher's own domain word (`product`, `category`, `review`) exactly as already registered in `kart-product-service/event-contract.md`, `kart-category-service/event-contract.md`, and `kart-review-service/architecture.md` respectively — matched here, not re-decided. No collision risk: this service defines zero event names of its own to collide with anything.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner
- [x] Approved
