---
doc_type: edge-cases
service: kart-category-service
status: approved
generated_by: edge-case-analyzer-agent
source: docs/services/kart-category-service/requirement-spec.md
---

# Edge Cases: kart-category-service

## Edge Case: Circular category reference on re-parent

- **What happens:** A category is re-parented onto one of its own descendants, creating a cycle in what must be a tree.
- **Why it happens:** A parent-change write validates only the immediate new-parent edge, not the full ancestor chain, so a single move (or a racing pair of moves) can introduce a cycle undetected (requirement-spec §4, Domain Invariant: no cycles).
- **Solutions available (3):** Synchronous ancestor-chain walk on every parent-change, rejecting if the new parent is already a descendant · Materialized-path/nested-set model so cycle detection is a query, not a walk · Periodic offline audit job that detects cycles after the fact.
- **Decision (3-5 bullets max):**
  - Chosen: Synchronous ancestor-chain check at write time.
  - Why: hierarchy well-formedness is the stated core responsibility (requirement-spec §2, "hierarchy"); validation must block the write, not catch it later.
  - Trade-off accepted: write-path latency grows with hierarchy depth — now bounded by the max-depth limit of 4 levels fixed in requirement-spec §4, so the ancestor-chain walk is capped at a small, constant number of hops regardless of taxonomy size.

## Edge Case: Subtree re-parenting invalidates downstream category data

- **What happens:** Moving a subtree changes the effective ancestor path for every descendant category, but Product's embedded `category: {id, name}` field and Search's category facets keep serving the pre-move view.
- **Why it happens:** `CategoryUpdated`'s only confirmed consumer is Analytics (BRD §10, as amended by ADR-0004/ADR-0008); Product and Search each hold their own denormalized copy of category data but neither is a wired consumer of this event today (requirement-spec §2) — so there is no defined propagation path to the services that actually render navigation/facets, and even once one exists, a subtree move affects N descendants, not one, which a single per-entity event model doesn't cleanly cover.
- **Solutions available (3):** Fan out one `CategoryUpdated`-style event per affected descendant · Publish one coarse event describing the moved subtree root/path and let consumers resolve the affected range themselves · Rely on cache TTL alone, no explicit invalidation.
- **Decision (3-5 bullets max):**
  - Chosen: One coarse event per subtree move, not per-descendant fan-out.
  - Why: per-descendant fan-out on a large subtree move can emit a burst disproportionate to one logical operation; the platform's own RabbitMQ topology notes fan-out throughput as a known limitation (kart-requirements.md §14).
  - Trade-off accepted: consumers (Product, Search) must resolve "what changed under this path" themselves rather than being told each affected entity directly.
  - Carried forward (non-blocking): whether Product and/or Search wire themselves up as live consumers of this event, versus relying on the eventual-consistency staleness window budgeted below in "Taxonomy write vs. Search facet staleness," is each of those services' own future call per ADR-0008's stated scope boundary, not something Category's docs resolve unilaterally — this decision fixes the event's shape, not its downstream wiring.

## Edge Case: Deleting a category that still has products assigned

- **What happens:** A category is deleted while products still reference its id, orphaning those products' navigation/facet path.
- **Why it happens:** Product-category cardinality is many-to-one — exactly one primary category per product (requirement-spec §4) — so deleting a category a product still references leaves that product with no valid category pointer at all, not merely a stale secondary tag.
- **Solutions available (3):** Soft-delete only — the id is marked deprecated/inactive and never physically removed · Hard block — the delete API rejects the operation while any product still references the category · Cascade — deletion emits a required-reassignment event that Product must handle (e.g. fallback to parent or "uncategorized").
- **Decision (3-5 bullets max):**
  - Chosen: Soft-delete with a deprecated/inactive state; the id is never physically removed or reused.
  - Why: `category.id` is the MongoDB sharding key for the Product and Search collections (requirement-spec §4, inferred invariant); physically removing or reusing an id would misroute already-sharded data.
  - Trade-off accepted: deprecated categories linger in the taxonomy indefinitely, adding a status filter to every taxonomy read.

## Edge Case: Taxonomy write vs. Search facet staleness

- **What happens:** A category is renamed or moved, but Search continues to facet/filter on the old name/path for some window afterward.
- **Why it happens:** Search is fed asynchronously via the Outbox/event pipeline (kart-requirements.md §7, §17). Category's own consistency target is now fixed (requirement-spec §3, per ADR-0011 (`docs/adr/0011-category-read-model-scope.md`)) as strong, read-your-write within Category's own PostgreSQL store — but that ADR explicitly places any customer-visible staleness in Product's and Search's own downstream denormalized copies, once those are wired. This edge case is that downstream staleness window, not a gap in Category's own consistency story.
- **Solutions available (2):** Treat category propagation to Search with the same seconds-scale eventual-consistency budget the BRD already sets for Product→Search (§2.2 domain rule) · Require synchronous, read-your-write consistency for category facets specifically, since a wrong navigation label is more visibly wrong than a stale price.
- **Decision (3-5 bullets max):**
  - Chosen: Eventual consistency, same seconds-scale budget as the existing Product→Search precedent.
  - Why: the BRD already accepts this exact trade-off for catalog data reaching Search; nothing in the requirement-spec marks category data as more consistency-sensitive than product price.
  - Trade-off accepted: a customer can briefly see a stale category name/facet immediately after an admin renames or moves a category.

## Edge Case: Unbounded hierarchy depth degrades navigation read latency

- **What happens:** A category tree with no enforced depth limit accumulates an unusually long chain, and a breadcrumb/subtree navigation read becomes an expensive recursive walk.
- **Why it happens:** Without an enforced bound, a category tree can accumulate an arbitrarily long chain even though `/categories` navigation reads carry the P95 < 150ms read-path latency NFR (requirement-spec §3) — an unbounded recursive walk breaks that budget as depth grows. Requirement-spec §4 now fixes the bound at 4 levels precisely to close this failure mode.
- **Solutions available (3):** Enforce a hard max-depth at write time, rejecting a create/move that would exceed it · Store a materialized path or ancestor array per category so reads are O(1) regardless of depth · No enforced limit, rely on caching to hide the cost.
- **Decision (3-5 bullets max):**
  - Chosen: Enforce a hard max-depth at write time, and store a materialized path for reads.
  - Why: the latency NFR is a stated external commitment; depth validation is cheap at write time (rare) versus paying an unbounded cost on every read (frequent, per the read-heavy classification in requirement-spec §3).
  - Trade-off accepted: resolved — requirement-spec §4 fixes the maximum-depth number at 4 levels (department → category → subcategory → sub-subcategory), consistent with typical e-commerce taxonomy depth; a taxonomy that genuinely needs a 5th level (rare in general e-commerce) would require this limit to be revisited.
