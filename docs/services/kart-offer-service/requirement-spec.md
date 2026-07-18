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
- Enforce redemption limits (BRD §2.1 item 10: "issuance, redemption, limits" — the BRD does not specify what the limits are: per-user, per-code, global, or time-windowed; see Open Questions).
- Consume `OrderCancelled` to reverse/void a coupon redemption tied to a cancelled order (BRD §5.4).

### Pricing
- Compute a price quote for a cart/checkout context, including tax and currency conversion (`/pricing/quote`, BRD §5.4).
- Publish `PriceQuoteIssued` after computing a quote (BRD §5.4).
- React to catalog price changes via `ProductPriceChanged` (BRD §5.4) — see Open Questions on publisher ambiguity.

### Promotion
- Serve currently active promotions (`/promotions/active`, BRD §5.4), cached in Redis for read performance.
- Support campaigns, flash sales, and bundle deals (BRD §2.1 item 12).
- Publish `PromotionActivated` when a campaign goes live (BRD §5.4).
- Promotion activation must feed into Pricing's quote computation — this is the domain coupling that justifies the merge (ADR-0001), but the BRD does not specify the actual integration contract between the two (in-process call within the same bounded context, vs. an internal event). Left to the Architecture/DDD Agents.

## 3. Non-Functional Requirements

Pulled from the BRD's global NFR table (§3), scoped to this service:

| Attribute | Target | Applies here because |
|---|---|---|
| Availability | 99.9% (secondary path — Offer is not on the Order Saga's critical path per §5.5, only Cart/Checkout reads from it) | BRD does not call out Offer/Pricing/Coupon/Promotion specifically in the 99.99% critical-path tier |
| Latency | P95 < 150ms, P99 < 400ms (read path) | `/pricing/quote` and `/promotions/active` are on the checkout read path |
| Consistency | Eventual for Promotion (Redis cache), Strong for Coupon redemption (PostgreSQL write) | Coupon redemption must not double-redeem; Promotion staleness of seconds is tolerable |
| Reliability | At-least-once delivery + idempotent consumers | Applies to `CouponRedeemed`, `PriceQuoteIssued`, `PromotionActivated` publication and `OrderCancelled`/`ProductPriceChanged` consumption |
| Retry/DLQ | `CouponRedeemed`: 2x retry, `coupon.dlq` (BRD §10) | Notably **not** in the BRD's "money-moving" 5x-retry tier (`Payment*` only) — see Open Questions, since kart-platform's own event standards overlay had assumed coupon redemption was money-moving-critical |

## 4. Domain Invariants

- A coupon must never be redeemed twice for the same order (double-redemption prevention — analogous in spirit to the BRD's inventory-oversell and payment-double-charge invariants at §2.2, though the BRD does not state this explicitly for Coupon; inferred from "redemption... limits" at §2.1).
- A `PriceQuoteIssued` must reflect the product price and any active promotion at the moment of quoting — not a stale cached price, per the pricing/catalog consistency intent implied by consuming `ProductPriceChanged`.
- Promotion/coupon effects must be idempotent under RabbitMQ's at-least-once delivery (BRD NFR §3, Reliability row).

## 5. API Surface (from BRD, starting point only)

| Endpoint/Event | Direction | Notes |
|---|---|---|
| `POST /coupons/validate` | Inbound API | BRD §5.4 |
| `POST /pricing/quote` | Inbound API | BRD §5.4 |
| `GET /promotions/active` | Inbound API | BRD §5.4 |
| `CouponRedeemed` | Published | Consumed by Order, Analytics (BRD §10) |
| `PriceQuoteIssued` | Published | Consumer not specified in BRD — see Open Questions |
| `PromotionActivated` | Published | Consumer not specified in BRD — see Open Questions |
| `OrderCancelled` | Consumed | Published by Order (BRD §10) |
| `ProductPriceChanged` | Consumed | Publisher disputed — see Open Questions |

Final contract is the API Design Agent's job, not this spec's.

## 6. Open Questions / Flagged Ambiguities

**Resolved (blocking):**

1. **`ProductPriceChanged` publisher contradiction — RESOLVED.** Product publishes it (BRD §5.4's service table stands); Pricing is a consumer, not the publisher. BRD §10's Event Catalog entry was the error. Product owns the catalog/list price; Pricing only computes derived quotes (tax, currency, promotions applied) and never announces base price changes.

**Carried forward (non-blocking — resolved by a later pipeline stage, not here):**

2. **Coupon redemption criticality** — BRD gives `CouponRedeemed` 2x retry, no paging (not the `Payment*` 5x/paged tier). Carried to the **Event Design Agent** stage to decide the actual retry/DLQ policy for this service.
3. **Coupon redemption limit semantics** (per-user/per-code/global/time-windowed) — carried to the **DDD Agent** stage; materially affects the `Coupon` aggregate's invariants.
4. **Pricing↔Promotion integration contract** (in-process call vs. internal event) — this is the **Architecture Agent**'s own job (sync vs. async dependency identification per its charter), not a Requirement Agent blocker. Left open for that stage.
5. **`PriceQuoteIssued` consumer** — no consumer listed in BRD §10. Carried to the **API/Event Design Agent** stages to confirm whether Cart/Order actually consume it or it's audit-only.

## Sign-off

- [x] Blocking open questions resolved (Q1)
- [x] Reviewed by: kakon-mehedi
- [x] Approved to proceed to Architecture Agent
