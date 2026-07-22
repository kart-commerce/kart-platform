---
doc_type: tickets
service: kart-offer-service
status: approved
generated_by: ticket-agent
source: [architecture.md, ddd-model.md, api-contract.yaml, database-design.md, event-contract.md, design-decisions.md — all approved]
---

# Tickets: kart-offer-service

Local draft. Not yet created as real GitHub Issues — that requires the target repo to exist (Project Scaffold Agent) and is a separate, explicit step.

**Input-freshness note:** all eight upstream design docs are now `status: approved` — the admin-write endpoints (`POST /coupons`, `POST /coupons/{couponCode}/deactivate`, `POST /promotions`, `POST /promotions/{campaignId}/deactivate`, plus their two `GET` read counterparts) that were a carried-forward implementation gap in `api-contract.yaml`/`tickets.md` are now fully specified (ADR-0019 closes the last open item, Admin's authorization category for Promotion). OFF-9/OFF-10 below are new; OFF-5/OFF-6 are updated to cite the now-real endpoints they always conceptually represented.

## Epic: kart-offer-service v1

Coupon validation/redemption, pricing quotes, and promotion campaigns — the Coupon/Pricing/Promotion merge per ADR-0001.

| ID | Task | Vertical Slice (Application/Features/) | Depends On | Design Source |
|---|---|---|---|---|
| OFF-1 | Validate coupon | `ValidateCoupon` | — | `api-contract.yaml` `/v1/coupons/validate`, `ddd-model.md` Coupon invariants |
| OFF-2 | Redeem coupon | `RedeemCoupon` | OFF-1 | `api-contract.yaml` `/v1/coupons/redeem`, `event-contract.md` `CouponRedeemed`, `database-design.md` `coupon_redemptions` |
| OFF-3 | Void coupon redemption on order cancellation | `VoidCouponRedemption` | OFF-2 | `event-contract.md` `OrderCancelled` (consumed) → `CouponRedemptionVoided` (published) |
| OFF-4 | Ingest catalog price changes | `RecomputeCatalogPrice` | — | `event-contract.md` `ProductPriceChanged` (consumed), `architecture.md` local-cache note |
| OFF-5 | Create/activate promotion campaign | `CreatePromotionCampaign` | — | `api-contract.yaml` `POST /v1/promotions` (admin-only, ADR-0019); `event-contract.md` `PromotionActivated`, `database-design.md` `promotion_campaigns` |
| OFF-6 | Deactivate promotion campaign | `DeactivatePromotionCampaign` | OFF-5 | `api-contract.yaml` `POST /v1/promotions/{campaignId}/deactivate` (`If-Match`/version precondition); `event-contract.md` `PromotionDeactivated`; `ddd-model.md` Modeling Decision #4 (window-truncation mechanism, not a status field) |
| OFF-7 | Get active promotions | `GetActivePromotions` | OFF-5 | `api-contract.yaml` `/v1/promotions/active` |
| OFF-8 | Get pricing quote | `GetPricingQuote` | OFF-4, OFF-5 | `api-contract.yaml` `/v1/pricing/quote`, `ddd-model.md` best-discount-wins precedence rule, `database-design.md` `pricing_quotes` |
| OFF-9 | Issue coupon | `IssueCoupon` | — | `api-contract.yaml` `POST /v1/coupons` (admin-only, ADR-0010), `GET /v1/coupons/{couponCode}` (admin read); `event-contract.md` `CouponIssued`; `database-design.md` `coupons` |
| OFF-10 | Deactivate coupon | `DeactivateCoupon` | OFF-9 | `api-contract.yaml` `POST /v1/coupons/{couponCode}/deactivate` (`If-Match`/version precondition); `event-contract.md` `CouponDeactivated`; `ddd-model.md` Modeling Decision #4; reuses the same `SELECT ... FOR UPDATE`-adjacent conditional-update pattern OFF-2's redemption-cap/validity-window logic already establishes for this table |

## Notes for Sprint Planner Agent

- OFF-1/OFF-4/OFF-5/OFF-9 have no dependencies — can start in parallel in sprint 1.
- OFF-8 (`GetPricingQuote`) is the highest-value slice (it's on the checkout read path) but has the most dependencies (OFF-4, OFF-5) — sequence those first.
- OFF-9 (`IssueCoupon`) and OFF-5 (`CreatePromotionCampaign`) are the same shape of task (admin-invoked aggregate creation) and fully independent of each other and of OFF-1/OFF-2 — build in parallel with the checkout-path tickets.
- OFF-10 (`DeactivateCoupon`) depends only on OFF-9 (a coupon must exist to deactivate) but shares its conditional-update/version-guard mechanism with OFF-2's redemption-path locking (`database-design.md`'s "Admin Write-Path Mechanics") — recommend the engineer who builds OFF-2 also builds OFF-10, for the same reason `kart-inventory-service/tickets.md` groups its shared-mechanism tickets together.
- No circular dependencies in this graph. Longest chain is OFF-4/OFF-5 → OFF-8 (2 deep), or OFF-9 → OFF-10 / OFF-5 → OFF-6 (2 deep each).
