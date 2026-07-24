---
doc_type: ddd-model
service: kart-product-service
status: approved
generated_by: ddd-agent
source: docs/services/kart-product-service/architecture.md, docs/services/kart-product-service/design-decisions.md, docs/services/kart-product-service/requirement-spec.md, docs/services/kart-product-service/edge-cases.md, docs/ddd/ubiquitous-language.md, docs/adr/0018-search-catalog-signal-sourcing.md
---

# DDD Model: kart-product-service

## Aggregate-Boundary Resolution (closes requirement-spec §2/§6 item 3's deferred call)

`requirement-spec.md` fixed the write-side column split (a `Product` parent/grouping row plus one-or-more `Variant`/SKU rows) but explicitly left "whether Variant is a child entity inside the Product aggregate or its own aggregate referencing Product by ID" to this stage. Resolved by the transaction-boundary test (`ddd-agent.md`/`ddd-cqrs-standards.md`: if two things don't need to commit together, they're two aggregates, not one):

- **`Variant` is its own aggregate root, not a child entity of `Product`.** A price or status change to one SKU must never require loading or locking every sibling variant under the same parent — at requirement-spec's own stated 100M-SKU scale (BRD §4.1), a product with a non-trivial size/color matrix would turn every single-SKU price edit into a whole-parent-document write if `Variant` were embedded. `edge-cases.md`'s "SKU uniqueness enforcement" and "Out-of-order `ProductPriceChanged` delivery" edge cases are both already reasoned entirely in terms of one SKU at a time, with no dependency on sibling variants — confirming no invariant actually needs the two to share a transaction.
- **`Product` (parent) is a separate, genuinely necessary aggregate**, not a legacy artifact to collapse away: it is the one place `name`, `description`, `categoryId`, and `brand` are authored once and shared across every sibling variant, and it is the unit `POST /products` creates together with its initial `Variant` (two sequenced saves, not one ACID transaction — see Cross-Aggregate Interaction below).

**Read-model keying — resolves a framing tension with requirement-spec.md, not a re-litigation of anything it actually decided.** requirement-spec.md's own §2 describes the read model as "an array of variant subdocuments... inside the parent product document," but the BRD's own worked example (§6.2) is a **flat, SKU-keyed** document (`"_id": "sku-192837"`, no parent id, no nested array) — and every downstream consumer this platform has since approved reads/writes at exactly that SKU grain: `ProductCreated`/`ProductPriceChanged`'s payloads are `sku`-only (BRD §10, no parent-product field at all), Cart's lazy validation and Wishlist's price comparison are both per-`CartLineItem.sku`/wishlisted-SKU, and Recommendation's/Cart's `GET /products/{id}` calls resolve a single sellable item. requirement-spec.md itself flagged this exact call ("aggregate-boundary question... deliberately left to the DDD Agent") as not yet decided, so this is that decision, not a change to one already made: **`product_read_model` is keyed one document per SKU** (`_id: <sku>`), matching the BRD's literal example and every consumer's actual access pattern, with `Product`'s shared parent-level fields (`name`, `description`, `category`, `brand`) denormalized redundantly onto each sibling `Variant`'s own document — the same denormalize-to-avoid-joins trade-off BRD §6.2 already states the rationale for. No nested variants array exists in the read model. A lightweight secondary index by `parentProductId` (database-design.md) supports "list this product's other variants" for a product-page variant-picker UI without embedding them.

## Aggregate: Product

**Entity:** `Product` — identified by `ProductId` (server-generated). The parent/grouping record; never itself an orderable or priced unit.

**Value objects:**
- `ProductStatus` — `Draft | Published | Archived`. `Draft` until the product has at least one `Variant` (see Cross-Aggregate Interaction); `Archived` is the parent-level retirement of the entire product line, distinct from one `Variant` being individually discontinued.

**Fields:** `id`, `name`, `description`, `categoryId`, `brand`, `status`.

**Invariants:**
- A `Product` is `Published` only once at least one child `Variant` exists for it — enforced at the application/write-path layer (a cross-aggregate condition, not a single-document constraint; see Cross-Aggregate Interaction).
- `categoryId` references a `Category` (owned by `kart-category-service`) supplied by the caller at write time; `Product` does not independently validate or refresh it against Category (per `architecture.md`'s "Category — no confirmed dependency edge today" resolution) — a known, accepted staleness window if the referenced category is later renamed, not a gap this aggregate closes.
- Archiving a `Product` (`Published`/`Draft` → `Archived`) cascades to discontinuing every child `Variant` still `Active` — an explicit, sequenced application-level orchestration across two aggregates (see Cross-Aggregate Interaction), never an ACID multi-document transaction.
- **CanRead/CanWrite/CanDelete ownership (BRD §24.1.2 — service-owned, decided here rather than left implicit now that it is a named platform requirement).** A `Product` has no per-user ownership dimension — it is public catalog data, not a resource any individual Customer owns. **Mechanism chosen: unconditional `CanRead` (any principal, including unauthenticated browse traffic), coarse-role-gated `CanWrite`** — `POST /products`, and any `PATCH` touching `name`/`description`/`categoryId`/`brand`/`status`, require the caller's JWT role claim to be `Admin` (BRD §24.1.1's "catalog management" grant) or `Partner API` (BRD §24.1.1's "bulk catalog upload" grant); no ownership comparison is meaningful here (there is no `userId` a `Product` belongs to) and no persisted grant table is needed (unlike Admin Service's own per-category `admin_permission_grants`, Product's write gate has no further per-principal or per-category distinction to make once role membership is established). `CanDelete` is never exposed — archiving is the only retirement path, itself gated by the same `CanWrite` role check, never a hard delete (CQRS-rebuildability invariant above).
- **Audit-actor invariant (BRD §24.3).** Every mutation to `product_groups` (database-design.md) stamps `created_by`/`updated_by` with the resolved acting principal — the Admin/Partner API client identity for every write reaching this aggregate (creation, parent-field edit, archive), since no self-service/end-user write path exists for `Product`. Auto-injected by the shared `kart-shared` `Kart.Shared.Auditing` package's `SaveChanges` interceptor (§24.3 — one platform-wide implementation referenced as a NuGet dependency, not built locally by this service; see database-design.md), never populated from a request-handler-supplied value, and never `NULL`.

**Domain events:** None published directly by this aggregate. Every externally-visible catalog event is `Variant`-level (see below) — this matches every consumer's SKU-keyed expectation and avoids inventing a second, differently-shaped "parent changed" event no consumer has asked for.

## Aggregate: Variant

**Entity:** `Variant` — identified by `Sku` (value object). The actual sellable, priced unit (requirement-spec §2/§4) — one row per SKU, referencing its parent `Product` by `parentProductId`.

**Value objects:**
- `Sku` — globally unique across the catalog (requirement-spec §4 Domain Invariant; edge-cases.md "SKU uniqueness enforcement"), enforced via a PostgreSQL unique constraint at the write side (design-decisions.md), independent of the MongoDB read model's `category.id` shard key.
- `Money` — `{ amount, currency }`; the base/list price, owned here as the system-of-record (requirement-spec §4 — Pricing/Offer only computes derived quotes, never announces base price changes).
- `VariantStatus` — `Active | Discontinued`. Soft-delete only, never a hard delete (requirement-spec §4's CQRS-rebuildability invariant; edge-cases.md "Discontinued/orphaned variant").
- `ProductAttributes` — the hybrid EAV/JSONB attribute set requirement-spec §2 already fixed: first-class indexed fields (`size`, `color`) plus a schemaless `extendedAttributes` bag for everything else. Modeled as one value object so the write-side column split and the read-model embedding stay in lockstep — this stage does not reopen which attributes are first-class, only confirms the value object groups them together.

**Fields:** `sku`, `parentProductId` (FK to `Product`), `price: Money`, `status: VariantStatus`, `attributes: ProductAttributes`.

**Invariants:**
- `sku` is immutable and globally unique once assigned (edge-cases.md).
- A `Variant` always references exactly one `Product` — many-to-one, mirroring `kart-category-service`'s identical cardinality decision for Product↔Category, and for the same reason (a single, unambiguous grouping, not a tagging system).
- `status` transitions `Active → Discontinued` are one-directional in this model — nothing in requirement-spec.md, edge-cases.md, or the BRD asks for a reinstatement path, and inventing one would be scope not requested; a genuinely new SKU is the modeled path for "selling this again."
- A price or status write is a single-document, single-aggregate operation — no other `Variant` or the parent `Product` is touched by it (this is the concrete outcome the aggregate-boundary resolution above exists to guarantee).
- **CanRead/CanWrite/CanDelete ownership (BRD §24.1.2).** Same no-ownership-dimension reasoning as `Product` above: a `Variant`/SKU is not owned by any individual Customer. **Mechanism chosen: unconditional `CanRead`, coarse-role-gated `CanWrite`** — `price`/`status`/`attributes` writes via `PUT`/`PATCH /products/{id}` require the caller's JWT role claim to be `Admin` or `Partner API` (BRD §24.1.1), an inline check with no ownership comparison and no persisted grant table, identical to `Product`'s mechanism. `CanDelete` is never exposed — `status: Active → Discontinued` is one-directional and soft (already stated above), never a hard delete, itself gated by the same `CanWrite` role check.
- **Audit-actor invariant (BRD §24.3).** Every mutation to `variants` (database-design.md) stamps `created_by`/`updated_by` with the resolved acting principal — the Admin/Partner API client identity for a direct catalog write (create, price/status/attribute edit), or a well-known `system:*` principal id for any future internal reconciliation job — never a client-suppliable value, never `NULL`, auto-injected by the same shared `kart-shared` interceptor as `Product`.

**Domain events:**
- Published: `ProductCreated` (`sku`, `name`, `description`, `categoryId`, `brand`, `price`, `status`, `attributes` — BRD §10 originally fixed `sku, attributes` only; grown by [ADR-0018](../../adr/0018-search-catalog-signal-sourcing.md) once `kart-search-service` confirmed it needs the full initial snapshot to build a searchable document, additive/non-breaking) — fired once per `Variant` creation, including the initial variant created alongside its parent `Product` via `POST /products`, and any later variant added to an existing product.
- Published: `ProductPriceChanged` (`sku`, `oldPrice`, `newPrice`, plus an added `occurredAt` — see event-contract.md's payload resolution for why) — fired on a `price` write.
- Published: `ProductUpdated` (`sku`, `changedFields`, `occurredAt`, plus `name`, `description`, `categoryId`, `brand`, `status`, `attributes` — grown by [ADR-0018](../../adr/0018-search-catalog-signal-sourcing.md) for the same reason as `ProductCreated` above) — fired on any non-price field write, including a parent-level `Product` edit (name/description/category/brand) fanned out as one `ProductUpdated` per affected sibling `Variant` (see Cross-Aggregate Interaction) — keeps every consumer's mental model uniformly SKU-keyed rather than introducing a second, parent-shaped event.
- Published (**new — formalized here**, not in the BRD's Event Catalog): `ProductDiscontinued` (`sku`, `discontinuedAt`) — fired on `status: Active → Discontinued`. Proposed at requirement-spec/edge-cases stage the same way `kart-offer-service`'s `CouponRedemptionVoided`/`PromotionDeactivated` were proposed; formalized as a first-class domain event here, the same formalization step ADR-0008 later gave Offer's proposed events. This directly unblocks two already-approved downstream commitments: `kart-search-service/requirement-spec.md` (resolved Open Question #4, already committed to consuming it as a soft-remove signal) and `kart-wishlist-service/edge-cases.md` ("Stale Wishlist Entry for a Discontinued Product," which names this event as the faster forward path alongside its own reconciliation-job default).
- Consumed: `ReviewSubmitted` (external — owned by `kart-review-service`; `orderId, sku, rating, reviewId, userId`) and `ReviewUpdated` (external — owned by `kart-review-service`; `orderId, sku, oldRating, newRating`, new, requirement-spec §2). Both drive an incremental, field-scoped update to this SKU's `ratingSummary` projection (see Read-Model Projection below) — never a second canonical rating computation (ADR-0014). `kart-search-service` independently consumes the same two events for its own equivalent ranking-signal projection ([ADR-0018](../../adr/0018-search-catalog-signal-sourcing.md)) — a second reader of Review's stream, not a second write path into this service's own `ratingSummary`.

## Read-Model Projection: `product_read_model` (MongoDB)

Not a fourth aggregate — a single-collection, SKU-keyed projection combining `Variant` (its own fields) with its parent `Product`'s shared fields (denormalized) and two externally-sourced summary fields, fed by five independent event/consumption paths:

- `ProductCreated`/`ProductPriceChanged`/`ProductUpdated`/`ProductDiscontinued` (this service's own `Variant` writes, Outbox-published then self-consumed into the projection — the standard CQRS write→project pipeline every other service in this platform already uses).
- `ReviewSubmitted`/`ReviewUpdated` (external, Review-owned) — writes only the `ratingSummary` field, field-scoped (edge-cases.md's "Concurrent read-model writes clobber the denormalized document" decision) so a rating projection can never clobber a concurrent price projection or vice versa.

**Invariant:** the read model must always be rebuildable from `Product` + `Variant`'s PostgreSQL rows plus the replayed `ReviewSubmitted`/`ReviewUpdated` stream (requirement-spec §4's CQRS-rebuildability invariant) — `ratingSummary` is therefore never itself a source of truth, only a cache of Review's own canonical aggregate (ADR-0014), and is excluded from any rebuild-from-write-side replay (it is re-derived from Review's event stream instead, the two sources composing without conflict per their disjoint field ownership).

## Cross-Aggregate Interaction

Three flows touch both `Product` and `Variant`, each as sequenced, independent saves — never one ACID transaction, per the aggregate-boundary resolution above:

1. **`POST /products` (initial creation).** Save `Product` (status `Draft`) → save its initial `Variant` → flip `Product.status` to `Published` → publish `ProductCreated` for that `Variant`. If the `Variant` save fails after the `Product` save commits, the result is a `Product` stuck in `Draft` with zero variants — a valid, inert interim state (not a broken invariant), retried or cleaned up as an ordinary write-path failure, not a distributed-transaction rollback concern.
2. **Adding a variant to an existing `Product`.** Save the new `Variant` referencing the existing `parentProductId` → publish `ProductCreated` for it. No write to `Product` itself is needed (it already exists and is already `Published`).
3. **A parent-level edit (`PATCH` on `name`/`description`/`categoryId`/`brand`) or archiving a `Product`.** Save `Product`'s own field(s)/`status` → for archiving, sequentially set every currently-`Active` sibling `Variant` to `Discontinued`, each write independently publishing `ProductUpdated` (parent-field edit) or `ProductDiscontinued` (archive cascade) for its own `sku`. A partial failure mid-cascade (some siblings updated, others not) is retried at the write-path level like any other multi-step application operation — it is not a rollback scenario, since each `Variant` write was already independently valid and durable the moment it committed.

`ReviewSubmitted`/`ReviewUpdated` consumption never touches `Product` or triggers any of the above — it is a fourth, fully independent path writing only the read model's `ratingSummary` field for a given `sku` (see Read-Model Projection above).

## Referenced Elsewhere (owned by another bounded context — accessed via ACL, not redefined here)

| Term | Owning Context | How this service uses it |
|---|---|---|
| Category | `kart-category-service` | `Product.categoryId` is a caller-supplied reference only; this service never validates it live against Category or models Category's own hierarchy/taxonomy invariants. |
| Rating / `ReviewSubmitted` / `ReviewUpdated` | `kart-review-service` | Consumed only to maintain `product_read_model.ratingSummary` as a denormalized projection (ADR-0014); this service never models Review's own moderation workflow or canonical rating aggregate. |

## Modeling Decisions & Assumptions (resolved here, not escalated — engineering defaults, revisable)

1. **`Variant` as its own aggregate, `Product` as a separate parent aggregate** — see "Aggregate-Boundary Resolution" above; the central decision this stage exists to make, applying the transaction-boundary test directly.
2. **Read model keyed by SKU, not nested under a parent document** — see "Aggregate-Boundary Resolution" above; reconciles requirement-spec.md's illustrative framing with the BRD's own worked example and every downstream consumer's actual access pattern, without reopening anything requirement-spec.md actually locked (the write-side column split, the hybrid EAV/JSONB attribute model).
3. **`ProductDiscontinued` formalized as a first-class domain event.** Was "proposed, not BRD-stated" through requirement-spec/edge-cases; formalized here the same way Offer's proposed events were later formalized by ADR-0008. Payload kept minimal (`sku, discontinuedAt`) — Search and Wishlist's own docs describe consuming it purely as a removal/staleness signal, needing no richer payload than that.
4. **`ProductUpdated` always fans out per-SKU, never as one parent-shaped event.** A parent-level rename could instead be published as one event carrying a list of affected SKUs; rejected in favor of per-SKU fan-out so every consumer of Product's events has exactly one payload shape to handle (`sku`-keyed) across all four event types, rather than two structurally different shapes. Accepted trade-off: a product with many variants generates a burst of events for one logical parent edit — judged acceptable since catalog edits are far less frequent than the 100M-SKU count would suggest for any single product (most products carry a small, single-digit variant count).
5. **`ProductCreated`/`ProductUpdated` payloads grown beyond their original BRD-fixed/first-drafted shape** ([ADR-0018](../../adr/0018-search-catalog-signal-sourcing.md), added during `kart-search-service`'s own pipeline pass) — `kart-search-service` confirmed a structural need for the full current catalog snapshot on both events (its own no-Mongo-dependency invariant forbids the `GET /v1/products/{sku}` workaround this document originally assumed any richer-value consumer would use), so `name, description, categoryId, brand, status, attributes` (plus `price` on `ProductCreated` only) are now carried on both. Additive-only; Analytics' existing consumption is unaffected.
6. **`Product.status`'s `Archived` state cascades to its variants rather than being a purely independent flag.** Grounded in requirement-spec §4's CQRS-rebuildability/soft-delete posture applied one level up: an "archived" parent with `Active` children would leave sellable SKUs orphaned under a product no longer meant to be catalogued at all. Revisable if a future requirement wants archived-parent-with-still-sellable-children as a distinct, intentional state — nothing today asks for it.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner
- [x] Approved to proceed to API/Database/Event Design Agents
