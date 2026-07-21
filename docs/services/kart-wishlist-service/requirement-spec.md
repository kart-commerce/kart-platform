---
doc_type: requirement-spec
service: kart-wishlist-service
status: approved
generated_by: requirement-agent
source: docs/requirements/kart-requirements.md
---

# Requirement Spec: kart-wishlist-service

## 1. Scope

Covers the single BRD service **Wishlist** (BRD §2.1 item 13: "Saved items, price-drop alerts"). No merge — unlike `kart-offer-service` ([ADR-0001](../../adr/0001-offer-service-merge.md)), Wishlist maps one-to-one from BRD row to service, so no ADR is needed to justify scope.

The BRD's treatment of this service is minimal: one row in the core-modules table (§2.1), one condensed row in the service-design table (§5.4), and — since **ADR-0007** (Event Catalog Completeness Pass) — a full Event Catalog entry (§10) for both the event Wishlist consumes and the event it publishes. Several gaps flagged in prior drafts of this spec are now closed: one by ADR (§6, item resolved by reference / since prior draft), three more by direct, single-service engineering defaults this pass made because they had no cross-cutting impact (§6, "Resolved by this pass"). The remaining three items are genuinely later-pipeline-stage decisions (API contract granularity, aggregate sizing, infra topology) and are carried forward, non-blocking; see §6.

## 2. Functional Requirements

### Saved Items
- Maintain a user's saved/wishlisted products (BRD §2.1 item 13, "Saved items").
- Expose wishlist operations via `/wishlist` (BRD §5.4) — the BRD gives only this base path; it does not enumerate HTTP verbs or sub-paths (add item, list items, remove item). See Open Questions.

### Price-Drop Alerts
- Consume `ProductPriceChanged` (BRD §5.4) to detect price movement on wishlisted products.
- Publish `WishlistPriceAlertTriggered` when a price-drop condition is met (BRD §5.4). The BRD itself does not define what qualifies as a "drop" or over what window, but this is now resolved as a service-owned engineering default (this spec's §6, item 2 and item 3 — no cross-cutting impact, so no ADR was needed): an alert fires when a `ProductPriceChanged` shows a new price **at least 5% below** the wishlisted product's current reference price for that `(userId, sku)` pair, and at most **one alert per `(userId, sku)` pair fires per rolling 24-hour window** regardless of how many further qualifying drops occur inside it. See §4 (Domain Invariants) for the precise rule and §6 for the rationale.
- `WishlistPriceAlertTriggered` now has a full Event Catalog row (BRD §10, line ~412), added by **ADR-0007** (Event Catalog Completeness Pass): publisher Wishlist; consumers Notification and Analytics; payload `userId, sku, oldPrice, newPrice`; 2x retry; DLQ `wishlist.dlq`. This resolves the prior draft's open question about whether Notification actually consumes this event — BRD §5.4's own Notification row (line ~192) independently names `WishlistPriceAlertTriggered` by name among the events Notification consumes, confirming the Event Catalog's consumer assignment rather than merely stating it once. No longer open; see §6.

## 3. Non-Functional Requirements

Pulled from the BRD's global NFR table (§3), scoped to this service:

| Attribute | Target | Applies here because |
|---|---|---|
| Availability | 99.9% (secondary path) | Wishlist is not named on the Order Saga's critical path (§5.5); BRD does not call out Wishlist specifically in the 99.99% tier |
| Latency | P95 < 150ms, P99 < 400ms (read path) | `/wishlist` reads (viewing saved items) sit on the browse path, not the checkout write path |
| Consistency | Not fully determinable — BRD lists Wishlist's database as simply "MongoDB" (§5.4), unlike sibling MongoDB-read-side services (Product, User, Review) which the BRD pairs with a PostgreSQL write side per the platform's stated CQRS pattern (§6, §7). See Open Questions. |
| Reliability | At-least-once delivery + idempotent consumers (global NFR) | Applies to `ProductPriceChanged` consumption and `WishlistPriceAlertTriggered` publication |
| Retry/DLQ | `ProductPriceChanged`: 3x retry, `catalog.dlq` (BRD §10, publisher-side, governs the inbound event Wishlist consumes). `WishlistPriceAlertTriggered`: 2x retry, `wishlist.dlq` (BRD §10, added by **ADR-0007** — Event Catalog Completeness Pass) — no longer an open gap; see §5's API Surface table and §6. |
| Alert throttling (service-owned default) | Minimum 5% price-decrease threshold before a `ProductPriceChanged` is alert-worthy, plus a 24-hour cooldown per `(userId, sku)` pair | Not a BRD-stated NFR — a business-logic default this service decided directly (§4, §6 item 2/3) to keep alert volume proportionate to the "Noise Alerts" and "Alert Storm" risks named in `edge-cases.md` |

## 4. Domain Invariants

- A `WishlistPriceAlertTriggered` must reflect the actual current price of the wishlisted product at trigger time, not a stale cached price — inferred from the service's stated role of reacting to `ProductPriceChanged`, analogous to Pricing's `PriceQuoteIssued` invariant in `kart-offer-service`.
- **Price-drop alert threshold (resolved, §6 item 2):** an inbound `ProductPriceChanged` is alert-worthy for a given `(userId, sku)` pair only if the new price is at least **5% below the reference price** for that pair. The reference price starts at the price observed when the entry was added to the wishlist, and is reset to the alerted price every time an alert fires (so the next alert requires another 5%+ drop from that new, lower point) — chosen over an any-decrease rule specifically because the "Noise Alerts" edge case (`edge-cases.md`) flags sub-cent/rounding "drops" as a real spam risk under the literal FR wording.
- **Alert dedup/cooldown (resolved, §6 item 3):** at most one `WishlistPriceAlertTriggered` fires per `(userId, sku)` pair per rolling 24-hour window, regardless of how many additional qualifying (5%+) drops occur inside that window; the next evaluation after the window elapses re-applies the 5% rule against the most recently alerted reference price. This is a distinct mechanism from the redelivery-idempotency invariant below — this one throttles genuinely distinct qualifying price-drop events, not repeated delivery of the same one.
- Alert publication must be idempotent under RabbitMQ's at-least-once delivery (BRD NFR §3, Reliability row): a redelivered `ProductPriceChanged` for a price already alerted on must not re-trigger a second `WishlistPriceAlertTriggered`. Resolved directly (no BRD statement needed) via a dedup table keyed on `(userId, sku, priceObserved)` combined with the Outbox pattern on publish — see `edge-cases.md`'s "Duplicate Alert Delivery from At-Least-Once Redelivery" decision, which this invariant now cites rather than deferring to Open Questions.
- A wishlist entry belongs to exactly one user (implied by "saved items" being an inherently per-user concept) — the BRD does not state this explicitly for Wishlist, so it is inferred rather than quoted.

## 5. API Surface (from BRD, starting point only)

| Endpoint/Event | Direction | Notes |
|---|---|---|
| `/wishlist` | Inbound API | BRD §5.4 — verb/sub-path granularity (add/list/remove) not specified |
| `WishlistPriceAlertTriggered` | Published | Consumed by Notification, Analytics; payload `userId, sku, oldPrice, newPrice`; 2x retry; DLQ `wishlist.dlq` (BRD §10, added by **ADR-0007** — Event Catalog Completeness Pass). Previously absent from the Event Catalog entirely despite being named as published (§5.4); now resolved, and Notification's consumption is independently confirmed by name in BRD §5.4's own Notification row (line ~192). |
| `ProductPriceChanged` | Consumed | BRD §5.4's service table attributes this to Product; BRD §10's Event Catalog attributes it to Pricing. Same contradiction already surfaced and resolved in `kart-offer-service`'s requirement spec (Product publishes, Pricing only consumes) — this spec adopts that resolution rather than re-opening it. |

Final contract is the API Design Agent's job, not this spec's.

## 6. Open Questions / Flagged Ambiguities

**Resolved (by reference — already settled in `kart-offer-service`, an approved spec):**

1. **`ProductPriceChanged` publisher contradiction.** Product publishes it; Pricing (and, here, Wishlist) are consumers only. See `kart-offer-service/requirement-spec.md` §6 Q1 for the original resolution. Not re-opened here.

**Resolved since the prior draft.** The prior draft's Open Question #4 — `WishlistPriceAlertTriggered` missing from the Event Catalog (§10), with no stated consumer, retry count, or DLQ strategy, and it being unconfirmed whether Notification consumed it — is resolved by **ADR-0007** (Event Catalog Completeness Pass), which added a full row: publisher Wishlist; consumers Notification and Analytics; payload `userId, sku, oldPrice, newPrice`; 2x retry; DLQ `wishlist.dlq`. BRD §5.4's own Notification row (line ~192) independently names `WishlistPriceAlertTriggered` among the events Notification consumes, confirming the catalog's consumer assignment rather than relying on it alone. See §2, §3's Retry/DLQ row, and §5's API Surface table above. Removed from the list below rather than carried forward as open; remaining genuinely open items renumbered.

**Resolved by this pass (single-service engineering defaults — no cross-cutting impact, so decided directly rather than escalated to an ADR):**

2. **Price-drop threshold undefined → resolved.** The BRD states Wishlist triggers alerts on price drops but gave no minimum delta or window, so any decrease — including a $0.01 rounding change — could have triggered `WishlistPriceAlertTriggered`. **Decision:** an alert is only alert-worthy at a minimum 5% decrease from the tracked reference price for that `(userId, sku)` pair (see §4). **Why:** the "Noise Alerts" edge case (`edge-cases.md`) already names sub-cent/rounding-jitter drops as a real spam risk under the literal any-decrease reading of the FR; a percentage threshold scales with price (fair across a $5 item and a $500 item) where a fixed absolute delta would not. **Trade-off accepted:** a genuine-but-small drop (e.g., 3% off a high-value item) will not alert; acceptable because the BRD gives no basis to prefer sensitivity over noise-avoidance, and 5% is a revisitable config value, not a hardcoded architectural constraint.
3. **Alert dedup/debounce across repeated small price drops → resolved.** The BRD did not say whether each qualifying drop re-triggers an alert or whether there's a cooldown per user/product pair. **Decision:** at most one alert per `(userId, sku)` pair per rolling 24-hour window (see §4), independent of the redelivery-idempotency dedup table (`edge-cases.md`'s "Duplicate Alert Delivery" decision), which handles the separate problem of the *same* message being redelivered. **Why:** 24 hours matches a "check back tomorrow" cadence reasonable for a shopping alert, bounds worst-case notification volume during a multi-step promotion ramp, and is a plain config value rather than a cross-service concern. **Trade-off accepted:** a user who would have wanted to see each intermediate price step during a fast ramp only sees the first qualifying one per day; acceptable given the same noise-avoidance rationale as item 2.
7. **No product-removal/discontinuation event feed → resolved with an interim default.** The BRD names no event for product deletion/discontinuation that Wishlist consumes — only `ProductPriceChanged`. `kart-product-service/edge-cases.md` proposes a new `ProductDiscontinued` event as a future fix, but that event is **still only proposed, not approved or in the BRD's Event Catalog** (no ADR exists for it as of this pass), so this spec cannot depend on it existing. **Decision:** Wishlist runs its own periodic reconciliation job (see `edge-cases.md`'s "Stale Wishlist Entry" decision) that queries Product Service (`GET /products/{id}`, BRD §5.4) for the current status of wishlisted SKUs and flags/prunes entries whose product is gone, independent of any new event. **Why:** this uses only API surface the BRD already defines, so it doesn't block sign-off on an upstream proposal that may never be approved; if/when `ProductDiscontinued` is approved, Wishlist can add it as a second, faster invalidation path without removing the reconciliation job (defense in depth, not a replacement). **Trade-off accepted:** staleness window bounded by the reconciliation cadence (an Architecture Agent implementation detail, e.g. hourly/daily) rather than being instant — acceptable since a stale wishlist entry is a UX rough edge, not a correctness or money-moving concern.

**Carried forward (non-blocking — legitimately a later pipeline stage's job, not a gap in this spec):**

4. **Write-side datastore ambiguity.** BRD §5.4 lists Wishlist's database as just "MongoDB," while §6.1's "Read-Heavy vs Write-Heavy" table doesn't mention Wishlist at all (unlike Category, where §6.1 explicitly grouped it with Product/Search and created a real §5.4-vs-§6.1 contradiction — see ADR-0011 (`docs/adr/0011-category-read-model-scope.md`)). There is no equivalent explicit contradiction for Wishlist, just an omission, so this does not warrant an ADR — it is carried to the **Architecture Agent** to decide whether Wishlist is a deliberate Mongo-only exception (no separate write-side store) or whether a PostgreSQL write side was simply omitted from the condensed table.
5. **`/wishlist` verb/sub-path granularity** — carried to the **API Design Agent** to define add/list/remove semantics.
6. **Wishlist size limits** (max saved items per user) — not stated by the BRD; carried to the **DDD Agent** as a potential aggregate invariant.

## Sign-off

- [x] Blocking open questions resolved (Q2–Q3, plus Q7's interim default)
- [x] Reviewed by: Automated architecture pipeline -- see docs/adr and this run's decision log
- [x] Approved to proceed to Architecture Agent
