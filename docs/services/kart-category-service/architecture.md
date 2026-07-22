---
doc_type: architecture
service: kart-category-service
status: approved
generated_by: architecture-agent
source: docs/services/kart-category-service/requirement-spec.md, docs/services/kart-category-service/edge-cases.md, docs/services/kart-category-service/design-decisions.md, docs/services/kart-category-service/ddd-model.md
---

# Architecture: kart-category-service

## Boundary Rationale

`kart-category-service` is the bounded context that answers "what is the shape of the taxonomy, and where does a given node sit in it" — it owns the category tree (creation, renaming, re-parenting, deprecation), the parent-child hierarchy invariant (no cycles, max depth 4, materialized-path storage), and its own read surface for navigation (BRD §2.1 item 4: "Taxonomy, hierarchy, navigation"; requirement-spec §1, §2, §4). No merge with another BRD service is indicated and no ADR proposes one — this is a standalone context, the smallest and least contended of the catalog-adjacent bounded contexts.

Two ADRs fix this boundary's edges precisely, closing what the requirement-spec's prior draft carried as blocking open questions:

- **[ADR-0011](../../adr/0011-category-read-model-scope.md)** settles that Category is served directly from PostgreSQL — it does not maintain a second, Mongo-backed read model the way Product and Search do. Category is the upstream *source* of `category.id`/`category.name` that Product's and Search's own MongoDB read models denormalize into their own collections; the copy lives on their side, never on a Category-owned Mongo collection. This keeps Category's own CQRS shape single-store and its consistency story strong/read-your-write, with all customer-visible staleness living downstream in Product's/Search's own projections.
- **[ADR-0010](../../adr/0010-admin-service-scope-and-integration.md)** settles the write-path ownership question: Category exposes its own RBAC-gated write API (create/rename/move/deprecate) and is the sole owner of its PostgreSQL write model. Admin Service never writes to Category's tables directly — it is a caller of Category's write API, exactly like every other service in the closed "catalog management" enumeration ADR-0010 fixes. This is the same single-writer-per-bounded-context pattern already implicit across BRD §5.1–§5.4.

Category is a **read-heavy, low-write-volume, non-order-path** service: `GET /categories` is called synchronously by the client-facing gateway for navigation, and by Admin's back office for write operations, but Category is **absent from the Order Saga** (BRD §12 only touches Inventory, Payment, Shipping) and absent from the message-bus fan-out that feeds the 99.99% critical-path tier (requirement-spec §3). This matters for availability posture: Category sits in the 99.9% secondary tier, can be briefly degraded without blocking order confirmation, and its own read-path latency budget (P95 < 150ms / P99 < 400ms) is met via PostgreSQL read replicas plus caching in front of `/categories` — not via a second datastore (ADR-0011).

## Dependencies

| Direction | Peer | Mechanism | Type | Notes |
|---|---|---|---|---|
| Inbound (client) | Client/Storefront via API Gateway | `GET /categories` | **Sync** (REST) | Navigation read surface (requirement-spec §5); P95 < 150ms / P99 < 400ms (requirement-spec §3). Read-only listing assumed; final shape (pagination, tree vs. flat) is the API Design Agent's job. |
| Inbound (service-to-service) | Admin Service | `POST /categories`, `PATCH /categories/{id}`, `POST /categories/{id}/move`, `DELETE /categories/{id}` (soft-delete/deprecate) | **Sync** (internal, client-credentials REST call) | Per **[ADR-0010](../../adr/0010-admin-service-scope-and-integration.md)**: Admin invokes Category's own write API as an orchestration/control-plane caller for the "catalog management" back-office category — it never writes to Category's PostgreSQL tables directly, and Category never grows a second writer. RBAC-gated on the same Identity-issued `Admin` role claim every other `/admin/*`-adjacent write trusts (BRD §24.1), plus Category's own cycle/depth validation (requirement-spec §4) at write time regardless of caller. |
| Outbound (published) | Analytics | `CategoryUpdated` event | **Async** | Confirmed consumer and delivery policy per BRD §10 as amended by **[ADR-0004](../../adr/0004-analytics-full-fanin-ingestion.md)** (Analytics full fan-in) and **[ADR-0008](../../adr/0008-event-catalog-completeness-round-2.md)** (added the missing §10 row): payload `categoryId, name`; 3x retry; DLQ `catalog.dlq`. Fired on create/rename/move/deprecate (requirement-spec §2). A subtree move emits one coarse event describing the moved subtree root/path, not one event per descendant (edge-cases.md, "Subtree re-parenting invalidates downstream category data"). |

**Deliberately absent from this table:** an edge from Category to Product or Search, in either direction. Both services hold a denormalized copy of category data (`category: {id, name}` embedded in Product's read model, `category.id` used as the MongoDB shard key for the Product and Search collections — BRD §6.2), and Search facets on category (BRD §17), but neither service's own approved `requirement-spec.md`/`edge-cases.md` names itself as a wired consumer of `CategoryUpdated` today. This is stated as an explicit, current fact (requirement-spec §2, §6), not an omission: **[ADR-0008](../../adr/0008-event-catalog-completeness-round-2.md)** explicitly scopes itself to *not* deciding whether Product or Search should additionally consume this event, leaving that as each downstream service's own future finding. Category's responsibility ends at publishing a well-defined event to its one confirmed consumer (Analytics); no phantom edge is drawn here to a consumer that doesn't yet exist.

## Distributed-Monolith Risk

**None identified.** Category has no synchronous outbound dependency on any other service — its one inbound synchronous edge (Admin calling its write API) is a low-frequency, back-office control-plane call, not a chatty dependency chain feeding a customer-facing critical path, and Category's own availability does not depend on Admin's being up (the reverse dependency is what exists: Admin's catalog-management operations depend on Category, not vice versa). Category is not a participant in the Order Saga and carries no synchronous dependency into it.

**One latent (already-budgeted, non-blocking) risk worth naming for later stages, not a distributed-monolith concern:** Product and Search each carry their own denormalized copy of category data with no live event-driven propagation path from Category today (see "Deliberately absent" note above). This is an eventual-consistency staleness window already budgeted by edge-cases.md ("Taxonomy write vs. Search facet staleness") against the existing Product→Search precedent (BRD §2.2), not a synchronous coupling — a Category outage cannot cascade into Product or Search failing, and a Product/Search outage cannot cascade into Category failing. It is flagged here only so a future Architecture Agent pass (if/when Product or Search add themselves as `CategoryUpdated` consumers per their own docs) knows the edge does not exist yet.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner, see docs/adr and this run's decision log
- [x] Approved to proceed to DDD Agent
