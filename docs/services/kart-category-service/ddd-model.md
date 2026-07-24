---
doc_type: ddd-model
service: kart-category-service
status: approved
generated_by: ddd-agent
source: docs/services/kart-category-service/requirement-spec.md, docs/services/kart-category-service/edge-cases.md, docs/services/kart-category-service/design-decisions.md, docs/services/kart-category-service/architecture.md
---

# DDD Model: kart-category-service

One aggregate root, one bounded context — the smallest, least-contended catalog-adjacent service on the platform. This model formalizes the aggregate shape `database-design.md`, `event-contract.md`, and `design-decisions.md` already implied consistently while this stage's own file did not yet exist; no invariant here contradicts either of those docs.

## Aggregate: Category

**Entity:** `Category` — identified by `CategoryId` (referenced from other bounded contexts — `kart-product-service`'s denormalized `category: {id, name}` field and `kart-search-service`'s category facets both reference this id, per BRD §6.2 — never redefining Category's own hierarchy).

**Value objects:**
- `AncestorPath` — the ordered root-to-immediate-parent chain of `CategoryId`s; the materialized-path representation that makes "is X an ancestor of Y" and breadcrumb reads index lookups, never recursive walks.
- `Depth` — the node's position in the tree (1–4); kept redundant with `AncestorPath.length` as its own field so the max-depth invariant is a cheap check, not a computed one.
- `CategoryStatus` — `Active | Deprecated`; deprecation is the only removal path, `CategoryId` is never physically deleted or reused.

**Invariants:**
- No `Category` may be its own ancestor — the tree must remain acyclic, enforced synchronously at write time via an `AncestorPath` containment check, not caught after the fact.
- Maximum `Depth` is 4 — enforced at write time (create/move rejected if it would exceed this).
- A `CategoryId`, once assigned, is never reassigned or reused, even after deprecation — it is the shard key Product's and Search's own read models key off downstream (BRD §6.2), and reassigning it would misroute already-sharded data.
- Deletion is always soft (`CategoryStatus = Deprecated`); a `Category` with products still referencing it is deprecated, never hard-removed, for the same shard-key-stability reason.
- A subtree move updates every descendant's `AncestorPath`/`Depth` as one logical operation and publishes exactly one coarse `CategoryUpdated` event describing the moved subtree's root and new path — never one event per descendant (edge-cases.md, "Subtree re-parenting invalidates downstream category data").
- **CanRead/CanWrite/CanDelete ownership (BRD §24.1.2 — service-owned, decided here rather than left implicit now that it is a named platform requirement).** A `Category` has no per-user ownership dimension — it is public navigation/taxonomy data, not a resource any individual Customer owns. **Mechanism chosen: unconditional `CanRead` (any principal, including unauthenticated browse traffic), coarse-role-gated `CanWrite`** — create, rename, move, and deprecate all require the caller's JWT role claim to be `Admin` (BRD §24.1.1's "catalog management" grant, requirement-spec.md §4's write-ownership invariant); no ownership comparison is meaningful (there is no `userId` a taxonomy node belongs to) and no persisted grant table is needed (a single coarse role check is sufficient — there is no further per-category or per-principal distinction to make, unlike Admin Service's own many-category `admin_permission_grants`). `CanDelete` is never exposed as a hard delete — deprecation (`CategoryStatus = Deprecated`) is the only removal path, itself gated by the same `Admin`-role `CanWrite` check, never a physical row removal (shard-key-stability invariant above).
- **Audit-actor invariant (BRD §24.3).** Every mutation to `categories` (database-design.md) stamps `created_by`/`updated_by` with the resolved acting principal — Admin's own operator/client identity for every create/rename/move/deprecate write, since Category has no self-service end-user write path. Auto-injected by the shared `kart-shared` `Kart.Shared.Auditing` package's `SaveChanges` interceptor (§24.3 — one platform-wide implementation referenced as a NuGet dependency, not built locally by this service; see database-design.md), never populated from a request-handler-supplied value, and never `NULL`.

**Domain events:**
- `CategoryUpdated` (published — existing, BRD §5.4/§10 as amended by ADR-0004/ADR-0008; payload `categoryId`, `name`, `parentId`, `path`, `operation`, `occurredAt`, finalized in event-contract.md). Fired on create, rename, move, and deprecate — the four writes requirement-spec.md §2 names as taxonomy-changing.

**Consumed events:** None. Category's writes are driven synchronously (client-facing reads via the Gateway; Admin's RBAC-gated write-API calls per ADR-0010) — it never reacts to another service's event (architecture.md, "Deliberately absent" note; event-contract.md's Consumed Events section).

## Cross-Aggregate / Cross-Context Interaction

There is no second aggregate in this bounded context, so there is no cross-aggregate transaction to reason about. The one cross-context relationship — Product's and Search's own MongoDB read models denormalizing `category: {id, name}` (BRD §6.2) — is a read-only reference via `CategoryId`, resolved entirely on Product's/Search's own side; Category never queries or writes into either service's data, and neither service is a wired consumer of `CategoryUpdated` today (a stated, non-blocking current fact, not a gap — see requirement-spec.md §2/§6 and ADR-0008's own scope boundary).

## Modeling Decisions & Assumptions (resolved here, not escalated — engineering defaults, revisable)

1. **`AncestorPath` is modeled as a value object, not a separate entity/aggregate**, because it has no identity or lifecycle of its own independent of the `Category` row it describes — it is recomputed and rewritten atomically whenever `Category.parent_id` changes, never referenced or mutated in isolation.
2. **No `CategoryTree` aggregate wrapping the whole hierarchy.** Each `Category` is independently the transaction boundary for its own create/rename/deprecate; a move touches multiple `Category` rows (the moved subtree) but resolves as sequential, individually-valid writes to each affected row within one database transaction (design-decisions.md's pessimistic-locking decision), not a single conceptual "tree" aggregate — consistent with the small, bounded (max depth 4) scale this domain operates at.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner, see docs/adr and this run's decision log
- [x] Approved to proceed to API/Database/Event Design Agents
