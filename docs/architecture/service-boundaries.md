---
doc_type: architecture-memory
status: living-document
---

# Service Boundaries & Dependency Graph

Cumulative record of every service's boundary and dependencies, built up one service at a time as it passes through the Architecture Agent. Each entry links to that service's full `docs/services/<name>/architecture.md`. Do not remove prior entries when adding a new one — this file is append-and-amend, not overwrite.

## kart-offer-service

See [full architecture doc](../services/kart-offer-service/architecture.md).

| Direction | Peer | Mechanism | Type |
|---|---|---|---|
| Inbound (client) | Cart/Checkout via API Gateway | `/coupons/validate`, `/pricing/quote`, `/promotions/active` | Sync |
| Inbound | Product | `ProductPriceChanged` | Async |
| Inbound | Order | `OrderCancelled` | Async |
| Outbound | Order, Analytics | `CouponRedeemed` | Async |
| Outbound | (unconfirmed) | `PriceQuoteIssued` | Async |
| Outbound | (unconfirmed) | `PromotionActivated` | Async |

No synchronous outbound dependency on any other service. Not a participant in the Order Saga (BRD §12).
