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

## Owned by `kart-delivery-tracking-service`

| Term | Definition | Kind |
|---|---|---|
| TrackingRecord | The current, exposed delivery state (status, ETA, last-updated time) for one `trackingId`; a read-side projection with no PostgreSQL write-side counterpart, created only by consuming `ShipmentDispatched` | Aggregate root |
| TrackingId | The opaque tracking identifier first seen in `ShipmentDispatched`'s payload; this service never generates one itself | Value object |
| CanonicalDeliveryStatus | The single internal delivery-status enum every exposed/published status must belong to, mapped per-carrier from raw carrier codes; never a raw carrier-native string, never `PENDING`/`Unknown` | Value object |
| LifecycleOrdinal | The monotonic ordering position of a `CanonicalDeliveryStatus` value, used to reject regressive status updates | Value object |
| Eta | The current estimated-delivery-time, either passed through from the carrier or computed from a static per-carrier SLA fallback table; recomputed on every accepted status update | Value object |
| TrackingStatusHistory | The append-only audit stream of every distinct received status (mapped or unmapped) for one `trackingId`, independent of `TrackingRecord`'s current-state document | Aggregate root |
| StatusHistoryEntry | One append-only, immutable record within a `TrackingStatusHistory` stream | Entity |
| WebhookDedupEntry | The idempotency ledger entry recognizing a duplicate carrier webhook delivery by carrier-supplied key or computed content hash | Aggregate root |
| CarrierStatusIngested | Internal-only domain event: the normalized, HMAC-verified representation of an inbound carrier webhook, durably enqueued before dedup/ordinal/mapping is applied | Domain event |
| UnmappedCarrierStatusFlagged | Internal/ops-only domain event: raised when a carrier's status code fails to resolve to a `CanonicalDeliveryStatus`, driving the operational triage queue | Domain event |

## Referenced (owned elsewhere — accessed via ACL, not redefined here)

| Term | Owning Context | How `kart-delivery-tracking-service` uses it |
|---|---|---|
| Order | kart-order-service | `TrackingRecord.orderId` is a reference field only, populated from `ShipmentDispatched`'s payload; never models Order's own state machine |
| Shipment / `ShipmentDispatched` | kart-shipping-service | Consumed only as the `TrackingRecord` creation trigger; never models Shipping's own aggregate |
