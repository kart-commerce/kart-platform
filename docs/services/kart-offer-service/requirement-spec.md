---
doc_type: requirement-spec
service: kart-offer-service
status: approved
generated_by: requirement-agent
source: docs/requirements/kart-requirements.md
---

# Requirement Spec: kart-offer-service

## 1. Scope

Covers three BRD services merged per [ADR-0001](../../adr/0001-offer-service-merge.md): **Coupon**, **Pricing**, and **Promotion** (BRD §2.1 items 10–12). All three answer "what does this customer pay, and why," and Promotion directly modifies pricing computation.

The merge is a bounded-context decision, not a data-model one: the write model must keep `PricingQuote`, `Coupon`, and `PromotionCampaign` as distinct aggregate roots (enforced by the DDD Agent downstream, not this spec).

## 2. Functional Requirements

### Coupon
- Validate a coupon code against redemption rules (`/coupons/validate`, BRD §5.4).
- Redeem a coupon, publishing `CouponRedeemed` (code, orderId) on success (BRD §10).
- Enforce redemption limits (BRD §2.1 item 10: "issuance, redemption, limits" — the BRD does not specify what the limits are: per-user, per-code, global, or time-windowed; resolved as "all three, independently optional," see Open Questions §6.3 and ddd-model.md Modeling Decision #1).
- Consume `OrderCancelled` to reverse/void a coupon redemption tied to a cancelled order (BRD §5.4).
- Support coupon issuance (creation) and deactivation via an internal, admin-invoked write API — not customer-facing (BRD §2.1 item 10's "issuance"; BRD §24.1's Admin role example grant, "coupon issuance"). The BRD names no creation endpoint anywhere — §5.4's only stated Coupon endpoint is `/coupons/validate` — this is a real gap, not an oversight local to this spec: ADR-0010 (`docs/adr/0010-admin-service-scope-and-integration.md`) already assigns coupon issuance to Offer's own write API, invoked synchronously by Admin Service (Admin never holds a second copy of `Coupon` data), and that ADR's own Consequences section explicitly names "Offer's coupon-creation write endpoint is likewise unstated" as this service's own open item to close, not a new cross-cutting question. Resolved directly here as a single-service engineering default: Offer exposes `POST /coupons` (create) and `POST /coupons/{couponCode}/deactivate` as internal/admin-only endpoints (authorized via the `Admin` RBAC role claim per BRD §24.1, not reachable by the `Customer` role) — final request/response shape is the API Design Agent's job, this spec only establishes that the endpoints exist and who calls them.

### Pricing
- Compute a price quote for a cart/checkout context, including tax and currency conversion (`/pricing/quote`, BRD §5.4).
- Publish `PriceQuoteIssued` after computing a quote (BRD §5.4).
- React to catalog price changes via `ProductPriceChanged` (BRD §5.4) — publisher ambiguity resolved, see Open Questions §6.1 (Product publishes, Pricing consumes).

### Promotion
- Serve currently active promotions (`/promotions/active`, BRD §5.4), cached in Redis for read performance.
- Support campaigns, flash sales, and bundle deals (BRD §2.1 item 12).
- Publish `PromotionActivated` when a campaign goes live (BRD §5.4).
- Promotion activation must feed into Pricing's quote computation — this is the domain coupling that justifies the merge (ADR-0001); the BRD does not specify the actual integration contract between the two, resolved as an in-process, same-bounded-context call, see Open Questions §6.4 and architecture.md's "Sync vs. Async Resolution."
- Support campaign creation/deactivation via an internal, admin-invoked write API — the same shape of gap as Coupon issuance above: BRD §2.1 item 12 states Promotion's scope ("campaigns, flash sales, bundle deals") but names no creation endpoint, and unlike Coupon issuance this operation is not one of the three illustrative example grants BRD §24.1 lists for the `Admin` role. Resolved directly here, by analogy to the Coupon-issuance resolution above, as a single-service engineering default rather than a second cross-cutting question: Offer exposes `POST /promotions` (create/activate) and `POST /promotions/{campaignId}/deactivate` as internal/admin-only endpoints, following the identical integration pattern ADR-0010 (`docs/adr/0010-admin-service-scope-and-integration.md`) already establishes for coupon issuance (owning service exposes the write API, Admin calls it, never a second copy of the data). That ADR's closed-enumeration table (its Decision #1) not naming "promotion campaign management" among Admin's four categories is treated as a minor, low-risk gap in that ADR's own enumeration — the same operation shape as coupon issuance, simply omitted from §24.1's illustrative (not exhaustive) examples — not a reason to open a second PENDING ADR here; formally extending that table is a trivial follow-up edit belonging to that ADR's own file, not a blocker for this service's sign-off.

## 3. Non-Functional Requirements

Pulled from the BRD's global NFR table (§3), scoped to this service:

| Attribute | Target | Applies here because |
|---|---|---|
| Availability | 99.9% (secondary path — Offer is not on the Order Saga's critical path per §5.5, only Cart/Checkout reads from it) | BRD does not call out Offer/Pricing/Coupon/Promotion specifically in the 99.99% critical-path tier |
| Latency | P95 < 150ms, P99 < 400ms (read path) | `/pricing/quote` and `/promotions/active` are on the checkout read path |
| Consistency | Write-through (Redis + PostgreSQL updated synchronously) for Promotion/active-campaign flags; Strong for Coupon redemption (PostgreSQL write) | BRD §16's Caching table mandates write-through specifically for "Promotion/active-campaign flags... since staleness there is unacceptable for pricing" — this supersedes the generic global-NFR "eventual is fine for caches" assumption for this one field class (see edge-cases.md's "Stale Redis cache vs. an actively-changing campaign" for the full resolution); Coupon redemption must not double-redeem |
| Reliability | At-least-once delivery + idempotent consumers | Applies to `CouponRedeemed`, `PriceQuoteIssued`, `PromotionActivated` publication and `OrderCancelled`/`ProductPriceChanged` consumption |
| Retry/DLQ | `CouponRedeemed`: 2x retry, `coupon.dlq` (BRD §10) | Not in the BRD's "money-moving" 5x-retry tier (`Payment*` only) — **resolved**, see Domain Invariants / event-contract.md's Q2 Resolution: Coupon redemption is not itself the double-charge-prevention boundary (Order/Payment's Saga idempotency owns that), so the BRD's original 2x/no-paging tier is correct as-is, not an oversight to escalate |

## 4. Domain Invariants

- A coupon must never be redeemed twice for the same order (double-redemption prevention — analogous in spirit to the BRD's inventory-oversell and payment-double-charge invariants at §2.2, though the BRD does not state this explicitly for Coupon; inferred from "redemption... limits" at §2.1).
- A `PriceQuoteIssued` must reflect the product price and any active promotion at the moment of quoting — not a stale cached price, per the pricing/catalog consistency intent implied by consuming `ProductPriceChanged`.
- Promotion/coupon effects must be idempotent under RabbitMQ's at-least-once delivery (BRD NFR §3, Reliability row).
- Deactivating a `Coupon` or `PromotionCampaign` must never retroactively invalidate a redemption/quote that already completed before the deactivation write committed — deactivation only prevents *future* validate/quote calls from seeing the code/campaign as active, it is not a rollback of past effects (same "immutable once issued" posture `PricingQuote` already has, applied here to the admin-write path introduced above).
- A coupon code must be unique at creation time (rejected on duplicate `couponCode`, enforced by the existing PRIMARY KEY on `coupons.coupon_code`, database-design.md) — this is a direct consequence of `CouponCode` being the aggregate's identifying value object (ddd-model.md), not a new modeling decision.

## 5. API Surface (from BRD, starting point only)

| Endpoint/Event | Direction | Notes |
|---|---|---|
| `POST /coupons/validate` | Inbound API | BRD §5.4 |
| `POST /pricing/quote` | Inbound API | BRD §5.4 |
| `GET /promotions/active` | Inbound API | BRD §5.4 |
| `POST /coupons` | Inbound API (internal, admin-only) | Not BRD-stated; resolved gap, see Functional Requirements § Coupon and ADR-0010 (`docs/adr/0010-admin-service-scope-and-integration.md`) |
| `POST /coupons/{couponCode}/deactivate` | Inbound API (internal, admin-only) | Not BRD-stated; resolved gap, same as above |
| `POST /promotions` | Inbound API (internal, admin-only) | Not BRD-stated; resolved gap, see Functional Requirements § Promotion |
| `POST /promotions/{campaignId}/deactivate` | Inbound API (internal, admin-only) | Not BRD-stated; resolved gap, same as above |
| `CouponRedeemed` | Published | Consumed by Order, Analytics (BRD §10) |
| `PriceQuoteIssued` | Published | Consumed by Analytics only ([ADR-0008](../../adr/0008-event-catalog-completeness-round-2.md), [ADR-0004](../../adr/0004-analytics-full-fanin-ingestion.md)) — see Open Questions Q5 |
| `PromotionActivated` | Published | Consumed by Analytics only ([ADR-0008](../../adr/0008-event-catalog-completeness-round-2.md), [ADR-0004](../../adr/0004-analytics-full-fanin-ingestion.md)) — see Open Questions Q5 |
| `PromotionDeactivated` | Published | Not in the BRD; added by ddd-model.md as the symmetric counterpart to `PromotionActivated`. Consumed by Analytics only, same reasoning as `PromotionActivated` (Q5) |
| `OrderCancelled` | Consumed | Published by Order (BRD §10) |
| `ProductPriceChanged` | Consumed | Publisher is Product, not Pricing — resolved, see Open Questions Q1 |

Final contract is the API Design Agent's job, not this spec's.

## 6. Open Questions / Flagged Ambiguities

All items originally raised here, plus one new gap found during this closure pass (item 6), are now resolved. None are blocking sign-off. See "Non-Blocking Carry-Forwards" below for items intentionally left for later pipeline stages — those are handoffs, not gaps.

1. **`ProductPriceChanged` publisher contradiction — RESOLVED.** Product publishes it (BRD §5.4's service table stands); Pricing is a consumer, not the publisher. BRD §10's Event Catalog entry was the error. Product owns the catalog/list price; Pricing only computes derived quotes (tax, currency, promotions applied) and never announces base price changes. Formally codified in [ADR-0008](../../adr/0008-event-catalog-completeness-round-2.md), which corrected BRD §10's Publisher column from "Pricing" to "Product" and added Offer to the consumer list — this spec's original reading is now the BRD's own text too, not just this service's local interpretation.

2. **Coupon redemption criticality — RESOLVED.** BRD gives `CouponRedeemed` 2x retry, no paging (not the `Payment*` 5x/paged tier). event-contract.md's "Requirement-Spec Q2 Resolution" section (Event Design Agent stage, already run for this service) kept the BRD's 2x/no-paging tier: the double-charge risk the `Payment*` tier guards against is owned by Order/Payment's own Saga idempotency, not by Coupon; a lost/retried `CouponRedeemed` degrades to a temporarily-inaccurate Analytics count or a delayed Order-side record, the same risk class as `ReviewSubmitted` (also 2x). Not re-litigated here — see event-contract.md.

3. **Coupon redemption limit semantics (per-user/per-code/global/time-windowed) — RESOLVED.** ddd-model.md's Modeling Decision #1 models all three dimensions (`RedemptionLimit.perUserCap`, `.globalCap`, `.validityWindow`) as independently-optional fields, matching how real coupon systems combine these constraints rather than forcing a single interpretation the BRD doesn't specify. Not re-litigated here — see ddd-model.md and database-design.md's `coupons`/`coupon_redemptions` schema.

4. **Pricing↔Promotion integration contract (in-process call vs. internal event) — RESOLVED.** architecture.md's "Sync vs. Async Resolution" section decided in-process, synchronous, same-bounded-context read: both aggregates live in the same repo/service per ADR-0001, so an async event hop for a same-transaction concern would be unnecessary overhead. `PromotionActivated` remains a real published event, but only for external consumers (Analytics), not for Pricing's own internal read of active campaigns. Not re-litigated here — see architecture.md.

5. **`PriceQuoteIssued` / `PromotionActivated` (and its new sibling `PromotionDeactivated`) consumer — RESOLVED.** [ADR-0008](../../adr/0008-event-catalog-completeness-round-2.md) added both events to BRD §10 with Analytics as the confirmed consumer, applying [ADR-0004](../../adr/0004-analytics-full-fanin-ingestion.md)'s platform-wide default ("every future new event automatically has Analytics as a consumer"). A cross-check of every other service's `requirement-spec.md` in this repo turned up no service that claims to consume `PriceQuoteIssued`, `PromotionActivated`, or `PromotionDeactivated` — Cart and Order's own specs do not list them as inbound events. Final decision: **Analytics is the sole confirmed consumer; all three events are published for audit/analytics/future-extension use, with no other confirmed consumer today.** If a future service (e.g. Notification, for "sale started" pushes) wants one of these, that is new, explicit scope for that service's own requirement-spec — not an ambiguity carried by this one. This also brings requirement-spec.md, ddd-model.md, architecture.md, and event-contract.md (which previously said "consumer unconfirmed"/"none confirmed") back into agreement with the BRD.

6. **Coupon issuance / promotion campaign creation write path — RESOLVED (new item, found during this pass).** BRD §2.1 item 10 ("issuance, redemption, limits") and §24.1 (Admin role example grant "coupon issuance") name coupon creation as in-scope, but no BRD section states a creation endpoint — §5.4's only stated Coupon endpoint is `/coupons/validate`. ADR-0010 (`docs/adr/0010-admin-service-scope-and-integration.md`) already resolves the cross-cutting half of this question (Admin invokes Offer's own write API synchronously; Admin never holds a duplicate `Coupon` copy) and explicitly names "Offer's coupon-creation write endpoint is likewise unstated" as this service's own remaining item to close. Closed directly in Functional Requirements/API Surface above: `POST /coupons`, `POST /coupons/{couponCode}/deactivate`, `POST /promotions`, `POST /promotions/{campaignId}/deactivate`, all internal/admin-only. The Promotion half (not named in BRD §24.1's illustrative examples, and not in the PENDING ADR's closed-enumeration table) is decided by analogy as a single-service default, not escalated as a second cross-cutting question — see Functional Requirements § Promotion for the reasoning. Not blocking: this is a same-shape extension of an already-decided integration pattern, not a new ambiguity.

## Non-Blocking Carry-Forwards to Later Pipeline Stages

These are normal handoffs to downstream agent stages, not unresolved gaps — sign-off does not depend on closing them here:

- **`PricingQuote` TTL's exact numeric value (15 minutes)** is ddd-model.md's own stated starting default (Modeling Decision #2), explicitly open to revision once the Database/API Design Agents need a concrete number for schema/cache design — carried forward there, not this spec's call to finalize.
- **Final request/response schemas** for every endpoint in API Surface above (including the four internal/admin-only endpoints newly added by item 6) are the API Design Agent's job per this spec's own "starting point only" framing — not re-decided here.
- **Exact P95/P99 latency budget allocation** between `/pricing/quote`'s in-process Promotion read and its own computation (both currently covered by one blended NFR row in §3) is an Architecture Agent-level capacity question, not a requirement-spec-level one.

## Sign-off

- [x] Blocking open questions resolved
- [x] Reviewed by: Automated architecture pipeline — see docs/adr and this run's decision log
- [x] Approved to proceed to Architecture Agent
