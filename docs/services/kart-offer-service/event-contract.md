---
doc_type: event-contract
service: kart-offer-service
status: approved
generated_by: event-design-agent
source: docs/services/kart-offer-service/ddd-model.md
---

# Event Contract: kart-offer-service

Exchange: `ecommerce.events` (per [kart-conventions.md](../../standards/kart-conventions.md)). Every consumer queue below gets its own DLQ per the reusable event standard — never shared.

| Event | Routing Key | Published/Consumed | Key Fields | Retry | DLQ | Criticality Justification |
|---|---|---|---|---|---|---|
| `CouponRedeemed` | `offer.coupon.redeemed` | Published (Order, Analytics) | `code`, `orderId` | 2x | `offer.coupon-redeemed.dlq` | See below — resolved, not `Payment*` tier |
| `CouponRedemptionVoided` | `offer.coupon.redemption-voided` | Published (Analytics) | `code`, `orderId`, `voidedAt` | 2x | `offer.coupon-redemption-voided.dlq` | Same justification as `CouponRedeemed` — symmetric event, symmetric tier |
| `PriceQuoteIssued` | `offer.pricing.quote-issued` | Published (consumer unconfirmed) | `quoteId`, `total`, `expiresAt` | 3x | `offer.quote-issued.dlq` | Standard tier — catalog/read-path event, no money movement |
| `PromotionActivated` | `offer.promotion.activated` | Published (consumer unconfirmed) | `campaignId`, `window` | 3x | `offer.promotion-activated.dlq` | Standard tier |
| `PromotionDeactivated` | `offer.promotion.deactivated` | Published (consumer unconfirmed) | `campaignId` | 3x | `offer.promotion-deactivated.dlq` | Standard tier |
| `ProductPriceChanged` | `product.price.changed` | Consumed (from Product) | `sku`, `oldPrice`, `newPrice` | — (consumer side) | — | N/A — Product owns retry/DLQ for its own publication |
| `OrderCancelled` | `order.order.cancelled` | Consumed (from Order) | `orderId`, `reason` | — (consumer side) | — | N/A — Order owns retry/DLQ for its own publication |

## Requirement-Spec Q2 Resolution: Coupon Retry Tier

**Resolved: keep the BRD's 2x/no-paging tier for `CouponRedeemed` and `CouponRedemptionVoided` — do not promote to the `Payment*` 5x/paged tier.**

Rationale: the double-charge risk the `Payment*` tier exists to guard against is owned and enforced by Order/Payment's own idempotency keys and Saga compensation (BRD §12) — Order creates one order regardless of whether a `CouponRedeemed` event is delayed or lost. A lost/retried `CouponRedeemed` event's worst case is a temporarily inaccurate Analytics count or a delayed Order-side record of which coupon applied, not a financial double-charge or an oversell. That's the same risk class as `ReviewSubmitted`, which the BRD already puts at 2x. Promoting Coupon events to the money-moving tier would page on-call for a class of failure that isn't actually money-critical — the BRD's original classification was correct, not an oversight.

## Sign-off

- [x] Reviewed by: kakon-mehedi
- [x] Approved
