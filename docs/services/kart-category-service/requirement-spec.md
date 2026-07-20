---
doc_type: requirement-spec
service: kart-category-service
status: approved
generated_by: requirement-agent
source: docs/requirements/kart-requirements.md
---

# Requirement Spec: kart-category-service

## 1. Scope

Covers the single BRD service **Category** (BRD §2.1 item 4: "Taxonomy, hierarchy, navigation"). No merge, no ADR — this is a standalone bounded context.

The BRD's treatment of Category is minimal: one core-modules row (§2.1), one condensed API/DB/events row (§5.4), and a handful of incidental mentions elsewhere (§6.1, §6.2, §17) where other services reference category data rather than describe Category's own behavior. This spec does not fill those gaps with invented requirements; gaps are named explicitly in §6.

## 2. Functional Requirements

- Maintain the category taxonomy — the set of category entities and their attributes (BRD §2.1 item 4: "Taxonomy").
- Maintain parent-child hierarchical relationships between categories (BRD §2.1 item 4: "hierarchy"). The BRD does not state a maximum tree depth or whether a category may have more than one parent — see Open Questions.
- Serve category data to support site navigation via `GET /categories` (BRD §5.4: "navigation" responsibility, API surface row). The BRD gives no HTTP method or request/response shape — read-only listing is assumed, not stated.
- Publish `CategoryUpdated` when category data changes (BRD §5.4). The BRD does not state which operations trigger it (create/rename/move/delete) or its payload — see Open Questions.
- Category data is a dependency of two other services, per incidental BRD mentions, though the BRD does not describe the mechanism connecting them to Category:
  - Product's denormalized MongoDB read model embeds `category: { id, name }` per product (BRD §6.2 example) and uses `category.id` as the MongoDB sharding key for the Product and Search collections (BRD §6.2).
  - Search facets/filters on category (BRD §17: "faceted aggregations on category, price range, and rating").
  - See Open Questions — the BRD does not name any consumer of `CategoryUpdated`, including these two.

## 3. Non-Functional Requirements

Pulled from the BRD's global NFR table (§3), scoped to this service:

| Attribute | Target | Applies here because |
|---|---|---|
| Availability | 99.9% (secondary path) | Category is absent from the Order Saga path and the service-boundary diagram's message-bus fan-out (§5.5) — nothing in the BRD places it on the 99.99% critical-path tier |
| Latency | P95 < 150ms, P99 < 400ms (read path) | `/categories` is a read endpoint; §6.1 explicitly groups Category with Product and Search as "Read-Heavy" services on the global read-path budget |
| Consistency | Not stated specifically for Category | §2.2's domain rule ("Search must reflect catalog changes within seconds, not milliseconds") is the closest BRD analog, since Category feeds Search facets and Product's embedded category field, but the BRD never states this rule applies to Category — see Open Questions |
| Reliability | At-least-once delivery + idempotent consumers | This is the BRD's blanket NFR (§3) for all messaging; applies to `CategoryUpdated` publication if/when a consumer is defined |
| Retry/DLQ | Not specified | `CategoryUpdated` does not appear in the BRD's Event Catalog (§10) at all, unlike every other named event in that table — see Open Questions |

## 4. Domain Invariants

- A category must not be its own ancestor (no cycles) — not stated explicitly by the BRD, but inferred from the stated responsibility itself: a structure described as a "hierarchy" (BRD §2.1 item 4) is not well-formed if it contains a cycle.
- Category identifiers, once assigned, should remain stable rather than being reassigned or reused — inferred from `category.id` serving as the MongoDB sharding key for the Product and Search collections (BRD §6.2); reassigning an id would misroute already-sharded data. The BRD does not state this as a rule; it is a consequence of the sharding-key mention.
- Beyond these two inferred structural invariants, the BRD states no business rules for Category (no oversell-style or double-charge-style rule as it does for Inventory/Payment at §2.2). Do not treat this spec's silence elsewhere as permission to invent rules the BRD doesn't support.

## 5. API Surface (from BRD, starting point only)

| Endpoint/Event | Direction | Notes |
|---|---|---|
| `/categories` | Inbound API | BRD §5.4; no HTTP method stated |
| `CategoryUpdated` | Published | BRD §5.4; no consumer named anywhere in the BRD (§5.4's Consumed columns for other services, and §10's Event Catalog, both omit it) — see Open Questions |

Final contract is the API Design Agent's job, not this spec's.

## 6. Open Questions / Flagged Ambiguities

1. **Tree depth limits** — the BRD does not state a maximum hierarchy depth. Materially affects the data model (recursive vs. materialized-path storage) and the read-path latency NFR (§3) as depth grows.
2. **Product-category cardinality** — can a product belong to more than one category, or exactly one? The Product read-model JSON example (BRD §6.2) shows a single `category: { id, name }` object, but that example is illustrative of denormalization, not a stated cardinality constraint. This directly affects Category's deletion/reassignment rules and Product Service's schema.
3. **`CategoryUpdated` has no stated consumer.** BRD §5.4 lists it as published by Category, but the Event Catalog (§10) omits it entirely, and neither Product's nor Search's Consumed column (§5.4) names it — even though Product embeds category name/id (§6.2) and Search facets on category (§17). The BRD does not describe how either dependent stays in sync with taxonomy changes.
4. **Read-model contradiction.** §6.1's "Read-Heavy vs Write-Heavy" table places Category among read-heavy services alongside Product and Search, stating "MongoDB/denormalized is source of truth for reads" for that group. But §5.4's per-service table lists Category's database as `PostgreSQL` only, without the `→ MongoDB read` notation given to Product, User, and Review in that same table. The BRD contradicts itself on whether Category has a read-side store at all.
5. **`CategoryUpdated` retry/DLQ policy is unspecified.** Every other named event in the BRD's Event Catalog (§10) has a retry count and DLQ target; `CategoryUpdated` isn't in that table to begin with. Carried to the Event Design Agent stage once (or if) a consumer is confirmed per Q3.
6. **Write-path ownership is unclear.** The BRD shows `/categories` with no method and no create/update/delete/move operations, while a separate Admin Service exposes RBAC-gated `/admin/*` endpoints (§5.4). The BRD does not say whether taxonomy curation happens through Category's own write API or is proxied through Admin.

## Sign-off

- [ ] Blocking open questions resolved
- [ ] Reviewed by:
- [ ] Approved to proceed to Architecture Agent
