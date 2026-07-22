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
| Outbound | Analytics | `PriceQuoteIssued` | Async |
| Outbound | Analytics | `PromotionActivated` | Async |

No synchronous outbound dependency on any other service. Not a participant in the Order Saga (BRD §12).

## kart-product-service

See [full architecture doc](../services/kart-product-service/architecture.md).

| Direction | Peer | Mechanism | Type |
|---|---|---|---|
| Inbound (client) | Client/Web/Mobile via API Gateway | `GET /products/{id}` | Sync |
| Inbound | Admin Service (`/admin/*`) | `POST /products`, `PUT`/`PATCH /products/{id}` | Sync |
| Inbound | Partner API Consumer (via API Gateway) | `POST /products`, `PUT`/`PATCH /products/{id}` | Sync |
| Inbound | Review | `ReviewSubmitted` | Async |
| Outbound | Search, Recommendation, Analytics | `ProductCreated` | Async |
| Outbound | Search, Wishlist, Offer, Analytics | `ProductPriceChanged` | Async |
| Outbound | Analytics (confirmed); others TBD | `ProductUpdated` | Async |
| Outbound | Search, Wishlist, Analytics | `ProductDiscontinued` | Async |

No synchronous outbound dependency on any other service, including Category — see this service's `architecture.md` for why a Category dependency is deliberately **not** added (Category's own approved docs state no live sync mechanism, sync or async, connects the two services today). Not a participant in the Order Saga (BRD §5.5 reaches Product only from the Gateway). Admin/Partner API write availability is coupled to Product's own write-path uptime (unavoidable, since they call Product's own API per ADR-0010) but this coupling does not chain further.

## kart-shipping-service

See [full architecture doc](../services/kart-shipping-service/architecture.md).

| Direction | Peer | Mechanism | Type |
|---|---|---|---|
| Inbound | Order | `OrderConfirmed` | Async |
| Inbound (internal/ops, unconfirmed) | Not yet confirmed (likely Admin/ops) | `/shipments` | Sync, if built |
| Outbound | Order, Notification, Delivery Tracking, Analytics | `ShipmentDispatched` | Async |
| Outbound | Order, Notification, Analytics | `ShipmentCreationFailed` | Async |
| Outbound | Shipping Carriers (external system, not a Kart service) | Carrier REST API (rate/label) | Sync, circuit breaker + secondary-carrier failover |

No synchronous dependency on any other Kart service. Async, post-confirmation participant in the Order Saga's success flow (BRD §12.1, per ADR-0002) — sits off the order-confirmation critical path by construction. Its only synchronous call of any kind is to the external Carrier API, mitigated with a circuit breaker + failover and decoupled from the internal write-path latency budget via Transactional Outbox. See [ADR-0002](../adr/0002-order-shipping-async-integration.md) and [ADR-0015](../adr/0015-shipping-shipment-creation-failed-event.md).

## kart-delivery-tracking-service

See [full architecture doc](../services/kart-delivery-tracking-service/architecture.md).

| Direction | Peer | Mechanism | Type |
|---|---|---|---|
| Inbound (client) | Client/Mobile/Web via API Gateway | `GET /tracking/{id}` | Sync |
| Inbound | Shipping | `ShipmentDispatched` (aggregate-creation trigger) | Async |
| Inbound (external, not a Kart service) | Per-carrier webhook senders | `POST /internal/webhooks/carriers/{carrierId}` | Async (third-party push) |
| Outbound (external, not a Kart service) | Per-carrier tracking APIs | Scheduled polling (6h staleness threshold) | Sync (outbound REST) |
| Outbound | Order (terminal `"delivered"` status only), Notification, Analytics | `DeliveryStatusUpdated` | Async |

No synchronous outbound dependency on any other Kart service. Not a participant in the Order Saga (BRD §12) — Bus fan-out consumer only. Its `DeliveryStatusUpdated` consumer set includes Order per [ADR-0005](../adr/0005-unify-order-terminal-event.md); this service's own `requirement-spec.md` has since been corrected to match. Its largest integration surface (per-carrier webhooks/polling) is external, not a Kart peer, and is not represented as a node in this graph.

## kart-payment-service

See [full architecture doc](../services/kart-payment-service/architecture.md).

| Direction | Peer | Mechanism | Type |
|---|---|---|---|
| Inbound (consumed) | Order | `OrderCreated` | Async |
| Inbound | Payment Gateway (external) | Tokenized charge/refund API call | Sync (external) |
| Inbound | Payment Gateway (external) | `POST /payments/webhooks/{gateway}` | Async (external) |
| Inbound (client-facing) | API Gateway → client / Support Agent tooling | `POST /payments/charge`, `POST /payments/{id}/refund` | Sync |
| Outbound | Order, Notification, Analytics | `PaymentCompleted` | Async |
| Outbound | Order, Notification, Analytics | `PaymentFailed` | Async |
| Outbound | Order, Notification, Analytics | `RefundIssued` | Async |
| Outbound | Order, Notification, Analytics | `ChargebackReceived` (new, [ADR-0012](../adr/0012-payment-chargeback-handling.md)) | Async |

No synchronous outbound dependency on any other Kart service — only sync outbound edge is to the external Payment Gateway. Required saga step in the Order Saga's success and compensation flows (BRD §12.1/§12.2), but coupled to Order fully asynchronously in both directions (see architecture.md's Sync/Async Resolution section for how this reconciles with BRD §12's uniform-looking sequence-diagram arrows). Refunds are tracked as their own Saga instance, distinct from the Order Saga's state machine.

## kart-admin-service

See [full architecture doc](../services/kart-admin-service/architecture.md).

| Direction | Peer | Mechanism | Type |
|---|---|---|---|
| Inbound (client) | Back-office operator, via API Gateway | `/admin/*` (RBAC: Identity-issued `Admin` claim + Admin's own category-scoped grant check) | Sync |
| Outbound | Product | `POST /products`, `PUT`/`PATCH /products/{id}` (catalog management) | Sync |
| Outbound | Category | Category's own write API (catalog management — node create/update/reorder/move) | Sync |
| Outbound | Offer | `POST /coupons` (coupon issuance) | Sync |
| Outbound | Identity | `POST /internal/users/{userId}/lock`, `.../unlock` (user suspension) | Sync |
| Outbound | Inventory | Inventory's own replenishment write path (inventory replenishment) | Sync |
| Outbound (published) | Analytics | `AdminActionPerformed` (audit trail, via Outbox pattern) | Async |

No consumed events (BRD §5.4 confirms "—"; operator-driven, not event-reactive). Not a participant in the Order Saga (BRD §5.5). Widest synchronous fan-out of any service placed so far — five outbound sync dependencies, each isolated to one back-office category by an independent circuit breaker (see `architecture.md`'s Distributed-Monolith Risk section) — no multi-hop synchronous chain exists.

## kart-recommendation-service

See [full architecture doc](../services/kart-recommendation-service/architecture.md).

| Direction | Peer | Mechanism | Type |
|---|---|---|---|
| Inbound (client) | Client/Mobile/Web via API Gateway | `GET /recommendations/{userId}` | Sync |
| Inbound | Order | `OrderDelivered` | Async |
| Inbound | Product | `ProductCreated` | Async |
| Inbound | (publisher not yet named) | Clickstream event(s) | Async |
| Outbound | Inventory | `GET /inventory/{sku}` | Sync |
| Outbound | Product | `GET /products/{id}` | Sync |

Publishes no events. Not a participant in the Order Saga (BRD §12). Flagged distributed-monolith risk: its two new synchronous outbound calls (Inventory, Product) for request-time availability filtering must degrade gracefully on timeout/error rather than coupling Recommendation's own uptime to both dependencies — see its `architecture.md` for the full mitigation requirement.

## kart-analytics-service

See [full architecture doc](../services/kart-analytics-service/architecture.md).

| Direction | Peer | Mechanism | Type |
|---|---|---|---|
| Inbound | Order | `OrderCreated`, `OrderConfirmed`, `OrderCancelled`, `OrderCompensationTriggered`, `OrderDelivered` | Async |
| Inbound | Inventory | `InventoryReserved`, `InventoryReservationFailed`, `InventoryReleased`, `InventoryReplenished` | Async |
| Inbound | Payment | `PaymentCompleted`, `PaymentFailed`, `RefundIssued`, `ChargebackReceived` | Async |
| Inbound | Shipping | `ShipmentDispatched`, `ShipmentCreationFailed` | Async |
| Inbound | Delivery Tracking | `DeliveryStatusUpdated` | Async |
| Inbound | Product | `ProductCreated`, `ProductPriceChanged`, `ProductUpdated` | Async |
| Inbound | Review | `ReviewSubmitted`, `ReviewUpdated` | Async |
| Inbound | Category | `CategoryUpdated` | Async |
| Inbound | Offer | `CouponRedeemed`, `PriceQuoteIssued`, `PromotionActivated`, `PromotionDeactivated` | Async |
| Inbound | User | `UserProfileUpdated`, `UserDataErased` | Async |
| Inbound | Identity | `UserRegistered`, `SessionCreated`, `UserAccountUpdated` | Async |
| Inbound | Notification | `NotificationSent` | Async |
| Inbound | Cart | `CartCheckedOut` | Async |
| Inbound | Wishlist | `WishlistPriceAlertTriggered` | Async |
| Inbound | Admin | `AdminActionPerformed` | Async |
| Outbound | (none) | Analytics publishes no event | — |
| Inbound (internal only) | Internal BI/ops consumers | Internal REST query API (`/internal/v1/...`) + BI-tool warehouse connection | Sync, internal-only, not via public Gateway |

Full fan-in of every published platform event per [ADR-0004](../adr/0004-analytics-full-fanin-ingestion.md). `ChargebackReceived` ([ADR-0012](../adr/0012-payment-chargeback-handling.md)), `ShipmentCreationFailed` ([ADR-0015](../adr/0015-shipping-shipment-creation-failed-event.md)), `ProductUpdated`, `ReviewUpdated`, `PromotionDeactivated`, and `UserDataErased` ([ADR-0016](../adr/0016-user-gdpr-erasure-policy.md)) were added to this row during this service's own Architecture Agent pass, cross-checked against each publishing service's own `architecture.md` — see `kart-analytics-service/architecture.md`'s "Full Fan-In Completeness Check" for detail. Zero synchronous coupling in either direction — no public inbound endpoint, no synchronous outbound dependency on any other service. Not a participant in the Order Saga (BRD §12).

## kart-notification-service

See [full architecture doc](../services/kart-notification-service/architecture.md).

| Direction | Peer | Mechanism | Type |
|---|---|---|---|
| Inbound | Order | `OrderCreated`, `OrderConfirmed`, `OrderCancelled`, `OrderCompensationTriggered`, `OrderDelivered` | Async |
| Inbound | Payment | `PaymentCompleted`, `PaymentFailed`, `RefundIssued` | Async |
| Inbound | Shipping | `ShipmentDispatched` | Async |
| Inbound | Delivery Tracking | `DeliveryStatusUpdated` | Async |
| Inbound | Wishlist | `WishlistPriceAlertTriggered` | Async |
| Inbound | Identity | `UserRegistered` | Async |
| Inbound | User | `UserNotificationPreferenceUpdated` (new event, introduced by this doc — see architecture.md) | Async |
| Outbound | Analytics | `NotificationSent` | Async |

No synchronous inbound API (consumer-only, BRD §5.4) and no synchronous outbound dependency on any other service. Not a participant in the Order Saga (BRD §12). Broadest fan-in consumer on the platform (ADR-0003); no distributed-monolith risk identified — see full doc for the two named (accepted) risks: opt-out staleness window and fan-in scaling, both already mitigated.

## kart-cart-service

See [full architecture doc](../services/kart-cart-service/architecture.md).

| Direction | Peer | Mechanism | Type |
|---|---|---|---|
| Inbound (client) | Client / Checkout UI via API Gateway | `/cart`, `POST /cart/merge` | Sync |
| Inbound | Inventory | `InventoryReservationFailed` | Async |
| Outbound | Analytics | `CartCheckedOut` | Async |
| Outbound (best-effort, fails open) | Product, Inventory | Lazy stock/price validation (gRPC) | Sync |

One synchronous outbound edge only, guarded by timeout + circuit breaker and failing open on breaker-open/timeout — never a hard gate on checkout initiation. Not a participant in the Order Saga (BRD §12); no dependency edge to Order in either direction — `CartCheckedOut` is Analytics-only, and Order's own creation trigger (`POST /orders`) bypasses Cart entirely (ADR-0007).

## kart-inventory-service

See [full architecture doc](../services/kart-inventory-service/architecture.md).

| Direction | Peer | Mechanism | Type |
|---|---|---|---|
| Inbound | Order | `POST /inventory/reserve` | Sync |
| Inbound | Order | `POST /inventory/release` | Sync |
| Inbound | Order | `OrderCancelled` | Async |
| Inbound | Order | `OrderCompensationTriggered` | Async |
| Inbound | Client (via API Gateway) | `GET /inventory/{sku}` | Sync |
| Inbound | Recommendation | `GET /inventory/{sku}` | Sync |
| Inbound | Cart | Lazy stock/price validation call (internal gRPC, fails open on Cart's side) | Sync |
| Inbound | Admin | Inventory's own replenishment write path (manual trigger) | Sync |
| Outbound | Order | `InventoryReserved` | Async |
| Outbound | Order, Cart | `InventoryReservationFailed` | Async |
| Outbound | Order, Analytics | `InventoryReleased` | Async |
| Outbound | Analytics | `InventoryReplenished` | Async |

No synchronous outbound dependency on any other service — every synchronous edge above is inbound to Inventory (Order's reserve/release, the client/Recommendation read, Cart's lazy validation, Admin's manual replenishment). A mandatory participant in both the Order Saga's success flow (reserve, BRD §12.1) and compensation flow (release, BRD §12.2). Platform's highest-contention service (`docs/PLATFORM_BLUEPRINT.md`); sits in the 99.99% order-path availability tier alongside Order itself. Read-path and Admin-replenishment mechanisms are split across two documented surfaces (public REST `GET /inventory/{sku}` vs. Cart's internal gRPC validation call) — see `architecture.md`'s API Surface Consistency Note for the non-blocking reconciliation carried to the API Design Agent.

## kart-review-service

See [full architecture doc](../services/kart-review-service/architecture.md).

| Direction | Peer | Mechanism | Type |
|---|---|---|---|
| Inbound (client) | Client/Storefront via API Gateway | `POST /reviews`, `GET /reviews?sku=...`, `PATCH /reviews/{id}`, `DELETE /reviews/{id}` | Sync |
| Inbound (client, back-office) | Support/Admin console via API Gateway | `PATCH /reviews/{id}/moderate` | Sync |
| Inbound | Order | `OrderDelivered` (ADR-0005) — projected into Review's own materialized delivered-order record; verified-purchase gate checks this local copy only, never a live call to Order | Async |
| Outbound | Product, Analytics | `ReviewSubmitted` (ADR-0014: Product's copy is denormalized, Review is canonical) | Async |
| Outbound | Product, Analytics | `ReviewUpdated` (new; retry/DLQ tier not yet registered — carried to Event Design Agent stage) | Async |
| Outbound (external, non-platform) | Automated content-safety classifier | Synchronous blocking pre-check inside `POST /reviews`/`PATCH /reviews/{id}`; fail-safe-to-human-queue circuit breaker on timeout/unavailability | Sync |

No synchronous outbound dependency on any other **platform** service — the verified-purchase gate deliberately uses event-carried state transfer instead of a live call to Order, to avoid coupling Review's write-path availability to Order's. Not a participant in the Order Saga (BRD §12). The one true synchronous dependency (the content-safety classifier) is external/cross-cutting infrastructure, not a platform bounded-context peer, and is designed to fail safe (to the human moderation queue), never open.

## kart-wishlist-service

See [full architecture doc](../services/kart-wishlist-service/architecture.md).

| Direction | Peer | Mechanism | Type |
|---|---|---|---|
| Inbound (client) | Client/Mobile/Web via API Gateway | `/wishlist` (add/list/remove) | Sync |
| Inbound | Product | `ProductPriceChanged` | Async |
| Inbound | Product | `ProductDiscontinued` | Async |
| Inbound | User Service | `UserDataErased` | Async |
| Outbound | Notification, Analytics | `WishlistPriceAlertTriggered` | Async |
| Outbound (background job only) | Product | `GET /products/{id}` (hourly reconciliation) | Sync |

No synchronous outbound dependency sits on the request/critical path — the one synchronous edge (`GET /products/{id}`) is scoped entirely to an hourly reconciliation job, never to `/wishlist` reads or `ProductPriceChanged` alert evaluation. Not a participant in the Order Saga (BRD §12). Write-side datastore ambiguity carried from requirement-spec §6 item 4 resolved in `architecture.md`: PostgreSQL write side + MongoDB read side, following the platform's default CQRS split — not a deliberate Mongo-only exception. `ProductDiscontinued` (now approved, `kart-product-service/event-contract.md`) and `UserDataErased` (ADR-0016, which already names Wishlist by name) are two new async inbound edges added by this pass, both consistent with `kart-product-service`'s and `kart-user-service`'s own already-approved docs — neither introduces a synchronous dependency or changes the Distributed-Monolith Risk assessment below.

## kart-category-service

See [full architecture doc](../services/kart-category-service/architecture.md).

| Direction | Peer | Mechanism | Type |
|---|---|---|---|
| Inbound (client) | Client/Storefront via API Gateway | `GET /categories` | Sync |
| Inbound (service-to-service) | Admin Service | `POST/PATCH /categories/{id}`, `POST /categories/{id}/move`, `DELETE /categories/{id}` (ADR-0010) | Sync |
| Outbound | Analytics | `CategoryUpdated` (ADR-0004, ADR-0008) | Async |

No synchronous outbound dependency on any other service — the one inbound sync edge (Admin's catalog-management calls) is a low-frequency control-plane dependency, not a chatty chain. Not a participant in the Order Saga (BRD §12); served directly from PostgreSQL, no separate Mongo read model (ADR-0011). No wired edge to Product/Search today — both hold denormalized category copies but neither is a confirmed `CategoryUpdated` consumer yet (ADR-0008's own stated scope boundary; each service's own future call).

## kart-identity-service

See [full architecture doc](../services/kart-identity-service/architecture.md).

| Direction | Peer | Mechanism | Type |
|---|---|---|---|
| Inbound (client, via API Gateway) | Customer / Support Agent / Admin / Partner API clients | `/auth/login`, `/auth/refresh`, `/auth/logout`, `/auth/mfa/verify`, `/auth/password/reset-initiate`, `/auth/password/reset-confirm` | Sync |
| Inbound (browser redirect) | Enterprise IdP (Okta / Azure AD / Google Workspace) | SAML ACS / OIDC callback | Sync (inline, cannot be deferred) |
| Inbound (browser redirect) | Social IdP (Google / Apple) | OIDC callback | Sync (inline) — resolves to `Customer` role only, never elevated |
| Inbound (service-to-service) | Admin Service | `POST /internal/users/{userId}/lock`, `.../unlock` | Sync (internal, client-credentials, `Admin`-scoped only) |
| Inbound (edge, cached, low-frequency) | API Gateway | JWKS public-key retrieval (RS256 local signature verification) | Sync, but not a per-request coupling |
| Shared-state (not a service call) | API Gateway | Redis-backed revocation list (`identity:revocation:*`) | Shared infra — Identity writes on logout/role-change/lock, Gateway reads on every authenticated request |
| Outbound (published) | User, Notification, Analytics | `UserRegistered` | Async (3x retry, `identity.dlq`, ADR-0007) |
| Outbound (published) | Analytics | `SessionCreated` | Async (2x retry, `identity.dlq`, ADR-0007) |
| Outbound (published) | User | `UserAccountUpdated` | Async (2x retry, `identity.dlq`, ADR-0006) |
| Outbound (external) | Enterprise IdP | SAML AuthnRequest / OIDC authorization request | Sync, per-IdP bulkhead |
| Outbound (external) | Social IdP | OIDC authorization request | Sync, own bulkhead group |

No synchronous outbound dependency on any other **internal** Kart service — Identity's only synchronous outbound calls are to external IdPs it does not control (the explicit reason it holds "sole point of contact" status, BRD §24.2); its only synchronous inbound internal-service edge is Admin Service's lock/unlock call (ADR-0010), which matches the outbound edge already recorded from Admin's own side. Platform's highest availability tier (99.99%) — every service's RBAC resolution runs through Identity at token-mint time (BRD §24.1) and every authenticated request is gated by a JWT it minted, though this is a design-time/mint-time coupling resolved locally at the Gateway edge via a cached public key, not a live per-request call (see `architecture.md`'s Distributed-Monolith Risk section). Not a participant in the Order Saga (BRD §12). Consumes no events by design — the admin-lock/unlock trigger is a synchronous inbound API call, not an event.
