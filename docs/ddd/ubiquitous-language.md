---
doc_type: ddd-memory
status: living-document
---

# Ubiquitous Language Glossary

Every term is owned by exactly **one** bounded context. Other contexts reference the concept through an Anti-Corruption Layer, never by redefining it. Check this file before introducing a new term; append, don't silently overwrite. Built up one service at a time as each passes through the DDD Agent.

## Owned by `kart-offer-service`

| Term | Definition | Kind |
|---|---|---|
| Coupon | A code-gated discount instrument with issuance, redemption, and limit rules | Aggregate root |
| CouponCode | The unique redeemable string identifying a Coupon | Value object |
| RedemptionLimit | The combination of per-user cap, global cap, and validity window that bounds how a Coupon may be redeemed | Value object |
| PricingQuote | An immutable, point-in-time computed price for a cart/checkout context, including tax and applied promotions | Aggregate root |
| PromotionCampaign | A time-boxed campaign (flash sale, bundle deal, or general promotion) that affects price computation | Aggregate root |
| DiscountRule | The computation a PromotionCampaign applies to affected items/SKUs | Value object |
| CampaignWindow | The start/end validity period of a PromotionCampaign | Value object |

## Referenced (owned elsewhere — accessed via ACL, not redefined here)

| Term | Owning Context | How `kart-offer-service` uses it |
|---|---|---|
| Order | kart-order-service | Consumes `OrderCancelled` to void a Coupon redemption; never models Order's own lifecycle |
| SKU / Product Price | kart-product-service | Consumes `ProductPriceChanged` to recompute PricingQuote; never owns catalog price |
