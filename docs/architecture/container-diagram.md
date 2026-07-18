---
doc_type: architecture-memory
status: living-document
---

# Container Diagram (C4 Level 2)

Cumulative diagram, extended one service at a time as each passes through the Architecture Agent. See [service-boundaries.md](service-boundaries.md) for the tabular dependency detail behind each edge.

```mermaid
graph TB
    Client[Client / Mobile / Web]
    GW[API Gateway]
    Client --> GW

    GW --> Offer[kart-offer-service<br/>Coupon + Pricing + Promotion]

    Product[Product Service] -. ProductPriceChanged .-> Offer
    Order[Order Service] -. OrderCancelled .-> Offer
    Offer -. CouponRedeemed .-> Order
    Offer -. CouponRedeemed .-> Analytics[Analytics Service]
```

_Only `kart-offer-service` has been placed so far — this diagram grows as each subsequent service goes through the Architecture Agent._
