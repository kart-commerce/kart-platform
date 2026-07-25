---
doc_type: api-integration-map
service: kart-web
status: pending-approval
generated_by: human-authored (client tier)
source: docs/client/kart-web/requirement-spec.md, docs/architecture/container-diagram.md
---

# API Integration Map: kart-web

The concrete, per-feature record of which backend service(s) `kart-web` calls, through what channel, and under what auth scope. This is what a coding/scaffold agent reads to wire up a feature module consistently — it should never need to re-derive "which service does this feature talk to" from prose each time.

**Endpoint status key**: ✅ = confirmed from an approved backend doc (cited); 🚧 = service exists and is architected, but this exact customer-facing endpoint isn't in an approved `api-contract.yaml` yet — build against the generated client once published, don't hand-guess the shape in the meantime. Every route below goes through `kart-api-gateway`; no row bypasses it except the one explicitly flagged in the Payment section.

## Catalog & Discovery

| Feature | Service | Endpoint(s) | Channel | Auth | Notes |
|---|---|---|---|---|---|
| Product detail | `kart-product-service` | `GET /products/{id}` ✅ (`container-diagram.md`) | REST | Public | Also the endpoint Wishlist/Recommendation call server-side for the same product — same generated client type reused, not redefined per feature |
| Category navigation | `kart-category-service` | 🚧 taxonomy/hierarchy read endpoints | REST | Public | |
| Search | `kart-search-service` | 🚧 full-text/filter/facet query endpoint | REST | Public | Debounced client-side; server does the actual ranking — client never re-implements ranking logic |
| Recommendations | `kart-recommendation-service` | 🚧 "customers also bought" / personalized feed | REST | Public (anonymous gets generic feed; personalization requires session) | Fails open per `container-diagram.md`'s own documented behavior when Recommendation calls Inventory/Product — `kart-web` must fail open identically (render nothing/generic, never an error block) if this call itself times out |
| Reviews & ratings | `kart-review-service` | 🚧 list/submit review endpoints | REST | Read: public. Submit: authenticated | Moderation-pending reviews render differently — see `requirement-spec.md` §3.1 |

## Cart & Wishlist

| Feature | Service | Endpoint(s) | Channel | Auth | Notes |
|---|---|---|---|---|---|
| Cart CRUD | `kart-cart-service` | 🚧 add/update/remove line item, get cart | REST | Guest session or authenticated | Guest→authenticated merge on login is this service's own documented lifecycle behavior — client doesn't reimplement the merge, just calls it |
| Stock/availability display | `kart-inventory-service` | `GET /inventory/{sku}` ✅ (pattern per `container-diagram.md`'s Recommendation edge) | REST + real-time (below) | Public | Read-only from `kart-web` — reservation happens via Cart/Order server-side, never a direct client write to Inventory |
| Wishlist | `kart-wishlist-service` | 🚧 add/remove/list wishlist items | REST | Authenticated | Price-drop alert delivery is Notification's job (see below), not a `kart-web` poll |

## Pricing & Promotions

| Feature | Service | Endpoint(s) | Channel | Auth | Notes |
|---|---|---|---|---|---|
| Price quote | `kart-offer-service` | `POST /pricing/quote` ✅ (`kart-offer-service/architecture.md`) | REST | Guest or authenticated | Re-called at checkout regardless of cart-time value — Domain Invariant #2, `requirement-spec.md` |
| Coupon validation | `kart-offer-service` | `POST /coupons/validate` ✅ | REST | Guest or authenticated | Specific rejection reason surfaced verbatim from the response, never genericized |
| Active promotions | `kart-offer-service` | `GET /promotions/active` ✅ | REST | Public | Cached read per Offer's own Redis-backed read path — client should respect the response's own cache headers, not add a second ad hoc TTL |

## Checkout & Fulfillment

| Feature | Service | Endpoint(s) | Channel | Auth | Notes |
|---|---|---|---|---|---|
| Place order | `kart-order-service` | `POST /orders` ✅ (`container-diagram.md`) | REST | Authenticated or guest-checkout session | `Idempotency-Key` header mandatory, per `requirement-spec.md` §3.4 |
| Order detail / status | `kart-order-service` | `GET /orders/{id}` ✅ | REST + real-time (below) | Owner-scoped | |
| Cancel order | `kart-order-service` | `POST /orders/{id}/cancel` ✅ | REST | Owner-scoped | Only while Order's own state machine allows it — a disabled control, not a call that's expected to fail, once the state machine has moved past cancellable |
| Payment submission | `kart-payment-service` (tokenization: external Payment Gateway, direct) | Tokenization: external gateway's hosted field, **not through `kart-api-gateway`** (`requirement-spec.md` §5). Charge itself: `POST /payments/charge` ✅, marked "secondary path" in `container-diagram.md` — the primary charge trigger is Order's own saga-internal call to Payment, not a direct customer-facing charge endpoint in the common case | REST (+ external direct for tokenization) | Authenticated or guest-checkout session | `Idempotency-Key` mandatory; raw PAN never transits `kart-web`'s own code, per Security §5 |
| Return/refund request (customer-initiated) | `kart-order-service` (new `ReturnRequest` sub-resource, see `checkout-and-refunds.md`) → triggers existing `kart-payment-service` `POST /payments/{id}/refund` on approval | 🚧 `POST /orders/{id}/return-request` (new — ticketed, not yet in an approved `api-contract.yaml`) | REST | Owner-scoped | **RESOLVED** — full eligibility/approval/notification workflow in [`checkout-and-refunds.md`](checkout-and-refunds.md); `kart-web` submits a request, it never calls `/payments/{id}/refund` directly (that call remains system/Support-Agent/Admin-driven, per its existing "support-agent driven" scoping) |
| Shipment/delivery tracking | `kart-shipping-service`, `kart-delivery-tracking-service` | 🚧 tracking/ETA read endpoint | REST + real-time (below) | Owner-scoped | Delivery Tracking's own terminal-only event (`DeliveryStatusUpdated`, delivered status) is the trigger for the real-time push — intermediate carrier statuses may only be available via the polling fallback `container-diagram.md` documents for Delivery Tracking itself |

## Identity & Account

| Feature | Service | Endpoint(s) | Channel | Auth | Notes |
|---|---|---|---|---|---|
| Login / logout / refresh | `kart-identity-service` | `/auth/login`, `/auth/refresh`, `/auth/logout` ✅ (`container-diagram.md`) | REST | Public → authenticated | Refresh handled by the auth interceptor transparently, per `agent-reusables/security-standards.md` |
| MFA challenge | `kart-identity-service` | `/auth/mfa/verify` ✅ | REST | Mid-auth-flow | |
| Password reset | `kart-identity-service` | `/auth/password/reset-initiate`, `/auth/password/reset-confirm` ✅ | REST | Public | |
| Social login | `kart-identity-service` (federates to Social IdP) | Browser redirect flow, resolves to `Customer` role only ✅ (`container-diagram.md`) | REST + redirect | Public | `kart-web` never talks to Google/Apple directly — Identity terminates the federation, per `system-context.md` |
| Profile / addresses / preferences | `kart-user-service` | 🚧 profile CRUD, address CRUD | REST | Authenticated | |

## Notifications

| Feature | Service | Endpoint(s) | Channel | Auth | Notes |
|---|---|---|---|---|---|
| In-app notification center | `kart-notification-service` | 🚧 list/mark-read endpoint | REST + real-time (below) | Authenticated | `kart-web` renders; delivery fan-out (email/SMS/push) is this service's own job, not duplicated client-side |
| Push registration | `kart-notification-service` | 🚧 device/push-token registration endpoint | REST | Authenticated, opt-in | Never registered without explicit user permission grant (browser permission prompt), per `requirement-spec.md` §3.6 |

## Real-Time Channels (via `kart-api-gateway`'s WS/SSE surface)

| Channel | Backing event(s) | Consumed by feature | Fallback if disconnected |
|---|---|---|---|
| Cart sync | Cart service's own cross-tab/device state | `cart` | Re-fetch cart on reconnect/focus |
| Live inventory | `InventoryReserved` / `InventoryReservationFailed` / `InventoryReleased` (Event Catalog) | `catalog` (PDP), `cart` | Last-known cached value + "checking availability" indicator |
| Live price/promotion | `PriceQuoteIssued`, `PromotionActivated`/`Deactivated` | `pricing-promotions` | Re-quote synchronously at checkout regardless (Domain Invariant #2) — real-time is a UX nicety here, never the source of truth at the moment of payment |
| Order/delivery status | `OrderConfirmed`/`Cancelled`/`Delivered`, `ShipmentDispatched`, `DeliveryStatusUpdated` (terminal) | `order-tracking` | Poll `GET /orders/{id}` on an interval |
| In-app notifications | Notification Service's own fan-out | `notifications` | Poll notification list endpoint on reconnect |

## Not Consumed by `kart-web`

- `kart-analytics-service` — `kart-web` is a **producer** into Analytics' ingestion pipeline (client-side events: `ProductViewed`, `ProductClicked`, `SearchPerformed`, per `container-diagram.md`'s `ClickstreamSource` node), never a consumer of its dashboards/reports. Analytics dashboards are `kart-admin-web`'s concern.
- `kart-admin-service` — back-office only, out of scope per `requirement-spec.md` §1.

## Remaining Notes

1. **Customer-initiated return/refund request — RESOLVED**, see `checkout-and-refunds.md`. The remaining 🚧 is purely mechanical: `kart-order-service`'s own docs need the `ReturnRequest` sub-resource and `POST /orders/{id}/return-request` formalized (tracked in `tickets.md`), not a design decision.
2. **Every 🚧 row** resolves automatically once that service's `api-design-agent` stage produces an approved `api-contract.yaml`, per the four-stage lifecycle in [`../api-strategy.md`](../api-strategy.md) §8 — this map's status flips from 🚧 to ✅ at that transition, not left stale.
3. **Locale/currency negotiation** — every REST call in this map additionally carries the active locale/currency (header or query param, generated-client-injected, never per-feature hand-wired) per [`../localization.md`](../localization.md); `kart-offer-service`'s pricing/quote calls are the one row where the currency value materially changes the response, not just its formatting.
