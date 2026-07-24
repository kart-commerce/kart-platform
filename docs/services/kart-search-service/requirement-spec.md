---
doc_type: requirement-spec
service: kart-search-service
status: approved
generated_by: requirement-agent
source: docs/requirements/kart-requirements.md
---

# Requirement Spec: kart-search-service

## 1. Scope

Covers a single BRD service: **Search** (BRD §2.1 item 5, "Full-text search, filters, facets, ranking"). No merge with another BRD service applies here — unlike Offer, Search maps 1:1 onto one bounded context, so no ADR is required to justify scope.

Search is a **read-only, query-side** service: it owns no write model of its own and publishes no events (BRD §5.4 lists no "Events Published" for Search). Its entire job is projecting catalog state into a queryable index.

## 2. Functional Requirements

- Serve full-text product search (`GET /search`, query-only, BRD §5.4).
- Support filters and faceted aggregations on category, price range, and rating, computed server-side rather than over-fetching and filtering client-side (BRD §17).
- Rank results by a blend of textual relevance and business signals: rating, in-stock status, and a "sponsored placement" boost (BRD §17). The BRD does not specify the weighting/algorithm for this blend — see Open Questions.
- Run a multi-match query across name/description/brand fields, boosting exact SKU/brand matches (BRD §17).
- Consume `ProductCreated` to add new products to the index (BRD §5.4).
- Consume `ProductPriceChanged` to keep indexed price current (BRD §5.4).
- Consume `ProductDiscontinued` to remove a product from active search results (soft-remove: mark the indexed document unavailable/excluded from default query results rather than hard-deleting it, consistent with how `ProductCreated`/`ProductPriceChanged` are applied as upserts). This event is a proposed addition owned by `kart-product-service` (not yet in the BRD's own Event Catalog §10) — see `kart-product-service/requirement-spec.md` and its `edge-cases.md`'s "Discontinued/orphaned variant" edge case, which names Search's Open Question #4 (below, now resolved) as one of the two downstream consumers this event was proposed to unblock. Formal payload/schema is the Event Design Agent's job once `ProductDiscontinued` is formalized platform-wide; Search's own follow-up commitment is to consume it and treat it as a removal signal, not a price/attribute update.
- Maintain the search index as a sibling of the MongoDB product read model, fed independently from the same Outbox/event pipeline — not derived from or dependent on the MongoDB read model (BRD §17).

## 3. Non-Functional Requirements

Pulled from the BRD's global NFR table (§3) and the Search-specific forced decision at §2.2, scoped to this service:

| Attribute | Target | Applies here because |
|---|---|---|
| Availability | 99.9% (secondary path) | BRD's 99.99% tier is explicitly scoped to "order path" (§3); Search is not on the Order Saga's critical path (§5.5 shows Search only as a Bus fan-out consumer, not a Saga participant) |
| Latency | P95 < 150ms, P99 < 400ms (read path) | `/search` is a pure read/query endpoint (§3 read-path row; §5.4 marks it "query only") |
| Consistency | Eventual, with a named bound: "within seconds, not milliseconds" (BRD §2.2), concretized as **P95 index-catch-up lag < 5s, P99 < 15s**, measured from source event publish (Outbox insert) to the document being searchable in OpenSearch | This is a BRD-named forced decision specific to Search, distinct from the generic "Eventual (MongoDB/read path)" NFR row — the BRD gives Search a stricter freshness bar than other read-side services get by default. The BRD names the bound ("seconds, not milliseconds") but not a number; the concrete P95/P99 figures are this spec's own engineering default (Decision, not an open question — see Open Questions §6 item 1), chosen to sit comfortably inside "seconds" while leaving headroom for consumer-lag spikes under the 100M-SKU/high-throughput load in §4.1 |
| Reliability | At-least-once delivery + idempotent consumers | Applies to `ProductCreated`/`ProductPriceChanged` consumption (BRD NFR §3, Reliability row) |
| Retry/DLQ | 3x retry, `catalog.dlq` (BRD §10, both `ProductCreated` and `ProductPriceChanged` rows) | Catalog/search events are explicitly called out as tolerating looser retry than money-moving events (BRD §10 footnote) — consistent with Search's read-only, eventually-consistent nature |
| Throughput | Read:write ratio ≈ 20:1 platform-wide (§4.4); catalog is 100M SKUs (§4.1) | Search sits on the high-read side of that ratio; index must serve high query volume against a large catalog |

**Cross-cutting Security obligations added by BRD §24.1.2, §24.1.4, §24.1.5, §24.3 (cross-reference only — the detailed "why" lives in the BRD itself and in this service's own ddd-model.md/database-design.md, not re-derived here):**

- **§24.1.2 (CanRead/CanWrite/CanDelete, service-owned):** Search is a pure read-only, query-side service (§1 above) — it exposes no external write API of any kind (§5 API Surface lists only `GET /search`; every mutation to `SearchDocument`/`CategoryLookup` is driven internally by consuming `ProductCreated`/`ProductPriceChanged`/`ProductUpdated`/`ProductDiscontinued`/`CategoryUpdated`/`ReviewSubmitted`/`ReviewUpdated`, never a caller-invoked write). `CanRead` on `GET /search` is therefore an unconditional grant to any principal, including unauthenticated browse traffic — a search result is public catalog data with no per-user ownership dimension, the same posture `kart-product-service`/`kart-category-service` take for their own public reads. `CanWrite`/`CanDelete` do not apply to any externally-reachable endpoint at all — the only "writes" this service ever performs are its own event-consumer projector code, not a caller-authorized action, so there is no CanWrite/CanDelete decision for an external principal to be gated by in the first place. The concrete mechanism (or rather, its inapplicability) is recorded as a Domain Invariant in ddd-model.md.
- **§24.1.4 (row-level security):** Search has no PostgreSQL write model at all (database-design.md's "Architecture Note" — OpenSearch only, a fully rebuildable projection of Product's/Category's/Review's own write sides) and no MongoDB read model either — its store is OpenSearch. Native RLS therefore has no write-side table to attach to, and even the §24.1.4 MongoDB query-builder-filter alternative does not apply in its principal-scoped-filtering sense: `search_products`/`search_category_lookup`/`search_rating_ledger` carry no per-row end-user ownership column, the same no-ownership-dimension carve-out already established for Product's/Category's own catalog tables. See database-design.md's "Row-Level Security Policy" subsection for the explicit reasoning.
- **§24.1.5 (column-level security):** No sensitive/PII columns exist. Every field on `SearchDocument`/`CategoryLookup` (`name`, `description`, `brand`, `category`, `price`, `availability`, facet attributes, `rating`) is public storefront/search content, not personal data about any individual. See database-design.md's "Sensitive / PII Column Classification" subsection.
- **§24.3 (default audit fields):** Search's OpenSearch indices are a disposable, rebuildable projection (database-design.md), not durable system-of-record tables in the sense §24.3 targets — the authoritative `created_by`/`updated_by` provenance for every field already lives in the upstream write models that originate it (`kart-product-service`, `kart-category-service`, `kart-review-service`, each independently carrying its own §24.3 audit columns). This service's own indices carry `lastCatalogEventAt`/`lastUpdatedAt` (ddd-model.md) as freshness/ordering-guard timestamps, which already serve this projection's own operational needs; adding a redundant `created_by`/`updated_by` pair to a fully rebuildable, non-authoritative index would duplicate provenance data without adding an audit guarantee the source services don't already provide. No relational/document table here is "mutable" in §24.3's sense of an authored system-of-record row.

## 4. Domain Invariants

- The search index must never depend on the MongoDB product read model being present or current — it is fed independently from the same event pipeline (BRD §17: "siblings, not dependent on each other"). A stale or down MongoDB read model must not block search indexing.
- Faceted counts returned alongside search results must reflect the same filtered result set they're presented with — not a separately-cached or stale aggregate (inferred from BRD §17's "computed server-side to avoid over-fetching," which implies facets are computed per-query, not precomputed and drifted).
- Ranking must incorporate rating, in-stock status, and sponsored placement as blended signals, not as hard filters — the BRD describes a blended score, not an exclusion rule (BRD §17). The BRD does not state what happens to out-of-stock items' relative ranking beyond "in-stock status" being one signal among several.
- Index staleness relative to the source catalog must stay within "seconds, not milliseconds" (BRD §2.2) — this is a domain-level bound, not merely an implementation detail, since the BRD calls it out as a forced consistency decision.

## 5. API Surface (from BRD, starting point only)

| Endpoint/Event | Direction | Notes |
|---|---|---|
| `GET /search` | Inbound API | Query-only per BRD §5.4; no request/response shape (query params, pagination, facet syntax) specified in the BRD |
| `ProductCreated` | Consumed | Published by Product (BRD §5.4, §10); adds new products to the index |
| `ProductPriceChanged` | Consumed | Publisher question resolved — see Open Questions §6 item 5 |
| `ProductDiscontinued` | Consumed (proposed) | Not yet a BRD §10 catalog row; proposed by `kart-product-service` to signal removal from active sale. See Open Questions §6 item 4 |

No events are published by Search (BRD §5.4 lists no outbound events) — Search is a pure consumer/query service. Final contract (query params, response shape, pagination/facet syntax) is the API Design Agent's job, not this spec's.

## 6. Open Questions / Flagged Ambiguities

All items originally listed here have been resolved or explicitly reclassified as non-blocking carry-forwards, per the closure pass run on 2026-07-21. None of the five items below are blocking sign-off.

1. **Consistency-lag SLA — resolved (engineering default).** BRD §2.2 says catalog changes must reflect "within seconds, not milliseconds" but gives no concrete bound. This is a single-service engineering default, not a cross-cutting or contradictory question, so it's decided directly here rather than escalated: **P95 index-catch-up lag < 5s, P99 < 15s**, measured Outbox-insert-to-searchable (see §3 NFR table, Consistency row). Why: sits inside the BRD's "seconds, not milliseconds" bound with margin for consumer-lag spikes; matches the platform's existing pattern of naming a concrete number for an eventual-consistency NFR rather than leaving it open (cf. BRD §3's own P95/P99 latency figures). Trade-off: this is this spec's proposed number, not a BRD-mandated one — the Architecture Agent may need to revise it once real indexing-pipeline throughput is load-tested; that revision is a normal downstream refinement of a stated baseline, not reopening an unresolved question.
2. **Ranking algorithm / relevance signal weighting — non-blocking, carried forward.** BRD §17 names the signals (textual relevance, rating, in-stock status, sponsored placement boost) but not their weights, tie-breaking order, or whether the "sponsored placement" boost is capped or auctioned. This is legitimately a product/business tuning decision, not something this spec should invent a number for — carried to the DDD/Architecture Agents to propose an initial scoring formula, and to Product/Business stakeholders for the sponsored-placement policy specifically (capped vs. auctioned has revenue-model implications outside engineering's remit). This does not block sign-off: Domain Invariants §4 already fixes the constraint the ranking formula must satisfy (blended signals, not hard filters), which is enough for downstream agents to design against.
3. **Facet cardinality / query-timeout limits — resolved (engineering default).** BRD §17 requires faceted aggregations on category, price range, and rating but does not bound facet value count or concurrent filter count. At 100M SKUs (§4.1) this is a real performance risk, but the bound itself is a single-service engineering default, not a cross-cutting decision — resolved directly: max 5 concurrent facet filters per query, max 100 returned value-buckets per facet, and a 300ms query-time budget (inside the P99 < 400ms latency NFR, §3) after which the query degrades rather than fails. Full behavior specified in `edge-cases.md`'s "Query Timeout Under High-Cardinality Filters," which this closes out together with this item.
4. **Product-removal/delisting event — resolved.** BRD §5.4/§10 name only `ProductCreated` and `ProductPriceChanged` for Search; no removal event exists in the BRD's own Event Catalog. This is now resolved upstream: `kart-product-service/requirement-spec.md` and its `edge-cases.md` ("Discontinued/orphaned variant" edge case) already decided to add a proposed `ProductDiscontinued` event (soft-delete via a `status` field, not a hard delete, to keep write-side history replayable), explicitly naming Search as one of two downstream consumers this was proposed to unblock. This is not a new cross-cutting decision for this service to make — it's a follow-up consumption commitment against an already-decided upstream event, recorded in Functional Requirements §2 and API Surface §5 above. `ProductDiscontinued` is not yet a formal BRD §10 catalog row; its final payload/schema formalization is the Event Design Agent's job, tracked as a normal downstream handoff, not a blocking gap in this spec.
5. **`ProductPriceChanged` publisher contradiction — resolved.** The BRD's current §10 Event Catalog row for `ProductPriceChanged` already lists Publisher: Product (matching §5.4), per **`docs/adr/0008-event-catalog-completeness-round-2.md`**, which corrected §10 from its earlier "Pricing" listing and added Offer to the consumer list. Search's own consumption contract was never affected by this either way (Search only needed the event to exist and its payload shape, not the publisher identity), so this item is now purely a documentation confirmation, not an open question.

## Sign-off

- [x] Blocking open questions resolved
- [x] Reviewed by: Automated architecture pipeline — see docs/adr and this run's decision log
- [x] Approved to proceed to Architecture Agent
