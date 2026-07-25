---
doc_type: requirement-spec
service: kart-web
status: pending-approval
generated_by: human-authored (requirement-agent equivalent, client tier)
source: docs/requirements/kart-requirements.md, docs/client/README.md
---

# Requirement Spec: kart-web

## 1. Scope

The **single, public-facing Angular application** for Kart's `Customer` actor (BRD §24, `system-context.md`) — browse, search, cart, checkout, order tracking, account, reviews, wishlist. It is the client-side counterpart to all 18 backend service repos, reached exclusively through `kart-api-gateway` (never a direct browser-to-service call — same boundary the gateway already enforces for every other consumer, `container-diagram.md`).

Explicitly **out of scope**: the `Support Agent`/`Admin` back-office experience — that is [`kart-admin-web`](../kart-admin-web/requirement-spec.md), a separate app, per [`docs/client/README.md`](../README.md)'s app-split rationale. A native mobile app is also out of scope for this spec (see §9 Open Questions) — `kart-web` is built PWA-installable so it covers the mobile *web* case, but a native iOS/Android app, if ever built, is a separate BRD-level decision, not an extension of this document.

This spec is heavier on **technology/architecture decisions** than a backend `requirement-spec.md` would be, because unlike a backend service (whose stack is already fixed platform-wide — .NET/ASP.NET Core, per the BRD's header), the client stack has no prior decision on record. §2 makes those calls explicitly, as engineering defaults, so downstream work doesn't re-litigate them per feature.

## 2. Technology & Architecture Decisions

| Decision | Choice | Why |
|---|---|---|
| Framework | Angular, latest stable LTS | Team default going forward; LTS-only avoids running production on an unsupported version. |
| Language | TypeScript, strict mode, zero `any` | Per `agent-reusables/docs/standards/frontend/frontend-coding-standards.md` — matches the backend's own "no substitutions without an ADR" rigor on type safety. |
| Component model | Standalone components, signals-first, RxJS where signals genuinely don't fit (cancellable async, event streams) | Per `agent-reusables/docs/standards/frontend/angular-architecture-standards.md`; this is the current recommended Angular architecture, not a Kart-specific choice. |
| Rendering | **SSR + hydration, mandatory** — not an opt-in | `kart-web` serves anonymous, SEO-dependent, first-load-latency-sensitive traffic at the BRD's load-tested ceiling (§3: 10M RPM, P95 < 150ms read path) — a client-only SPA's blank-screen-then-hydrate cost is not acceptable at that scale or for organic search discovery of the product catalog. |
| Build tooling | Angular CLI, Vite/esbuild-based builder | Per the reusable standard; no Kart-specific override. |
| Repo / deploy unit | New standalone repo `kart-web`, containerized, deployed like any other Kart deployable (reuses `kart-devops` reusable CI workflows and `kart-infra` Helm/K8s bootstrap) | Consistent with the platform's hybrid repo strategy (`PLATFORM_BLUEPRINT.md` §2) — the client is a 19th deployable unit, not special-cased. |
| Offline / installability | **PWA** — installable, offline-tolerant for already-viewed catalog/cart/wishlist content; checkout and payment explicitly require connectivity (never queued offline — see Domain/UX Invariant §8.3) | User-visible resilience on flaky mobile networks; matches the BRD's own "surface eventual consistency, don't hide it" principle (`kart-requirements.md` §12), extended to network state. |
| Design system | Tokens/theming/asset-registry *system* from `agent-reusables/docs/standards/frontend/design-system-standards.md`; Kart's actual brand values in [`design-tokens.md`](design-tokens.md) | Per the content-placement split — the system is reusable, the palette isn't. |
| State management | NgRx Signal Store (or equivalent), feature-scoped stores + a small global store (session, theme, locale, cart-badge projection) | Per `agent-reusables/docs/standards/frontend/state-management-standards.md`; the feature-store boundary below is drawn along Kart's own bounded contexts, not generically. |
| i18n | Runtime-switchable, ICU MessageFormat, RTL-ready from day one even if launch locales are LTR-only. Launch locales: English (default/fallback), Bangla, German — currency (USD, BDT) is an independent axis from language. Full mechanism and values in [`../localization.md`](../localization.md) | Cheaper to build in from the start than retrofit; closes the prior "BRD doesn't state launch locales" gap as an explicit engineering default (§9 resolution #1). |
| Shared design system | Tokens/components published as `@kart/design-system`, a dedicated versioned npm package repo consumed by both `kart-web` and `kart-admin-web` — full architecture in [`../design-system.md`](../design-system.md) | Per ADR-0022's two-independent-apps decision — consistency without shared source, same pattern `kart-shared` already proves at platform scale. |
| Backend dependency / mock strategy | OpenAPI-generated typed clients + MSW-mocked development against `🚧`-flagged endpoints + Unleash feature flags gating not-yet-live features — full workflow in [`../api-strategy.md`](../api-strategy.md) | Operationalizes `api-integration-map.md`'s existing `✅`/`🚧` status key into a concrete build/ship workflow rather than leaving it as prose. |
| Real-time transport | WebSocket/SSE via the API Gateway (not a direct connection to any individual service) — used for cart sync, live inventory/pricing, order tracking | Matches the gateway-only access rule above; concrete channel-per-feature mapping is in [`api-integration-map.md`](api-integration-map.md). |
| Microfrontend posture | Single deployable app; feature-folder boundaries kept Module-Federation-ready per the reusable standard, but Module Federation itself is **not** adopted now | No concrete scaling trigger for it yet (one team, one release cadence) — matches the reusable standard's own anti-premature-abstraction rule. Revisit if/when independent per-feature-team release cadence becomes a real need. |

## 3. Functional Requirements

Grouped by Kart bounded context (BRD §2.1 numbering retained for traceability). Each item is customer-facing behavior; which backend endpoint/event realizes it is [`api-integration-map.md`](api-integration-map.md)'s job, not this section's.

### 3.1 Catalog & Discovery — Product (#3), Category (#4), Search (#5), Recommendation (#18)
- Browse by category (hierarchical navigation, `kart-category-service`'s taxonomy).
- Product listing pages (PLP) and product detail pages (PDP) with variants/attributes (`kart-product-service`).
- Instant/full-text search with filters, facets, ranking, and result highlighting (`kart-search-service`) — debounced-as-you-type, with search-suggestion and empty-state handling.
- Product comparison (BRD-adjacent capability, not a named BRD endpoint — see §9 Open Questions) and "recently viewed" (client-tracked, no dedicated backend service named for it — see §9).
- Personalized recommendations ("customers also bought," homepage/PDP modules) from `kart-recommendation-service`, degrading gracefully (empty/generic fallback, never an error state) if that service is slow or down — matches `kart-recommendation-service`'s own documented fail-open behavior on its Inventory/Product calls (`container-diagram.md`).
- Reviews & ratings display on PDP, submission flow, moderation-aware (a review pending moderation shows differently than a published one) — `kart-review-service`.

### 3.2 Cart & Wishlist — Cart (#7), Wishlist (#13), Inventory (#6, read-only here)
- Add/update/remove cart line items; cart lifecycle including expiry and merge (guest cart → authenticated cart on login) per `kart-cart-service`'s own documented lifecycle.
- Real-time stock/availability indication on PDP and in-cart (reads `kart-inventory-service`; `kart-web` never writes to Inventory directly — reservation happens through Cart/Order, not from the browser).
- Wishlist: save items, price-drop alerts surfaced as in-app/notification-channel alerts (`WishlistPriceAlertTriggered`, consumed via Notification per the Event Catalog) — `kart-wishlist-service`.
- Cart must reconcile consistently across open tabs/devices for the same authenticated session (see Domain/UX Invariant §8.1).

### 3.3 Pricing & Promotions — Offer (#10–12: Coupon/Pricing/Promotion merge)
- Live price quote display (tax/currency-aware) at cart and checkout via `kart-offer-service`'s `/pricing/quote`.
- Coupon code entry/validation (`/coupons/validate`) with clear, specific rejection reasons (expired, limit reached, not applicable to cart contents) — never a generic "invalid code."
- Active promotions/campaigns surfaced on PLP/PDP/cart (`/promotions/active`), including flash-sale countdown UI where a campaign has a defined end time.
- Best-discount-wins is the platform's resolved pricing rule (no stacking, per `kart-offer-service/ddd-model.md`) — the UI must reflect exactly one applied discount at a time and never imply stacking is possible (no "+" affordance next to an already-applied promo/coupon).

### 3.4 Checkout & Fulfillment — Order (#8), Payment (#9), Shipping (#16), Delivery Tracking (#17)
- Guest checkout (no forced account creation) and authenticated checkout, both supported.
- Multiple saved addresses and saved payment methods (tokenized, never a raw card number touching `kart-web`'s own code — see §4 Security).
- Order placement against `kart-order-service`'s saga-orchestrated flow; the UI surfaces the BRD's own documented eventual-consistency window as an explicit "processing your order" state (`kart-requirements.md` §12), never a fake-instant confirmation that later silently fails.
- Order history, order detail, order cancellation (while cancellable per Order's own state machine), self-service return/refund request submission from `Delivered` — full workflow (eligibility, approval, partial/full, notifications) in [`checkout-and-refunds.md`](checkout-and-refunds.md).
- Real-time order/delivery tracking with carrier ETA (`kart-shipping-service`, `kart-delivery-tracking-service`), pushed over the real-time channel where available, polled as a fallback.
- Idempotent submission on every money-moving action (place order, submit payment, request refund) — the UI generates and attaches an `Idempotency-Key` per the backend's own mandatory-header rule (`api-standards.md`) and disables the submit control until a response (success or failure) is received, preventing double-submit from a network retry or an impatient double-click.

### 3.5 Identity & Account — Identity (#1), User (#2)
- Registration, native login, social login (Google/Apple per BRD §24.2), MFA challenge flow where required.
- Session handling per `agent-reusables/docs/standards/frontend/security-standards.md` — silent refresh, device/session logout ("log out this device" / "log out everywhere").
- Profile, addresses, and preference management (`kart-user-service`).
- Password reset, email verification flows.

### 3.6 Notifications — Notification (#15)
- In-app notification center reflecting the platform's actual notification fan-out (order updates, price-drop alerts, promotions the user opted into) — `kart-web` renders/displays notifications; it does not own delivery (that's Notification Service's job across email/SMS/push).
- Browser push notifications (opt-in, permission-gated) for the subset of alerts that make sense as a push (order shipped/delivered, price-drop) — never defaulted-on without explicit consent.

### 3.7 Cross-Cutting UX Capabilities
- Toast/snackbar transient feedback for every mutating action (add-to-cart, coupon applied, item saved to wishlist), consistent placement/timing across the app (design-system concern, not per-feature bespoke).
- Skeleton loading states matching real content dimensions (per the reusable performance standard's CLS rule) for every data-dependent view — PLP, PDP, cart, order history.
- Optimistic UI for low-risk, easily-reversible actions (add-to-wishlist, add-to-cart) — the UI updates immediately and reconciles/rolls back on a failure response, never blocking on a round-trip for these; **not** applied to money-moving actions (payment, order placement), which always wait for a confirmed response per the idempotency rule in §3.4.

## 4. Non-Functional Requirements

Traced to the BRD's global NFR table (§3) where the client consumes a backend-stated target; stated as a client-tier engineering default (flagged `[default]`) where the BRD is silent.

| Category | Target | Source |
|---|---|---|
| Availability | 99.99% (order-path pages: cart/checkout/order-tracking), 99.9% secondary | BRD §3, inherited — the client can't exceed what the backend guarantees, but it must not be the weaker link (see Reliability row below) |
| Read-path latency (perceived) | LCP < 2.0s, matches backend's P95 < 150ms read-path budget plus rendering/network overhead budget | BRD §3 backend figure + `agent-reusables/docs/standards/frontend/performance-standards.md` `[default]` |
| Write-path latency (perceived) | Checkout/payment submission feedback within backend's P95 < 300ms write-path budget plus a bounded UI processing-state window | BRD §3 |
| Lighthouse Performance | ≥ 95 on PLP/PDP/home/checkout | `[default]`, reusable standard |
| Accessibility | WCAG 2.2 AA | `[default]`, reusable standard — BRD doesn't state an a11y target; this platform's own premium-enterprise ambition (this doc's mandate) makes AA the floor, not a stretch goal |
| Browser support | Latest Chrome, Edge, Firefox, Safari; progressive enhancement/graceful degradation elsewhere | `[default]` |
| Test coverage | ≥ 90% business logic (stores, validators, pricing/cart-reconciliation logic), ≥ 80% overall | `[default]`, reusable standard |
| Observability | 100% trace coverage on the order/checkout path (matches BRD §23's own order-path tracing mandate, extended client-side) | BRD §23 + reusable observability standard |
| Security | OWASP Top 10, CSP, no plaintext token storage (§5) | BRD §3/§24 + reusable security standard |
| Scalability | CDN-first static/edge delivery; SSR tier horizontally scaled behind the same load posture as the backend's own 10M-RPM load-tested ceiling (BRD §3) — the client must not be the component that "breaks first at 10x traffic" (BRD §23 Q38's own framing, now answered for this tier: CDN + stateless SSR pods scale horizontally, no sticky session dependency) | BRD §3, §23 |
| i18n | Full runtime i18n with RTL support (§2); 3 launch locales (en/bn/de), 2 currencies (USD/BDT) | [`../localization.md`](../localization.md) |
| Cookie/Privacy compliance | Full GDPR rights (access/export/delete/rectify) + categorized cookie consent w/ versioning | [`../privacy.md`](../privacy.md) |

## 5. Security Requirements (client-tier specifics)

Full rules in `agent-reusables/docs/standards/frontend/security-standards.md`; the Kart-specific instances:

- Access/refresh tokens issued by `kart-identity-service` are held per the BFF pattern (SSR server holds the token; browser holds only an `HttpOnly`/`Secure`/`SameSite` session cookie) — `kart-web`'s SSR tier already exists (per §2's mandatory-SSR decision), so the BFF pattern is the natural fit, not the in-memory-SPA fallback.
- Saved payment methods are tokenized by the payment gateway (BRD's own "tokenized card processing" boundary, `system-context.md`) — `kart-web` never receives, stores, or transmits a raw PAN; the card-entry UI posts directly to the gateway's own hosted field/tokenization endpoint, and Kart's backend only ever sees the resulting token.
- Role-gated UI: `kart-web` only ever renders the `Customer` role's surface — a `Support Agent`/`Admin` credential must never grant access to anything in this app (that's `kart-admin-web`'s job). This is enforced server-side (the gateway/Identity-issued token scoping), not just by this app choosing not to render admin UI.
- Session-timeout numbers, PCI DSS scope confirmation (SAQ A — no card data ever transits this app), and OWASP ASVS Level 2 alignment are specified in full in [`../security.md`](../security.md), shared with `kart-admin-web`.
- Cookie consent categorization/banner mechanics and full GDPR rights (access/export/delete/rectification) are specified in [`../privacy.md`](../privacy.md).

## 6. Consumed API / Event Surface (summary)

Full per-feature detail (endpoints, real-time channels, auth scope) lives in [`api-integration-map.md`](api-integration-map.md). Summary of backend touchpoints, all routed through `kart-api-gateway`:

`kart-identity-service`, `kart-user-service`, `kart-product-service`, `kart-category-service`, `kart-search-service`, `kart-inventory-service` (read-only), `kart-cart-service`, `kart-order-service`, `kart-payment-service`, `kart-offer-service`, `kart-wishlist-service`, `kart-review-service`, `kart-notification-service` (in-app rendering + push registration), `kart-shipping-service`, `kart-delivery-tracking-service`, `kart-recommendation-service`.

Not consumed by `kart-web`: `kart-analytics-service` (ingests client events, never serves data back to this app — that's `kart-admin-web`'s dashboard concern) and `kart-admin-service` (back-office only, out of scope per §1).

## 7. Design System & Anti-Hardcoding Requirements

Governed by `agent-reusables/docs/standards/frontend/design-system-standards.md` in full; not restated here. Kart's own token values, theme list (light/dark/system, single-brand — no white-label requirement identified for Kart itself, resolved as out of scope, §9 resolution #5), and asset registry are [`design-tokens.md`](design-tokens.md). The cross-app distribution mechanism (how `kart-web` and `kart-admin-web` both consume these tokens/components without sharing source) is [`../design-system.md`](../design-system.md).

## 8. Domain / UX Invariants

The frontend-tier equivalent of a backend requirement-spec's "Domain Invariants" — rules that must hold regardless of implementation detail, seeding `architecture.md` and any future frontend-facing design-decision work:

1. **Cart consistency across sessions.** A cart's displayed contents must always reconcile with `kart-cart-service`'s authoritative state within the same bounded staleness window the backend itself documents for Cart — the UI never invents a client-only cart state that can permanently diverge from the server (e.g., a locally-added item that silently fails to persist must surface as an error, not a phantom success).
2. **Price shown must never be staler than the last known `PriceQuoteIssued`/`ProductPriceChanged` event for that item** at the point of checkout — if the client's cached price could be stale (e.g., the cart was left open across a promotion change), checkout re-quotes before allowing payment submission, never charges against a possibly-stale cached number.
3. **Money-moving actions never queue offline.** Per the PWA decision in §2 — add-to-cart/wishlist may be queued and synced when connectivity returns, but "place order" and "submit payment" are disabled (with a clear "you're offline" state) rather than silently queued, since a queued payment submitted minutes later against a possibly-changed cart/price is exactly the staleness invariant #2 exists to prevent.
4. **Stock/availability display must never show "in stock" once the backend has signaled otherwise** (an `InventoryReleased`/reservation-exhausted signal invalidates a cached "in stock" badge) — an overselling UI bug is a customer-trust failure even if the backend's own oversell-prevention invariant (BRD §2.2) still holds at the transaction level.
5. **No dark patterns.** Countdown timers, "only N left" scarcity indicators, and pre-checked upsell/marketing-consent checkboxes only render when backed by a real, backend-sourced value — never a fabricated client-side number or a default-checked consent box. This is a professionalism/trust requirement this doc sets explicitly since the BRD is silent on it and a "premium enterprise" ambition (this doc's own mandate) forecloses the alternative.

## 9. Resolved Decisions (formerly Open Questions)

The BRD is written from a backend/systems-design-curriculum angle (§1.1–1.2) and does not specify client-tier scope in the same depth it specifies backend services. Each gap previously flagged here has been closed with a concrete engineering default — this section is now a decision log, not a list of open items:

1. **Launch locales/currencies — RESOLVED.** English (default/fallback), Bangla, German; USD/BDT as an independent axis from language. Full detection/persistence/formatting mechanism in [`../localization.md`](../localization.md).
2. **Product comparison and "recently viewed" — RESOLVED, final.** Both are client-local only: "recently viewed" persists in IndexedDB, capped at 50 entries, no backend persistence and no cross-device sync; product comparison is a thin client-side feature (selected SKUs held in-memory/session, resolved against already-fetched Product data) with no dedicated backend endpoint. If cross-device persistence is ever required, that is new backend scope requested explicitly through the normal requirement-spec process for the owning service — not a silent client-side workaround.
3. **Native mobile app — confirmed out of scope**, not merely deferred. `kart-web`'s PWA installability (§2) is this platform's complete answer to mobile access absent a stated native-app requirement. A native app, if ever commissioned, consumes the same `kart-api-gateway` contracts and is scoped as its own client repo, entirely outside this document.
4. **SSR/SEO extent — RESOLVED.** Exact page-by-page classification (SSR: Home/Category/PLP/PDP/Brand/Search/CMS; CSR-only: Login/Register/Cart/Checkout/Account/Wishlist/Orders) plus meta/structured-data/sitemap/robots/hydration mechanics are fully specified in [`seo.md`](seo.md).
5. **White-label/multi-brand support — confirmed out of scope for Kart itself, final.** The token architecture in `design-tokens.md`/`../design-system.md` structurally supports a second brand at no retrofit cost, but Kart operates one brand — this is recorded as "supported by construction, not exercised," and stays that way unless a future BRD-level decision states otherwise.
