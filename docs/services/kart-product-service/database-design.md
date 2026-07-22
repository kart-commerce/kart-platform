---
doc_type: database-design
service: kart-product-service
status: approved
generated_by: database-design-agent
source: docs/services/kart-product-service/ddd-model.md, docs/services/kart-product-service/architecture.md, docs/services/kart-product-service/design-decisions.md, docs/services/kart-product-service/requirement-spec.md, docs/services/kart-product-service/edge-cases.md, docs/services/kart-product-service/api-contract.yaml
---

# Database Design: kart-product-service

Two PostgreSQL tables (`product_groups`, `variants`), matching ddd-model.md's two-aggregate split exactly — no cross-table transaction is ever taken (ddd-model.md's Cross-Aggregate Interaction: creation, parent edits, and archival are sequenced saves, never one ACID write spanning both). One MongoDB collection (`product_read_model`), keyed by `sku` per ddd-model.md's read-model-keying resolution — not by `product_group_id` — matching the BRD's own §6.2 worked example and every downstream consumer's SKU-level access pattern.

## PostgreSQL (Write Side)

```sql
-- ── product_groups ──────────────────────────────────────────────────────
-- Backs the Product aggregate (ddd-model.md). One row per parent/grouping
-- record; never itself priced or orderable.
CREATE TABLE product_groups (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name         TEXT NOT NULL,
    description  TEXT,
    category_id  TEXT NOT NULL,          -- caller-supplied reference to kart-category-service; never validated live (architecture.md)
    brand        TEXT,
    status       TEXT NOT NULL CHECK (status IN ('Draft', 'Published', 'Archived')) DEFAULT 'Draft',
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Supports the polling-free "is this group's category ever queried on its
-- own" path — not a hot path, but a small B-tree costs nothing at this
-- table's size (bounded by distinct product-group count, not SKU count).
CREATE INDEX idx_product_groups_category_id ON product_groups (category_id);

-- ── variants ────────────────────────────────────────────────────────────
-- Backs the Variant aggregate (ddd-model.md) — the actual sellable, priced
-- unit. One row per SKU. This is the platform's single-highest-row-count
-- write-side table (100M SKUs, BRD §4.1) — every column here is on the
-- write path a price/status/attribute PATCH touches.
CREATE TABLE variants (
    sku                 TEXT PRIMARY KEY,   -- globally unique; edge-cases.md "SKU uniqueness enforcement" — enforced synchronously here, independent of the read model's category.id shard key
    product_group_id    UUID NOT NULL REFERENCES product_groups(id),
    price_amount        NUMERIC(12,2) NOT NULL,
    price_currency      TEXT NOT NULL,
    status              TEXT NOT NULL CHECK (status IN ('Active', 'Discontinued')) DEFAULT 'Active',
    size                TEXT,               -- first-class indexed attribute (requirement-spec §2 hybrid EAV/JSONB decision)
    color                TEXT,              -- first-class indexed attribute
    extended_attributes JSONB NOT NULL DEFAULT '{}',  -- schemaless bag for everything else (ddd-model.md ProductAttributes)
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Point-lookup/write index for the PATCH /v1/products/{sku} write path and
-- the SKU-uniqueness invariant — the primary key already gives this, listed
-- here only for the indexing-rationale table below to reference by name.

-- Supports "list every sibling variant under this product group" — the
-- product-page variant-picker UI query (ddd-model.md's read-model-keying
-- resolution note) and the archive-cascade write (ddd-model.md
-- Cross-Aggregate Interaction flow 3: "sequentially set every currently-
-- Active sibling Variant to Discontinued").
CREATE INDEX idx_variants_product_group_id ON variants (product_group_id);

-- Supports browse/facet queries filtering on size/color at 100M-SKU scale
-- (requirement-spec §2: "browse/facet queries need fast indexed equality/
-- range filtering on exactly these"). Partial — most variants have both set,
-- but a category without a size/color concept leaves them null; the partial
-- filter keeps the index from indexing rows where the filter is meaningless.
CREATE INDEX idx_variants_size ON variants (size) WHERE size IS NOT NULL;
CREATE INDEX idx_variants_color ON variants (color) WHERE color IS NOT NULL;

-- ── product_outbox_events ───────────────────────────────────────────────
-- The Outbox row every Variant/Product write inserts in the same PostgreSQL
-- transaction as its domain write (platform-standard Outbox pattern, BRD
-- §11) — guarantees `ProductCreated`/`ProductPriceChanged`/`ProductUpdated`/
-- `ProductDiscontinued` are never published without the write that caused
-- them having durably committed, and never lost if the write commits but
-- the immediate publish attempt fails.
CREATE TABLE product_outbox_events (
    id           BIGSERIAL PRIMARY KEY,
    event_type   TEXT NOT NULL,       -- ProductCreated | ProductPriceChanged | ProductUpdated | ProductDiscontinued
    sku          TEXT NOT NULL,       -- every published event is SKU-keyed (ddd-model.md)
    payload      JSONB NOT NULL,
    occurred_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    published_at TIMESTAMPTZ          -- null until the poller confirms RabbitMQ publish
);

CREATE INDEX idx_product_outbox_unpublished ON product_outbox_events (id) WHERE published_at IS NULL;
```

### Why `variants.sku` is the primary key, not a separate surrogate id

Every access path — the write-side uniqueness invariant (edge-cases.md), the `PATCH /v1/products/{sku}` write, and the read-model projector's own upsert key — is a point lookup by `sku` and nothing else. A separate `UUID` primary key plus a secondary unique index on `sku` would only add a second lookup hop with no benefit any query pattern here actually needs (contrast `product_groups`, which genuinely needs a server-generated id since it has no natural external identifier of its own — `POST /v1/product-groups` returns one precisely because nothing caller-supplied identifies a product group).

## MongoDB (Read Side) — `product_read_model`

```js
// One document per SKU — not one per product group with a nested variants
// array. Resolves ddd-model.md's read-model-keying decision: matches BRD
// §6.2's own worked example (`"_id": "sku-192837"`, flat, no parent id) and
// every downstream consumer's SKU-level access pattern (ProductCreated/
// ProductPriceChanged's sku-only payloads; Cart/Wishlist/Recommendation all
// operate per-SKU).
db.createCollection("product_read_model")
// {
//   _id: <sku>,                          // the Variant's own identity — point-read/write key for GET /v1/products/{sku}
//   productGroupId: <uuid>,              // reference only, supports the "list sibling variants" secondary query below — never used to key this document
//   name: <string>,                      // denormalized from product_groups (ddd-model.md) — avoids a join on every catalog read (BRD §6.2's stated rationale)
//   description: <string>,
//   category: { id: <string>, name: <string> },  // denormalized (BRD §6.2 example) — staleness window accepted per architecture.md's Category resolution
//   brand: <string>,
//   price: { amount: <decimal>, currency: <string> },
//   status: "Active" | "Discontinued",
//   size: <string | null>,
//   color: <string | null>,
//   extendedAttributes: <object>,
//   ratingSummary: { avg: <double>, count: <int> },  // written only by the ReviewSubmitted/ReviewUpdated projector — field-scoped, never touched by the catalog projector (edge-cases.md "Concurrent read-model writes clobber the denormalized document")
//   lastUpdatedAt: <ISODate>             // last accepted catalog projection write — the write-through cache's own freshness signal (design-decisions.md)
// }

// Sharded by category.id (BRD §6.2, requirement-spec §2) for browse-query
// locality — unchanged from the BRD's own stated sharding decision; this
// stage only confirms it, since ddd-model.md's SKU-keying resolution
// changes the document's identity field, not its shard key.
sh.shardCollection("kart.product_read_model", { "category.id": 1 })

// Supports "list every sibling variant under this product group" (product-
// page variant-picker UI) without embedding them (ddd-model.md's
// read-model-keying resolution note) — a lightweight secondary query, not
// this document's primary access path.
db.product_read_model.createIndex({ productGroupId: 1 })
```

### Concurrency Control at the Read-Model Layer (implements design-decisions.md's decision, doesn't re-derive it)

Every projector write is a **field-scoped partial update** (`$set` only the fields its own event owns), per edge-cases.md's "Concurrent read-model writes clobber the denormalized document" decision:

- `ProductPriceChanged` projector: `$set: { price, lastUpdatedAt }` only.
- `ProductUpdated` projector: `$set` only the changed parent/attribute fields named in the event's `changedFields`, plus `lastUpdatedAt`.
- `ProductDiscontinued` projector: `$set: { status: "Discontinued", lastUpdatedAt }` only.
- `ReviewSubmitted`/`ReviewUpdated` projector: `$set: { ratingSummary }` only — never touches `price`, `status`, or any catalog field.

No document version field or optimistic-lock retry loop is needed (design-decisions.md already ruled this out): every projector's field set is disjoint from every other's, so two concurrent partial updates to the same document commit independently without either clobbering the other's fields.

## Indexing Rationale

| Index | Query it supports | Why needed |
|---|---|---|
| `variants` PK (`sku`) | `PATCH /v1/products/{sku}`; the SKU-uniqueness invariant | Direct point lookup/write — no other column identifies a Variant |
| `variants(product_group_id)` | Archive cascade (ddd-model.md flow 3: "every currently-Active sibling Variant"); parent-edit fan-out | Without it, both operations force a full-table scan of `variants` per parent edit/archive |
| `variants(size) WHERE size IS NOT NULL`, `variants(color) WHERE color IS NOT NULL` | Browse/facet filtering on size/color at 100M-SKU scale (requirement-spec §2) | A category-agnostic full scan can't hold the read-path latency budget at this row count; partial indexing keeps the index from carrying rows where the filter is meaningless |
| `product_groups(category_id)` | Any future "all product groups in category X" admin/reporting query | Low-cost insurance at this table's much smaller row count (bounded by distinct product-group count, not SKU count) |
| `product_outbox_events(id) WHERE published_at IS NULL` | The Outbox poller's own "find unpublished rows" scan | Without it, the poller degrades to scanning the full, ever-growing outbox history every poll cycle |
| `product_read_model` shard key (`category.id`) | Browse-query locality (BRD §6.2) | Unchanged from the BRD's own stated decision — this stage confirms it still applies under SKU-keying, since the shard key is independent of the document's own `_id` |
| `product_read_model(productGroupId)` | "List sibling variants" product-page query | Without it, that query has no index to run against at all under SKU-keyed documents |

## Partitioning/Sharding

- **`variants`** is the platform's largest single write-side table (100M SKUs, BRD §4.1). No partitioning is added at this stage: every write and read against it is a single-row point operation keyed by `sku` (the primary key), which PostgreSQL's own B-tree handles at this scale without range/hash partitioning — partitioning would only help a query pattern that scans a *range* of SKUs, and no such pattern exists anywhere in requirement-spec.md, edge-cases.md, or ddd-model.md. Flagged, not blocking: if a future bulk-catalog-load pattern needs range scans (e.g. "all SKUs uploaded by partner X in batch Y"), that is a new access pattern to design an index or partitioning scheme for then, not a gap in today's design.
- **`product_groups`** is bounded by distinct product-group count, several orders of magnitude smaller than the SKU count (most products carry a small, single-digit variant count per ddd-model.md) — no partitioning called for.
- **`product_outbox_events`** grows with write volume but is self-bounding in practice: rows are deleted or archived once `published_at` is set and a retention window elapses (standard Outbox housekeeping, same pattern every other Outbox-backed service in this platform already uses — no service-specific deviation needed here).
- **`product_read_model`** sharding is already fixed by the BRD (`category.id`) and confirmed unchanged above — no further partitioning decision needed at this stage.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner
- [x] Approved (write-model schema — `product_groups`/`variants` — reviewed at full write-model approval weight; `product_read_model` is a standard rebuildable projection)
