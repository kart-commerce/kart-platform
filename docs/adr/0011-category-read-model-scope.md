---
doc_type: adr
status: accepted
---

# ADR-0011: Category Is Served Directly from PostgreSQL — No Separate MongoDB Read Model

## Status

Accepted

## Context

Two BRD sections disagree about whether Category has a denormalized read-side store at all:

- BRD §5.4's condensed service table gives Category's database as `PostgreSQL` only — no `→ MongoDB read` arrow. The same table gives Product, User, and Review an explicit `PostgreSQL → MongoDB read` notation for exactly this CQRS split, so the arrow's absence for Category is a stated distinction, not an omission of detail.
- BRD §6.1's "Read-Heavy vs Write-Heavy" table lists `Product, Search, Category` together as "Read-heavy," with the shared reasoning "Millions of reads per write → MongoDB/denormalized is source of truth for reads" — which read literally, claims Category also has a MongoDB-backed read side.
- BRD §6.2's only worked example of the denormalized read model (`product_read_model`) embeds `category: { id, name }` as a field *inside Product's own* MongoDB document, and states `category.id` is the **sharding key** for the Product and Search collections — i.e., Category's identifier is consumed by other services' read models, but no `category_read_model` collection of Category's own is ever shown or named anywhere in the BRD.

This is a genuine BRD self-contradiction (§5.4 vs §6.1), the same kind ADR-0002/ADR-0005/ADR-0007/ADR-0008 already resolved elsewhere by picking the more specific, detailed source over the more generic one. It is not covered by any existing ADR: ADR-0001–0009 address the Offer merge, Order-Shipping async integration, Notification's consumed-event scope, Analytics fan-in, the Order terminal event, the Identity/User boundary, two event-catalog completeness passes, and Order-Inventory sync scope — none of them touch Category's data-store topology. It blocks `kart-category-service/requirement-spec.md` sign-off because the answer determines the service's CQRS shape (one store vs. two), its consistency NFR, and whether a MongoDB replica set/shard needs to be provisioned for it at all.

## Decision

**Category is served directly from PostgreSQL. It does not maintain a separate MongoDB denormalized read model.** §5.4's per-service table is treated as the more reliable source where it conflicts with §6.1's grouping, for the same reason ADR-0008 preferred §10 over §5.4's "Product Consumes: —" on the Review question: the specific, itemized row is more authoritative than the general grouping when the two disagree, and no worked example anywhere in the BRD (§6.2 or elsewhere) ever shows a `category_read_model` collection.

§6.1's "Read-heavy" classification for Category is read as describing **traffic shape** (many navigation reads per taxonomy write), not a claim that Category adopts the same Postgres-write/Mongo-read CQRS split that Product and Search need. The two services that do need that split (Product, Search) both operate at 100M-SKU cardinality (BRD §4.1) where cross-shard joins are prohibitively expensive — the BRD's own stated reason to denormalize (§6.2: "MongoDB has no cross-shard joins; embedding trades storage/staleness for read latency"). A category taxonomy is orders of magnitude smaller (a tree of departments/categories/subcategories, not a per-SKU record), so the read-path latency NFR (P95 < 150ms, requirement-spec §3) is achievable with PostgreSQL read replicas plus an application-level or Redis cache in front of `/categories`, without paying for a second datastore, a sharding scheme, and an Outbox-fed sync pipeline that its data volume doesn't warrant.

Category remains the upstream source of `category.id`/`category.name` that Product and Search denormalize into *their own* read models (BRD §6.2) — this decision does not change that relationship, only confirms that the copy lives on Product's and Search's side, not on a Category-owned Mongo collection.

## Consequences

- `kart-category-service`'s Consistency NFR is: strong read-after-write within Category's own PostgreSQL (no replication lag to a second store to reason about), with any staleness customers might observe in navigation living entirely downstream, in Product's and Search's own denormalized copies once those exist — that staleness is already covered by the Product→Search eventual-consistency precedent (BRD §2.2) and by this service's own edge-cases.md ("Taxonomy write vs. Search facet staleness").
- No MongoDB replica set/shard needs to be provisioned for Category — this is a real infrastructure/capacity-planning simplification for the Architecture Agent, not just a documentation fix.
- If taxonomy read traffic or depth ever grows enough that PostgreSQL + caching can't hold the latency budget, revisiting this decision (introducing a Category-owned read model) is expected to be a future architecture-agent-level trade-off, not a permanent foreclosure — the same "revisit later if warranted" posture ADR-0001 already takes for Offer's aggregate split.
- `kart-category-service/requirement-spec.md`'s NFR table and Open Question #4 are resolved by this ADR; no other service's approved docs need to change (Product's and Search's own read-model descriptions already only ever described their *own* collections embedding category data, never a Category-owned one).
