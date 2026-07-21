---
doc_type: tickets
service: kart-offer-service
status: draft
generated_by: ticket-agent
source: [architecture.md, ddd-model.md, api-contract.yaml, database-design.md, event-contract.md — all approved]
---

# Tickets: kart-offer-service

Local draft. Not yet created as real GitHub Issues — that requires the target repo to exist (Project Scaffold Agent) and is a separate, explicit step.

## Epic: kart-offer-service v1

Coupon validation/redemption, pricing quotes, and promotion campaigns — the Coupon/Pricing/Promotion merge per ADR-0001.

| ID | Task | Vertical Slice (Application/Features/) | Depends On | Design Source |
|---|---|---|---|---|
| OFF-1 | Validate coupon | `ValidateCoupon` | — | `api-contract.yaml` `/v1/coupons/validate`, `ddd-model.md` Coupon invariants |
| OFF-2 | Redeem coupon | `RedeemCoupon` | OFF-1 | `api-contract.yaml` `/v1/coupons/redeem`, `event-contract.md` `CouponRedeemed`, `database-design.md` `coupon_redemptions` |
| OFF-3 | Void coupon redemption on order cancellation | `VoidCouponRedemption` | OFF-2 | `event-contract.md` `OrderCancelled` (consumed) → `CouponRedemptionVoided` (published) |
| OFF-4 | Ingest catalog price changes | `RecomputeCatalogPrice` | — | `event-contract.md` `ProductPriceChanged` (consumed), `architecture.md` local-cache note |
| OFF-5 | Activate promotion campaign | `ActivatePromotionCampaign` | — | `event-contract.md` `PromotionActivated`, `database-design.md` `promotion_campaigns` |
| OFF-6 | Deactivate promotion campaign | `DeactivatePromotionCampaign` | OFF-5 | `event-contract.md` `PromotionDeactivated` |
| OFF-7 | Get active promotions | `GetActivePromotions` | OFF-5 | `api-contract.yaml` `/v1/promotions/active` |
| OFF-8 | Get pricing quote | `GetPricingQuote` | OFF-4, OFF-5 | `api-contract.yaml` `/v1/pricing/quote`, `ddd-model.md` best-discount-wins precedence rule, `database-design.md` `pricing_quotes` |

## Notes for Sprint Planner Agent

- OFF-1/OFF-4/OFF-5 have no dependencies — can start in parallel in sprint 1.
- OFF-8 (`GetPricingQuote`) is the highest-value slice (it's on the checkout read path) but has the most dependencies (OFF-4, OFF-5) — sequence those first.
- No circular dependencies in this graph.
