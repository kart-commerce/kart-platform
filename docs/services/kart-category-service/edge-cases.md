---
doc_type: edge-cases
service: kart-category-service
status: pending-approval
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
  - Trade-off accepted: write-path latency grows with hierarchy depth — bounded only once a max-depth is set (requirement-spec §6, Open Question 1, still unresolved).

## Edge Case: Subtree re-parenting invalidates downstream category data

- **What happens:** Moving a subtree changes the effective ancestor path for every descendant category, but Product's embedded `category: {id, name}` field and Search's category facets keep serving the pre-move view.
- **Why it happens:** The BRD names no consumer for `CategoryUpdated` at all (requirement-spec §6, Open Question 3), so there is no defined propagation path today — and even once one exists, a subtree move affects N descendants, not one, which a single per-entity event model doesn't cleanly cover.
- **Solutions available (3):** Fan out one `CategoryUpdated`-style event per affected descendant · Publish one coarse event describing the moved subtree root/path and let consumers resolve the affected range themselves · Rely on cache TTL alone, no explicit invalidation.
- **Decision (3-5 bullets max):**
  - Chosen: One coarse event per subtree move, not per-descendant fan-out.
  - Why: per-descendant fan-out on a large subtree move can emit a burst disproportionate to one logical operation; the platform's own RabbitMQ topology notes fan-out throughput as a known limitation (kart-requirements.md §14).
  - Trade-off accepted: consumers (Product, Search) must resolve "what changed under this path" themselves rather than being told each affected entity directly.
  - Unresolved: which service(s) actually consume this event is still Open Question 3 in the requirement-spec — this decision fixes the event's shape, not its wiring.

## Edge Case: Deleting a category that still has products assigned

- **What happens:** A category is deleted while products still reference its id, orphaning those products' navigation/facet path.
- **Why it happens:** The requirement-spec (§6, Open Question 2) leaves product-category cardinality and reassignment rules unstated, so deletion has no contractually correct behavior defined.
- **Solutions available (3):** Soft-delete only — the id is marked deprecated/inactive and never physically removed · Hard block — the delete API rejects the operation while any product still references the category · Cascade — deletion emits a required-reassignment event that Product must handle (e.g. fallback to parent or "uncategorized").
- **Decision (3-5 bullets max):**
  - Chosen: Soft-delete with a deprecated/inactive state; the id is never physically removed or reused.
  - Why: `category.id` is the MongoDB sharding key for the Product and Search collections (requirement-spec §4, inferred invariant); physically removing or reusing an id would misroute already-sharded data.
  - Trade-off accepted: deprecated categories linger in the taxonomy indefinitely, adding a status filter to every taxonomy read.

## Edge Case: Taxonomy write vs. Search facet staleness

- **What happens:** A category is renamed or moved, but Search continues to facet/filter on the old name/path for some window afterward.
- **Why it happens:** Search is fed asynchronously via the Outbox/event pipeline (kart-requirements.md §7, §17), and the BRD gives Category no stated consistency target of its own (requirement-spec §3, Consistency row — "not stated specifically for Category").
- **Solutions available (2):** Treat category propagation to Search with the same seconds-scale eventual-consistency budget the BRD already sets for Product→Search (§2.2 domain rule) · Require synchronous, read-your-write consistency for category facets specifically, since a wrong navigation label is more visibly wrong than a stale price.
- **Decision (3-5 bullets max):**
  - Chosen: Eventual consistency, same seconds-scale budget as the existing Product→Search precedent.
  - Why: the BRD already accepts this exact trade-off for catalog data reaching Search; nothing in the requirement-spec marks category data as more consistency-sensitive than product price.
  - Trade-off accepted: a customer can briefly see a stale category name/facet immediately after an admin renames or moves a category.

## Edge Case: Unbounded hierarchy depth degrades navigation read latency

- **What happens:** A category tree with no enforced depth limit accumulates an unusually long chain, and a breadcrumb/subtree navigation read becomes an expensive recursive walk.
- **Why it happens:** No maximum depth is stated (requirement-spec §6, Open Question 1), yet `/categories` navigation reads carry the P95 < 150ms read-path latency NFR (requirement-spec §3) — an unbounded recursive walk breaks that budget as depth grows.
- **Solutions available (3):** Enforce a hard max-depth at write time, rejecting a create/move that would exceed it · Store a materialized path or ancestor array per category so reads are O(1) regardless of depth · No enforced limit, rely on caching to hide the cost.
- **Decision (3-5 bullets max):**
  - Chosen: Enforce a hard max-depth at write time, and store a materialized path for reads.
  - Why: the latency NFR is a stated external commitment; depth validation is cheap at write time (rare) versus paying an unbounded cost on every read (frequent, per the read-heavy classification in requirement-spec §3).
  - Trade-off accepted: this fixes the *mechanism* only — the actual maximum-depth number is still Open Question 1 in the requirement-spec, unresolved here.
