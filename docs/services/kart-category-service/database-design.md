---
doc_type: database-design
service: kart-category-service
status: pending-approval
generated_by: database-design-agent
source: docs/services/kart-category-service/requirement-spec.md, docs/services/kart-category-service/edge-cases.md, docs/services/kart-category-service/design-decisions.md, docs/services/kart-category-service/architecture.md, docs/adr/0011-category-read-model-scope.md, docs/adr/0010-admin-service-scope-and-integration.md, docs/adr/0004-analytics-full-fanin-ingestion.md, docs/adr/0008-event-catalog-completeness-round-2.md
---

# Database Design: kart-category-service

No `ddd-model.md` exists for this service yet, matching the precedent already recorded in `kart-admin-service/database-design.md` and `kart-analytics-service/database-design.md`. Category's domain shape is narrow enough to design directly from its own approved `requirement-spec.md`/`edge-cases.md`, `design-decisions.md`, `architecture.md`, and the three ADRs that fix its edges: there is exactly one aggregate root — **Category** (a taxonomy node: id, name, parent, hierarchy position, status) — and no second aggregate. Product, Coupon, and user-identity data are explicitly out of scope (requirement-spec §4, ADR-0010): Category never stores a local copy of another service's domain data, and no other service (including Admin) ever writes to Category's own tables directly.

**Flag (same pattern already noted in `kart-analytics-service/database-design.md`):** `architecture.md` and `design-decisions.md` still carry unchecked sign-off checkboxes (frontmatter `status: pending-approval` / `proposed`), while `requirement-spec.md` and `edge-cases.md` are fully closed (`status: approved`). Their content is internally consistent with the now-closed requirement-spec/edge-cases and raises no open question blocking this stage — this design derives directly from their already-decided content (write-through Redis cache, pessimistic locking for hierarchy mutations, transactional Outbox, synchronous Admin-to-Category REST) rather than re-deciding anything. Re-confirm against those two docs once a human checks their sign-off boxes; no substantive rework is expected.

Write model is **PostgreSQL** (source of truth), a single table plus its Outbox. **No MongoDB read model** — ADR-0011 settles that Category is served directly from PostgreSQL; the CQRS split Product/Search need does not apply here because Category's own data volume (a tree of departments/categories/subcategories, not a per-SKU record) is orders of magnitude smaller than the 100M-SKU cardinality that motivates Product's/Search's Mongo read side. The read-path latency budget (P95 < 150ms / P99 < 400ms, requirement-spec §3) is met with PostgreSQL read replicas plus a **write-through Redis cache** in front of `/categories` (`design-decisions.md`, "Caching Strategy for the `/categories` Read Path") — described below as a cache, not a rebuildable projection, since ADR-0011 explicitly rules out a second, Mongo-backed store for this service.

## Write Model (PostgreSQL)

```sql
-- Category taxonomy node — the service's one aggregate root (requirement-spec §2, §4).
-- Materialized-path storage (ancestor_path) so a read never pays for a recursive walk
-- (requirement-spec §2, §4; edge-cases.md "Unbounded hierarchy depth degrades navigation
-- read latency"). category_id is never reassigned or reused (requirement-spec §4 — it is
-- the MongoDB sharding key Product/Search use downstream), so a self-referencing FK on
-- parent_id is safe: a parent row is never physically removed, only soft-deprecated.
CREATE TABLE categories (
    category_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name            TEXT NOT NULL,
    parent_id       UUID NULL REFERENCES categories (category_id),
                            -- NULL = depth-1 (top-level department); non-NULL for every deeper node
    ancestor_path   UUID[] NOT NULL DEFAULT '{}',
                            -- ordered root-to-immediate-parent ancestor ids; empty for a depth-1 node.
                            -- This is the materialized path requirement-spec §4 requires: reading a
                            -- category's full ancestor chain (breadcrumb) or checking "is X an ancestor
                            -- of Y" is an array lookup, never a recursive CTE.
    depth           SMALLINT NOT NULL,
                            -- redundant with ancestor_path's length, kept as its own column so the
                            -- max-depth-4 invariant (requirement-spec §4) is a cheap indexed CHECK/filter
                            -- rather than an array_length() computed on every read.
    status          TEXT NOT NULL DEFAULT 'active'
                            CHECK (status IN ('active', 'deprecated')),
                            -- soft-delete only, id never physically removed or reused (requirement-spec
                            -- §4; edge-cases.md "Deleting a category that still has products assigned" —
                            -- chosen: soft-delete, because category_id is the Product/Search shard key)
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

    CHECK (depth BETWEEN 1 AND 4),
                            -- requirement-spec §4 Domain Invariant: "Maximum hierarchy depth is 4 levels"
    CHECK (depth = COALESCE(array_length(ancestor_path, 1), 0) + 1),
                            -- keeps depth and ancestor_path from drifting apart; both are written together
                            -- by the same application-level create/move transaction
    CHECK (parent_id IS DISTINCT FROM category_id)
                            -- trivial single-hop guard only; this is defense-in-depth, not the invariant
                            -- itself — the actual "no cycles" check (edge-cases.md, "Circular category
                            -- reference on re-parent") is the application-level ancestor-chain walk
                            -- described under Indexing Rationale below, run inside a SELECT ... FOR UPDATE
                            -- transaction per design-decisions.md's "Concurrency Control for Hierarchy
                            -- Mutations" decision, per the DDD standard that invariants are enforced in
                            -- domain code, not left to a single edge-case CHECK constraint
);

-- "List active children of X" — the traversal every navigation-tree render and every admin
-- move/breadcrumb screen runs, and the query a Redis cache miss falls back to.
CREATE INDEX idx_categories_parent_status
    ON categories (parent_id, status);

-- "Give me the full active tree, ordered top-down" — what a full cache warm/rebuild of the
-- write-through Redis cache (design-decisions.md) or a Postgres-replica fallback read runs,
-- without a recursive query (requirement-spec §4).
CREATE INDEX idx_categories_status_depth
    ON categories (status, depth);

-- Backs the cycle check itself: "is the category being moved (X) already an ancestor of the
-- proposed new parent (P)?" is `X.category_id = ANY(P.ancestor_path)` — a GIN index makes this
-- an index lookup, not a per-row scan, even as the taxonomy grows (edge-cases.md, "Circular
-- category reference on re-parent").
CREATE INDEX idx_categories_ancestor_path
    ON categories USING GIN (ancestor_path);

-- Transactional Outbox for CategoryUpdated (design-decisions.md, "Reliable Event Publication
-- for CategoryUpdated"): one row per create/rename/move/deprecate; one coarse row per subtree
-- move (edge-cases.md, "Subtree re-parenting invalidates downstream category data"), not one
-- per descendant. Written in the same transaction as the categories write it describes.
CREATE TABLE category_outbox_events (
    outbox_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    category_id     UUID NOT NULL REFERENCES categories (category_id),
                            -- the category itself (create/rename/deprecate), or the moved subtree's
                            -- root (move) — matches the "one coarse event per subtree move" decision
    event_type      TEXT NOT NULL DEFAULT 'CategoryUpdated',
                            -- a single value today; kept as a column (not hardcoded downstream) in case
                            -- a second Category-owned event type is added later
    payload         JSONB NOT NULL,
                            -- BRD §10 (as amended by ADR-0004/ADR-0008) fixes the confirmed payload as
                            -- {categoryId, name} today; JSONB lets the Event Design Agent grow this
                            -- (e.g. a path/parentId field for subtree-move consumers, requirement-spec
                            -- §5) without a schema migration
    occurred_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    published_at    TIMESTAMPTZ NULL
                            -- set only by the Outbox relay after a successful publish to
                            -- ecommerce.events with the 3x retry / catalog.dlq policy (BRD §10, ADR-0008)
);

-- The relay's own scan: "find everything not yet published, oldest first" — same pattern as
-- kart-admin-service's idx_admin_actions_unpublished and kart-analytics-service's
-- idx_analytics_dlq_events_pending.
CREATE INDEX idx_category_outbox_unpublished
    ON category_outbox_events (occurred_at)
    WHERE published_at IS NULL;
```

## Read Model / Cache (Redis)

Not a MongoDB read model (ADR-0011) and not a rebuildable CQRS projection with its own consumer — a **write-through cache** in front of PostgreSQL, per `design-decisions.md`'s "Caching Strategy for the `/categories` Read Path" decision. A cache miss falls back to the PostgreSQL read replica via `idx_categories_parent_status` / `idx_categories_status_depth` above, so Redis availability is a latency, not a correctness, dependency — consistent with ADR-0011's "strong, read-your-write within Category's own PostgreSQL store" consistency target.

- `category:children:{parentId}` (sentinel `root` for depth-1 nodes) → ordered JSON array of child summaries `{id, name, hasChildren}`, backing the primary `/categories` navigation read.
- `category:node:{categoryId}` → JSON detail `{id, name, parentId, ancestorPath, depth, status}`, backing breadcrumb/single-node reads.
- **Every** taxonomy write (create/rename/move/deprecate) updates the affected entries synchronously, in the same operation as the PostgreSQL write — not a bare TTL-expiry or invalidate-then-repopulate-on-next-read (`design-decisions.md`). A create/rename/deprecate touches its own `category:node:{id}` entry and its parent's `category:children:{parentId}` entry; a subtree move additionally updates `category:node:{id}` for every descendant whose `ancestorPath` changed, plus the old-parent and new-parent `category:children` entries — this is an application-level loop over the moved subtree (bounded by the max-depth-4 invariant), not a per-descendant `CategoryUpdated` event fan-out (edge-cases.md already fixes the event itself as one coarse row per move; the cache update is a separate, synchronous mechanism this stage owns).

## Indexing Rationale

| Index | Query it supports | Why needed |
|---|---|---|
| `categories` PK on `category_id` | Direct node lookup by id; FK target for `parent_id` and `category_outbox_events.category_id` | Standard PK access path; `category_id` is also the stable identifier Product/Search shard on downstream (requirement-spec §4), so it is never reassigned |
| `idx_categories_parent_status` | "List active children of X" — navigation-tree traversal and cache-miss fallback for `category:children:{parentId}` | The read-path latency NFR (P95 < 150ms, requirement-spec §3) requires this be an index lookup, not a per-render table scan, on every cache miss |
| `idx_categories_status_depth` | "Give me the full active tree, top-down" — cache warm/rebuild and full-listing fallback | Avoids a recursive query entirely (requirement-spec §4's materialized-path rationale); a status+depth scan replaces the recursive walk edge-cases.md's "Unbounded hierarchy depth..." decision explicitly rejected |
| `idx_categories_ancestor_path` (GIN) | The cycle check on every create/move: "is the node being moved already an ancestor of its proposed new parent?" | Backs edge-cases.md's "Circular category reference on re-parent" decision (synchronous ancestor-chain check at write time) with an index lookup instead of a per-row scan, run inside the `SELECT ... FOR UPDATE` transaction design-decisions.md's concurrency-control decision fixes |
| `idx_category_outbox_unpublished` (partial, `published_at IS NULL`) | The Outbox relay's "find rows not yet published" scan | Standard Outbox mechanics (design-decisions.md, "Reliable Event Publication for `CategoryUpdated`"); keeps the relay a cheap partial-index scan rather than a full-table scan |

## Partitioning/Sharding

Not needed. A general e-commerce taxonomy bounded to 4 levels (department → category → subcategory → sub-subcategory) is, by construction, thousands of nodes at most — orders of magnitude below the 100M-SKU cardinality (BRD §4.1) that is ADR-0011's own stated reason Product and Search need a sharded MongoDB read side. Category's own write volume is low and RBAC-gated/admin-driven (requirement-spec §4, design-decisions.md), not a customer-facing hot path. Single-table PostgreSQL, with the indexes above and a read replica for the `/categories` fallback path, is sufficient at current scale; `category_id` remains the *value* Product's and Search's own MongoDB collections shard on, but Category's own PostgreSQL table is never itself sharded on it.

## Sign-off

- [ ] Reviewed by: _pending human review_
- [ ] Approved (write-model schema)
