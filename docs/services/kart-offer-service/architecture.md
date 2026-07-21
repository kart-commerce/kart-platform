---
doc_type: architecture
service: kart-offer-service
status: approved
generated_by: architecture-agent
source: docs/services/kart-offer-service/requirement-spec.md
---

# Architecture: kart-offer-service

## Boundary Rationale

`kart-offer-service` is the bounded context that answers "what does this customer pay, and why" — it owns price computation, promotional campaigns, and coupon redemption as one cohesive domain (per [ADR-0001](../../adr/0001-offer-service-merge.md)). It is a **read-heavy, checkout-adjacent** service: it is called synchronously during Cart/Checkout, but it is **not** a participant in the Order Saga (BRD §12) — Order's saga only touches Inventory, Payment, and Shipping. Offer's involvement with Order is asynchronous and after-the-fact (redemption compensation on cancellation), never a saga step.

This matters for scaling and availability posture: Offer can degrade or be briefly unavailable without blocking the transactional order-confirmation critical path, but a slow Offer response *will* directly add latency to the checkout read path (BRD NFR §3: P95 < 150ms read path applies here).

## Dependencies

| Direction | Peer Service | Mechanism | Type | Notes |
|---|---|---|---|---|
| Inbound | Cart/Checkout (client-facing, via API Gateway) | `POST /coupons/validate`, `POST /pricing/quote`, `GET /promotions/active` | **Sync** (REST) | Checkout read path — latency-sensitive |
| Inbound (consumed) | Product | `ProductPriceChanged` event | **Async** | Resolved publisher per requirement-spec Q1 — Product owns base/catalog price; Offer/Pricing reacts to recompute quotes |
| Inbound (consumed) | Order | `OrderCancelled` event | **Async** | Triggers coupon-redemption compensation (void/reverse), not a saga step — Offer is not in BRD §12's saga sequence |
| Outbound (published) | Order, Analytics | `CouponRedeemed` event | **Async** | Order consumes for its own record; Analytics fans in every event (BRD §10) |
| Outbound (published) | Analytics | `PriceQuoteIssued` event | **Async** | Consumer confirmed as Analytics-only per [ADR-0008](../../adr/0008-event-catalog-completeness-round-2.md)/[ADR-0004](../../adr/0004-analytics-full-fanin-ingestion.md) — requirement-spec Q5, resolved. No other service's requirement-spec claims it. Published as an audit/analytics/extension point, not a functional dependency for any other service today. |
| Outbound (published) | Analytics | `PromotionActivated` / `PromotionDeactivated` events | **Async** | Same resolution as `PriceQuoteIssued` above — Analytics-only per ADR-0008/ADR-0004. Note: ADR-0003 scopes Notification's consumption to `order.*`/`payment.*` events plus a short explicit list; Promotion events are not on that list, so Notification is **not** a confirmed consumer (the earlier "since Notification consumes almost every event" reasoning here was superseded by ADR-0003 and has been removed). If product wants "sale started" pushes later, that's new scope for Notification's own docs. |

## Sync vs. Async Resolution (requirement-spec Q4)

Pricing↔Promotion integration is **in-process**, not an event. Both live in the same bounded context and repo (`kart-offer-service`) per ADR-0001 — a `PromotionActivated` domain event crossing into the same service that already holds the `PromotionCampaign` aggregate would be an unnecessary async hop for a same-transaction concern. `PromotionActivated` as listed in the Dependencies table above is for **external** consumers (other services), not for Pricing's own read of active promotions, which is a direct in-process query against `PromotionCampaign`.

## Distributed-Monolith Risk

**None identified at the boundary level.** Offer has no synchronous outbound dependency on any other service — all three of its inbound sync calls come from the client-facing gateway/checkout flow, and both of its event dependencies (Product, Order) are async and non-blocking. It can be deployed, scaled, and partially degraded independently of Order/Payment/Inventory's saga.

One risk worth naming for the Database Design Agent: `/pricing/quote` must remain a fast, self-contained computation (no synchronous fan-out to Product or Promotion services) to hold the P95 < 150ms target — this means catalog price data (`ProductPriceChanged` payload) must be cached/materialized locally in Offer's read model, not fetched synchronously at quote time.

## Sign-off

- [x] Reviewed by: kakon-mehedi
- [x] Approved to proceed to DDD Agent
