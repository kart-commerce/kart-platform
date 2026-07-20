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
- Maintain the search index as a sibling of the MongoDB product read model, fed independently from the same Outbox/event pipeline — not derived from or dependent on the MongoDB read model (BRD §17).

## 3. Non-Functional Requirements

Pulled from the BRD's global NFR table (§3) and the Search-specific forced decision at §2.2, scoped to this service:

| Attribute | Target | Applies here because |
|---|---|---|
| Availability | 99.9% (secondary path) | BRD's 99.99% tier is explicitly scoped to "order path" (§3); Search is not on the Order Saga's critical path (§5.5 shows Search only as a Bus fan-out consumer, not a Saga participant) |
| Latency | P95 < 150ms, P99 < 400ms (read path) | `/search` is a pure read/query endpoint (§3 read-path row; §5.4 marks it "query only") |
| Consistency | Eventual, with a named bound: "within seconds, not milliseconds" (BRD §2.2) | This is a BRD-named forced decision specific to Search, distinct from the generic "Eventual (MongoDB/read path)" NFR row — the BRD gives Search a stricter freshness bar than other read-side services get by default. The BRD does **not** give a precise numeric SLA (e.g. p99 lag ≤ 5s) — see Open Questions |
| Reliability | At-least-once delivery + idempotent consumers | Applies to `ProductCreated`/`ProductPriceChanged` consumption (BRD NFR §3, Reliability row) |
| Retry/DLQ | 3x retry, `catalog.dlq` (BRD §10, both `ProductCreated` and `ProductPriceChanged` rows) | Catalog/search events are explicitly called out as tolerating looser retry than money-moving events (BRD §10 footnote) — consistent with Search's read-only, eventually-consistent nature |
| Throughput | Read:write ratio ≈ 20:1 platform-wide (§4.4); catalog is 100M SKUs (§4.1) | Search sits on the high-read side of that ratio; index must serve high query volume against a large catalog |

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
| `ProductPriceChanged` | Consumed | Publisher disputed between BRD §5.4 (Product) and BRD §10's Event Catalog (Pricing) — this exact contradiction was already raised and resolved in the `kart-offer-service` requirement-spec (Product publishes; Pricing only consumes). Carried here for consistency: Search's consumption contract is unaffected either way, since Search only cares that the event exists and what it contains, not who emits it |

No events are published by Search (BRD §5.4 lists no outbound events) — Search is a pure consumer/query service. Final contract (query params, response shape, pagination/facet syntax) is the API Design Agent's job, not this spec's.

## 6. Open Questions / Flagged Ambiguities

1. **Consistency-lag SLA has no number.** BRD §2.2 says catalog changes must reflect "within seconds, not milliseconds" but gives no concrete bound (e.g., p95 ≤ 2s, p99 ≤ 10s). This is named explicitly as a forced decision in the BRD, so it's real and load-bearing, but the actual number is not stated. Carried to the Architecture Agent to propose a concrete SLA, and back to a human for sign-off since it affects indexing pipeline design (batch vs. near-real-time consumers).
2. **Ranking algorithm / relevance signal weighting is unspecified.** BRD §17 names the signals (textual relevance, rating, in-stock status, sponsored placement boost) but not their weights, tie-breaking order, or whether the "sponsored placement" boost is capped or auctioned. Carried to the DDD/Architecture Agents — this is a product/business decision as much as an engineering one.
3. **Facet cardinality limits are unspecified.** BRD §17 requires faceted aggregations on category, price range, and rating "computed server-side to avoid over-fetching," but does not bound how many facet values or how many concurrent filters a query may carry. At 100M SKUs (§4.1), unbounded facet cardinality is a real performance risk. Carried to the Architecture Agent.
4. **No product-removal/delisting event is named.** BRD §5.4/§10 give Search only `ProductCreated` and `ProductPriceChanged` as consumed events — there is no `ProductDeleted`/`ProductDelisted` equivalent in the BRD's Event Catalog. It's unclear how the index is expected to remove a product that's no longer sellable. Carried to the Event Design Agent stage to confirm whether such an event exists elsewhere in the catalog or needs to be added.
5. **`ProductPriceChanged` publisher contradiction** — carried forward from the same ambiguity already flagged in `kart-offer-service`'s spec (BRD §5.4 says Product, BRD §10 says Pricing). Non-blocking for Search specifically since Search is a consumer either way, but noted here for cross-service consistency.

## Sign-off

- [ ] Blocking open questions resolved
- [ ] Reviewed by:
- [ ] Approved to proceed to Architecture Agent
