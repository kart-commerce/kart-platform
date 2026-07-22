---
doc_type: tickets
service: kart-product-service
status: approved
generated_by: ticket-agent
source: [architecture.md, ddd-model.md, api-contract.yaml, database-design.md, event-contract.md, design-decisions.md, requirement-spec.md, edge-cases.md]
---

# Tickets: kart-product-service

Local draft. Not yet created as real GitHub Issues — that requires the target repo to exist (Project Scaffold Agent) and is a separate, explicit step.

## Epic: kart-product-service v1

Catalog system-of-record (BRD §2.1 item 3) modeled as two aggregates (`ddd-model.md`): `Product` (the parent/grouping record — name, description, category, brand) and `Variant` (the actual sellable, priced, SKU-identified unit). PostgreSQL is the strongly-consistent write side; `product_read_model` (MongoDB, sharded by `category.id`) is the eventually-consistent, denormalized read side, keyed one document per SKU (not nested under a parent document — `ddd-model.md`'s read-model-keying resolution). The platform's highest-fan-out catalog publisher: `ProductCreated`/`ProductPriceChanged`/`ProductUpdated`/`ProductDiscontinued` reach up to four independent consumer groups each, every one isolated behind its own bulkhead queue/DLQ (`design-decisions.md`).

| ID | Task | Vertical Slice (Application/Features/) | Depends On | Design Source |
|---|---|---|---|---|
| PRD-1 | Create a product group and its initial variant | `CreateProductGroup` | — | `api-contract.yaml` `POST /v1/product-groups`; `ddd-model.md` Cross-Aggregate Interaction flow 1 (`Product` save → initial `Variant` save → `Published` flip); `database-design.md` `product_groups`, `variants`, `product_outbox_events`; `event-contract.md` `ProductCreated` (published, `product.product.created`, per-consumer-group DLQs) |
| PRD-2 | Add a variant to an existing product group | `AddVariant` | PRD-1 | `api-contract.yaml` `POST /v1/product-groups/{productGroupId}/variants`; `ddd-model.md` Cross-Aggregate Interaction flow 2; `database-design.md` `variants` (SKU-uniqueness constraint), `idx_variants_product_group_id`; `event-contract.md` `ProductCreated` |
| PRD-3 | Get product detail by SKU | `GetProduct` | PRD-1 | `api-contract.yaml` `GET /v1/products/{sku}` (`ProductResponse`); `ddd-model.md` read-model-keying resolution (SKU-keyed, no nested variants array); `database-design.md` `product_read_model` point-read by `_id` |
| PRD-4 | Update a variant's price, status, or attributes | `UpdateVariant` | PRD-1 | `api-contract.yaml` `PATCH /v1/products/{sku}` (mutually exclusive price/status/attributes outcomes, `409` on mixed request); `ddd-model.md` `Variant` invariants (one-directional `Discontinued`, single-aggregate write); `database-design.md` `variants`, field-scoped `product_read_model` projector; `event-contract.md` `ProductPriceChanged` (with `occurredAt`), `ProductDiscontinued`, `ProductUpdated` — exactly one per call; edge-cases.md "Out-of-order `ProductPriceChanged` delivery," "SKU uniqueness enforcement" |
| PRD-5 | Update product-group fields, or archive the group | `UpdateProductGroup` | PRD-1, PRD-4 | `api-contract.yaml` `PATCH /v1/product-groups/{productGroupId}` (field edit vs. `status: Archived`); `ddd-model.md` Cross-Aggregate Interaction flow 3 (per-SKU fan-out, sequenced, never atomic across siblings) and Modeling Decision 5 (archive cascades to children); `event-contract.md` `ProductUpdated` (parent-field edit, fanned out per sibling SKU), `ProductDiscontinued` (archive cascade, fanned out per sibling SKU) |
| PRD-6 | Apply a rating-summary projection from Review's events | `ApplyRatingProjection` | PRD-1 | `event-contract.md` `ReviewSubmitted`/`ReviewUpdated` (consumed, `product.review-submitted.dlq`/`product.review-updated.dlq`); `ddd-model.md` Read-Model Projection section (ADR-0014 — denormalized copy, never canonical); `database-design.md` field-scoped `ratingSummary` partial update, disjoint from every catalog projector's own field set (edge-cases.md "Concurrent read-model writes clobber the denormalized document") |

## Notes for Sprint Planner Agent

- PRD-1 has no dependencies — the foundation every other ticket needs (`product_groups`/`variants` schema, the Outbox, and the first confirmed SKU to read/update/project against).
- PRD-2 and PRD-3 both only need PRD-1's schema to exist; they are independent of each other and of PRD-4/5/6 — all three (PRD-2, PRD-3, and the start of PRD-4/5/6's implementation) can proceed in parallel once PRD-1 lands.
- PRD-4 depends only on PRD-1 (a `Variant` row must be creatable) — it does not depend on PRD-2, since PRD-1 alone already produces one variant to update.
- PRD-5 depends on PRD-1 (the product group must exist) and PRD-4 (the archive-cascade path reuses PRD-4's own per-SKU discontinue-and-publish logic rather than duplicating it) — sequence it after both.
- PRD-6 depends only on PRD-1 (a `product_read_model` document must exist for the projector to update) — independent of PRD-2 through PRD-5, can run in parallel with all of them.
- No circular dependencies in this graph; longest chain is PRD-1 → PRD-4 → PRD-5, 3 deep.
- PRD-4's three mutually-exclusive event outcomes (price/status/attributes) are implemented as one ticket, not three, because they share the same single-`Variant`-aggregate write path and the same `409`-on-mixed-request validation rule — splitting them would split one cohesive use case across tickets, which this platform's ticket-sizing rule avoids.
