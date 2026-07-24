---
doc_type: requirement-spec
service: kart-category-service
status: approved
generated_by: requirement-agent
source: docs/requirements/kart-requirements.md
---

# Requirement Spec: kart-category-service

## 1. Scope

Covers the single BRD service **Category** (BRD §2.1 item 4: "Taxonomy, hierarchy, navigation"). No merge, no ADR governs scope — this is a standalone bounded context.

The BRD's treatment of Category is minimal: one core-modules row (§2.1), one condensed API/DB/events row (§5.4), and a handful of incidental mentions elsewhere (§6.1, §6.2, §17) where other services reference category data rather than describe Category's own behavior. This spec does not fill those gaps with invented requirements. A prior draft of this spec carried six items as blocking Open Questions; this pass closes all six:

1. **Tree depth limit** — resolved directly (§2, §4): max depth 4, materialized-path storage.
2. **Product-category cardinality** — resolved directly (§2, §4): many-to-one (single primary category per product), matching Product's own denormalization shape.
3. **`CategoryUpdated`'s consumer** — resolved by BRD §10 as amended by **ADR-0004** and **ADR-0008**: Analytics is the confirmed consumer. See §2, §5.
4. **Read-model contradiction (§6.1 vs §5.4)** — this one had no existing ADR and is a genuine BRD self-contradiction; resolved by a new ADR, ADR-0011 (`docs/adr/0011-category-read-model-scope.md`): Category is served directly from PostgreSQL, no separate MongoDB read model. See §3, §4.
5. **`CategoryUpdated` retry/DLQ policy** — resolved by the same BRD §10 row ADR-0008 added: 3x retry, `catalog.dlq`. See §3, §5.
6. **Write-path ownership (Category vs. Admin)** — resolved directly (§4): Category owns its own write model and write API; Admin calls it, never writes Category's tables directly.

None of these are left as "silently picked" interpretations — each resolution below states what was decided, why, and (where relevant) which existing ADR, new ADR, or BRD passage grounds it. See §6 for the full closure log and for the small number of items that are legitimately carried forward (non-blocking) to later pipeline stages rather than resolved here.

## 2. Functional Requirements

- Maintain the category taxonomy — the set of category entities and their attributes (BRD §2.1 item 4: "Taxonomy").
- Maintain parent-child hierarchical relationships between categories (BRD §2.1 item 4: "hierarchy"), bounded to a **maximum depth of 4 levels** (e.g., Department → Category → Subcategory → Sub-subcategory), stored as a materialized path (or ancestor array) per category rather than resolved via recursive query. This is a resolved engineering default, not a BRD-stated number — see §4's Domain Invariants for the why/trade-off, matching the depth-mechanism decision edge-cases.md already made in "Unbounded hierarchy depth degrades navigation read latency."
- Serve category data to support site navigation via `GET /categories` (BRD §5.4: "navigation" responsibility, API surface row). The BRD gives no HTTP method or request/response shape — read-only listing is assumed, not stated; final contract remains the API Design Agent's job (§5).
- Expose its own write API for taxonomy curation — create, rename, move (re-parent), and soft-delete/deprecate a category — rather than accepting writes to its tables from any other service. See §4's Domain Invariant on write ownership for the why.
- Publish `CategoryUpdated` on every taxonomy write that changes what a client would see in navigation or facets: create, rename, move/re-parent, and deprecate (soft-delete). This is a resolved default (the BRD names the event but not its triggering operations); a subtree move emits one coarse event describing the moved subtree root/path rather than one event per descendant, per edge-cases.md's "Subtree re-parenting invalidates downstream category data" decision. Consumer, retry, and DLQ are settled: BRD §10 (as corrected by **ADR-0004**, **ADR-0008**) lists Analytics as the confirmed consumer, 3x retry, `catalog.dlq`.
- Category data is a dependency of two other services, per incidental BRD mentions, though the BRD does not describe a live sync mechanism connecting them to Category:
  - Product's denormalized MongoDB read model embeds `category: { id, name }` per product (BRD §6.2 example) and uses `category.id` as the MongoDB sharding key for the Product and Search collections (BRD §6.2).
  - Search facets/filters on category (BRD §17: "faceted aggregations on category, price range, and rating").
  - Neither Product's nor Search's own approved `requirement-spec.md`/`edge-cases.md` names itself as a consumer of `CategoryUpdated` today, despite each holding a denormalized copy of category data. That is stated here as an explicit, current fact, not silently assumed to be fine forever: if Product or Search later need live sync (rather than accepting the staleness window edge-cases.md already budgets for), that is a new finding for *their* own docs, per **ADR-0008**'s own stated boundary ("a new, separate finding for that service's own docs, not something this ADR should be read as having already answered"). It is not a blocker for this service's sign-off — Category's responsibility ends at publishing a well-defined event; wiring a consumer is each downstream service's own call.

## 3. Non-Functional Requirements

Pulled from the BRD's global NFR table (§3), scoped to this service:

| Attribute | Target | Applies here because |
|---|---|---|
| Availability | 99.9% (secondary path) | Category is absent from the Order Saga path and the service-boundary diagram's message-bus fan-out (§5.5) — nothing in the BRD places it on the 99.99% critical-path tier |
| Latency | P95 < 150ms, P99 < 400ms (read path) | `/categories` is a read endpoint; §6.1 explicitly groups Category with Product and Search as "Read-Heavy" services on the global read-path budget. Achieved via PostgreSQL read replicas plus caching, not via a second MongoDB read store — see ADR-0011 (`docs/adr/0011-category-read-model-scope.md`) |
| Consistency | Strong, read-your-write within Category's own PostgreSQL store; Eventual (seconds-scale) for downstream copies in Product/Search once wired | Resolved: ADR-0011 (`docs/adr/0011-category-read-model-scope.md`) settles that Category has no read-side store of its own to lag behind, so its own reads are always current. Any customer-visible staleness lives entirely in Product's/Search's denormalized copies, which edge-cases.md's "Taxonomy write vs. Search facet staleness" already budgets against the existing Product→Search precedent (BRD §2.2) |
| Reliability | At-least-once delivery + idempotent consumers | This is the BRD's blanket NFR (§3) for all messaging; applies to `CategoryUpdated` publication, now with a confirmed consumer (Analytics, BRD §10 as amended by ADR-0004/ADR-0008) |
| Retry/DLQ | 3x retry, `catalog.dlq` | Resolved: BRD §10, added by **ADR-0008** ("same tier as sibling catalog events `ProductCreated`/`ProductPriceChanged`") |

**Cross-cutting Security obligations added by BRD §24.1.2, §24.1.4, §24.1.5, §24.3 (cross-reference only — the detailed "why" lives in the BRD itself and in this service's own ddd-model.md/database-design.md, not re-derived here):**

- **§24.1.2 (CanRead/CanWrite/CanDelete, service-owned):** Category is the resource owner of its own `Category` taxonomy data and defines its own fine-grained permission mechanism — a `Category` node has no per-user ownership dimension (it is public navigation/taxonomy data, not owned by any individual Customer), so `CanRead` (`GET /categories`) is an unconditional grant to any principal, including unauthenticated browse traffic. `CanWrite`/`CanDelete` (create, rename, move, deprecate — §2/§4/§5 above) are instead gated purely on the caller's coarse role being `Admin` (BRD §24.1.1's "catalog management" grant, already cited in this document's §4 write-ownership invariant) via an inline role-claim check, with no persisted grant table (there is no per-category or per-principal distinction beyond "is this caller Admin," unlike Admin Service's own many-category `admin_permission_grants`) and no ownership comparison (no `userId` a taxonomy node belongs to). The concrete mechanism is recorded as a Domain Invariant in ddd-model.md.
- **§24.1.4 (row-level security):** Category's write model is 100% PostgreSQL (`categories`, `category_outbox_events` — database-design.md), with no MongoDB read model at all (ADR-0011). Neither table has a per-row end-user ownership column — a taxonomy node belongs to no individual Customer — so native RLS's ownership predicate has nothing to key on here, the same carve-out BRD §24.1.4 itself anticipates via its own Payment `payment_intents` example. See database-design.md's "Row-Level Security Policy" subsection for the explicit no-ownership reasoning.
- **§24.1.5 (column-level security):** No sensitive/PII columns exist. `categories.name`/`parent_id`/`ancestor_path`/`depth`/`status` are public taxonomy/navigation content, not personal data about any individual — there is no analogue here to Payment's tokenized-credential case or User's address/phone. See database-design.md's "Sensitive / PII Column Classification" subsection.
- **§24.3 (default audit fields):** every mutable table in database-design.md (`categories`, `category_outbox_events`) now carries `created_at`/`updated_at`/`created_by`/`updated_by`, auto-injected by the shared `kart-shared` `Kart.Shared.Auditing` package's `SaveChanges` interceptor reading the JWT principal (§24.3's own stated mechanism — one platform-wide implementation, not built locally by this service) — never a value a request handler sets directly. The acting principal is Admin's own client/operator identity for every taxonomy write (Category has no self-service end-user write path), or a well-known `system:*` id for the Outbox relay — never `NULL`.

## 4. Domain Invariants

- A category must not be its own ancestor (no cycles) — not stated explicitly by the BRD, but inferred from the stated responsibility itself: a structure described as a "hierarchy" (BRD §2.1 item 4) is not well-formed if it contains a cycle. Enforced synchronously at write time — see edge-cases.md's "Circular category reference on re-parent."
- **Maximum hierarchy depth is 4 levels**, enforced at write time (create/move rejected if it would exceed this), with a materialized path (or ancestor array) stored per category so reads never pay for a recursive walk. *Decision:* 4 levels is consistent with typical e-commerce taxonomy depth (department → category → subcategory → sub-subcategory) and is deep enough for a general marketplace catalog without unbounded growth. *Why:* the BRD names no number, but the latency NFR (§3) and the materialized-path mechanism edge-cases.md already chose both require *some* concrete bound to be enforceable; leaving it unbounded reopens the exact read-latency failure mode edge-cases.md's "Unbounded hierarchy depth degrades navigation read latency" describes. *Trade-off accepted:* a taxonomy that genuinely needs a 5th level (rare in general e-commerce, more common in some B2B/industrial catalogs) would need this limit revisited — an explicit, documented default rather than a silent one.
- **Product-category cardinality is many-to-one: exactly one (primary) category per product.** *Decision:* a product belongs to exactly one category at a time; cross-cutting discovery (e.g., "also in Deals," multi-facet browsing) is Search's/Product's own concern, not a second category membership Category itself tracks. *Why:* BRD §6.2's `product_read_model` example embeds a single `category: { id, name }` object (not an array), and `category.id` is used as *the* MongoDB sharding key for the Product and Search collections (BRD §6.2) — a shard key must resolve to exactly one value per document, which is only well-defined under single-category membership; a many-to-many model would leave "which category shards this product" ambiguous. Neither Product's nor Search's own approved docs describe or need multi-category membership. *Trade-off accepted:* re-categorizing a product is a single-field update (simple), but the platform cannot natively express "this product also appears in a second category" without a separate, explicit tagging mechanism outside Category's own domain — not built here because nothing in the BRD asks for it.
- Category identifiers, once assigned, should remain stable rather than being reassigned or reused — inferred from `category.id` serving as the MongoDB sharding key for the Product and Search collections (BRD §6.2); reassigning an id would misroute already-sharded data. Deletion is soft (deprecate, never physically remove/reuse an id) per edge-cases.md's "Deleting a category that still has products assigned," for the same sharding-key reason.
- **Category service owns its own write model exclusively; Admin Service (or any other service/actor) performs taxonomy curation only through Category's own write API, never by writing to Category's PostgreSQL tables directly.** *Decision:* `/admin/*`'s "catalog management" example grant (BRD §24.1) is realized as Admin calling Category's RBAC-gated write endpoints (create/rename/move/deprecate), authenticated with the same Identity-issued `Admin` role claim every other RBAC-gated surface on the platform trusts (BRD §24.1) — not as a second, Admin-owned path into Category's tables. *Why:* this is the same bounded-context ownership pattern already implicit across every service in BRD §5.1–§5.4 (each service names exactly one database as its own; no service's Boundary Rationale ever describes another service writing directly into its tables), and it mirrors the platform's existing single-writer conventions (e.g., Identity as sole issuer of role claims — BRD §24.1 — which every consumer, including Admin, trusts rather than duplicates). This is a direct application of an existing, ubiquitous platform default, not a new cross-cutting architectural pattern, so it is decided here rather than via a new ADR. *Trade-off accepted:* Admin cannot bulk-load or directly patch category rows for performance reasons without going through Category's own API/validation (cycle check, depth check) — accepted, because bypassing that validation is exactly the class of bug the "no cycles" and "max depth" invariants above exist to prevent.
- Beyond these invariants, the BRD states no further business rules for Category (no oversell-style or double-charge-style rule as it does for Inventory/Payment at §2.2). Do not treat this spec's silence elsewhere as permission to invent rules the BRD doesn't support.

## 5. API Surface (from BRD, starting point only)

| Endpoint/Event | Direction | Notes |
|---|---|---|
| `GET /categories` | Inbound API | BRD §5.4; no HTTP method stated beyond the implied read, read-only listing assumed. Final shape (pagination, tree vs. flat, filter params) is the API Design Agent's job |
| `POST /categories`, `PATCH /categories/{id}`, `POST /categories/{id}/move`, `DELETE /categories/{id}` (soft-delete/deprecate) | Inbound API | Not named explicitly in the BRD's condensed §5.4 row, but required by the write-ownership resolution in §4: Category exposes its own RBAC-gated write surface (same `Admin` role claim pattern as every other `/admin/*`-adjacent write, BRD §24.1) rather than accepting writes from Admin's own store. Exact verbs/routes/payload shape are the API Design Agent's job — this row only fixes *that* Category owns these operations, not their final contract |
| `CategoryUpdated` | Published | BRD §5.4; confirmed consumer and delivery policy per BRD §10 (added by **ADR-0004**, **ADR-0008**): consumer Analytics, payload `categoryId, name`, retry 3x, DLQ `catalog.dlq`. Fired on create/rename/move/deprecate (§2). Whether the payload needs to grow (e.g., a `path`/`parentId` field for subtree moves, per edge-cases.md's coarse-event decision) is the Event Design Agent's job, carried forward — see §6 |

## 6. Open Questions / Flagged Ambiguities

**Resolved this pass.** The prior draft carried six items as blocking; all six are closed:

1. *Tree depth limits* — resolved directly: max depth 4, materialized-path storage. See §2, §4.
2. *Product-category cardinality* — resolved directly: many-to-one (single primary category per product), grounded in BRD §6.2's single-object example and its use of `category.id` as a shard key. See §4.
3. *`CategoryUpdated` has no stated consumer* — resolved by **ADR-0004** (Analytics full fan-in) and **ADR-0008** (Event Catalog Completeness Pass, Round 2), which together give `CategoryUpdated` a confirmed row in BRD §10: consumer Analytics. Whether Product or Search additionally need to consume it is explicitly *not* answered by ADR-0008 (it says so itself) and is not answered here either — stated as an explicit, non-blocking current fact in §2, not a gap in this service's own docs.
4. *Read-model contradiction, BRD §6.1 vs. §5.4* — this was the one genuine BRD self-contradiction among the six, with no existing ADR covering it. Resolved via a new ADR: ADR-0011 (`docs/adr/0011-category-read-model-scope.md`) — Category is served directly from PostgreSQL, no separate MongoDB read model; §6.1's "Read-heavy" grouping is read as a traffic-shape classification, not a store-topology mandate. See §3, §4.
5. *`CategoryUpdated` retry/DLQ policy* — resolved by the same BRD §10 row ADR-0008 added: 3x retry, `catalog.dlq`, same tier as sibling catalog events. See §3, §5.
6. *Write-path ownership, Category vs. Admin* — resolved directly: Category owns its own write model and RBAC-gated write API; Admin calls it, never writes Category's tables directly — the same single-writer-per-bounded-context pattern already implicit across every other service in the BRD. See §4.

**Carried forward (non-blocking).** These are normal handoffs to later pipeline stages, not unresolved gaps:

- Final HTTP contract for `/categories` and the new write endpoints (pagination shape, tree-vs-flat response, exact verb/route naming) is the API Design Agent's job, as already noted in §5.
- Whether `CategoryUpdated`'s payload needs to grow beyond `categoryId, name` (e.g., to carry a `path`/`parentId` for subtree-move consumers) is the Event Design Agent's job once a concrete consumer beyond Analytics is confirmed.
- Whether Product and/or Search should become live consumers of `CategoryUpdated` (rather than relying on the eventual-consistency staleness window edge-cases.md already budgets for) is left to those services' own future requirement-spec revisions, per **ADR-0008**'s own stated scope boundary — not something Category's docs can or should resolve unilaterally on their behalf.

## Sign-off

- [x] Blocking open questions resolved
- [x] Reviewed by: Automated architecture pipeline — see docs/adr and this run's decision log
- [x] Approved to proceed to Architecture Agent
