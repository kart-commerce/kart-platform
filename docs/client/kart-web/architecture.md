---
doc_type: architecture
service: kart-web
status: pending-approval
generated_by: human-authored (architecture-agent equivalent, client tier)
source: docs/client/kart-web/requirement-spec.md
---

# Architecture: kart-web

## Boundary Rationale

`kart-web` is the **sole browser-facing entry point for the `Customer` actor** (per `requirement-spec.md` §1). It holds no domain logic of its own — every business rule it appears to enforce (best-discount-wins, oversell prevention, idempotent payment) is actually enforced by the owning backend service; `kart-web` only renders state and disables/re-validates client-side as a UX convenience, never as the actual boundary (same rule as `agent-reusables/docs/standards/frontend/security-standards.md`'s "route guard is UX, not enforcement," generalized to every domain rule, not just auth).

This makes `kart-web` architecturally closer to a thin, fan-out **API Gateway consumer** than to a bounded-context service — it has one synchronous dependency (the Gateway) and one real-time dependency (the Gateway's WS/SSE surface), never a direct dependency on any of the 18 backend services. All 18 are reached exclusively through `kart-api-gateway`, the same rule every other Gateway consumer already follows (`container-diagram.md`).

## Dependencies

| Direction | Peer | Mechanism | Type | Notes |
|---|---|---|---|---|
| Outbound | `kart-api-gateway` | REST, all requests | **Sync** | The only synchronous dependency this app has — no service is ever called directly, bypassing the gateway. |
| Outbound | `kart-api-gateway` (WS/SSE upgrade) | Real-time channel | **Async, push** | Cart sync, live inventory/pricing, order/delivery tracking — see `api-integration-map.md` for the channel-per-feature breakdown. |
| Outbound | Payment Gateway (external) | Hosted tokenization field/redirect | **Sync, direct** | The **one** exception to "never bypass Kart's own gateway" — raw card data must never transit Kart's own infrastructure at all (`requirement-spec.md` §5), so this call goes straight from the browser to the external Payment Gateway's own hosted UI, per `system-context.md`'s existing `System -->|charge, refund| PaymentGW` edge (here, the equivalent edge originates from the browser for tokenization only; the actual charge still flows through `kart-payment-service`). |
| Outbound | CDN | Static assets, images | **Sync** | Per `system-context.md`'s existing `System -.->|offloads static/image traffic| CDN` edge — `kart-web`'s build artifacts and product imagery are CDN-served, not origin-served, from day one. |
| Inbound (fan-in) | Browsers (Customers) | HTTPS | **Sync** | The actual traffic this app exists to serve, at the BRD §3 load ceiling. |

No other Kart repo depends on `kart-web` — it is a leaf in the platform's repository interaction graph (`PLATFORM_BLUEPRINT.md` §12), the same position a pure Gateway consumer occupies.

## Distributed-Monolith Risk

**None identified**, by construction: `kart-web` cannot develop a hidden synchronous coupling to an individual backend service because it structurally cannot reach one — the Gateway is the only address it knows. The one risk worth naming for whoever builds the Gateway integration: if `kart-web`'s SSR tier ever needs to fan out to *multiple* Gateway calls to assemble one page (e.g., PDP needs Product + Inventory + Recommendation + Review data), that fan-out must happen server-side during SSR with parallel requests (per `agent-reusables/docs/standards/frontend/networking-resilience-standards.md`'s batching rule), not serially — a serial fan-out at SSR time directly adds to LCP, the metric §4 of `requirement-spec.md` budgets tightest.

## Repository Folder Structure

Layered on `agent-reusables/docs/standards/frontend/angular-architecture-standards.md`'s generic structure; Kart-specific is the concrete feature list (mapped 1:1 to the bounded contexts in `requirement-spec.md` §3) and the SSR entry points:

```
kart-web/
├── src/
│   ├── app/
│   │   ├── core/
│   │   │   ├── auth/                  # BFF session handling, auth interceptor, silent refresh
│   │   │   ├── http/                  # generated Gateway API clients (per api-integration-map.md)
│   │   │   ├── realtime/              # one WS/SSE connection manager, channel subscriptions
│   │   │   └── config/                # typed environment config (Gateway base URL, feature flags)
│   │   ├── shared/
│   │   │   ├── ui/                    # design-system atoms/molecules/organisms (design-tokens.md consumers)
│   │   │   ├── directives/ pipes/ utils/
│   │   ├── features/
│   │   │   ├── catalog/               # Product + Category + Search + Recommendation + Review (§3.1)
│   │   │   ├── cart/                  # Cart + read-only Inventory (§3.2)
│   │   │   ├── wishlist/              # (§3.2)
│   │   │   ├── pricing-promotions/    # Offer-service consumption shared by cart/checkout (§3.3)
│   │   │   ├── checkout/              # Order + Payment (§3.4)
│   │   │   ├── order-tracking/        # Order history/detail + Shipping + Delivery Tracking (§3.4)
│   │   │   ├── account/               # Identity + User (§3.5)
│   │   │   ├── notifications/         # in-app center + push registration (§3.6)
│   │   │   └── cms/                   # About/FAQ/Terms/Privacy/Help — build-time prerendered, see seo.md §11 tier 2
│   │   └── app.routes.ts              # every features/* entry is lazy
│   ├── server.ts                      # Angular SSR entry point
│   └── main.ts / main.server.ts
├── public/                            # static assets not resolved through the Assets registry (favicon, manifest.webmanifest for PWA)
├── tests/                             # unit/component colocated per feature; e2e/visual/contract test suites separate, per agent-reusables/testing-standards.md
├── Dockerfile                         # multi-stage: build → Node LTS SSR runtime image
└── .github/workflows/ci.yml           # calls kart-devops's reusable workflow, same as every backend repo
```

Notes:
- `pricing-promotions/` is its own feature (not folded into `cart` or `checkout`) because it's genuinely shared by both — cart shows a live quote, checkout re-quotes before payment (per `requirement-spec.md` Domain Invariant #2). Splitting it avoids `cart` and `checkout` each growing a duplicate pricing-display implementation.
- `catalog/` intentionally spans four backend services (Product, Category, Search, Recommendation) plus Review's display surface, because from the customer's perspective "browsing the catalog" is one cohesive capability — splitting it into four UI features to mirror the backend 1:1 would fragment a single user journey for no client-side benefit. This is the frontend analogue of the Offer Service merge rationale (`ADR-0001`): the merge criterion is "what does the user experience as one thing," not "how many backend services answer it."

## SSR / Hosting / Deployment Topology

Exact per-route SSR vs. CSR classification, meta/structured-data/sitemap/robots/hydration mechanics, and the three-tier route-prerender policy (per-request SSR / build-time prerender+webhook rebuild / CSR-only) are fully specified in [`seo.md`](seo.md) — not restated here. Deployment implications of the two-independent-client-app decision (this app vs. `kart-admin-web`) are formalized in [ADR-0022](../../adr/0022-client-app-split-confirmation.md).

- **SSR runtime**: Node LTS, containerized (multi-stage Docker build, matching the backend's own mandatory multi-stage convention), deployed as a stateless K8s workload — no sticky sessions, no in-memory state that would prevent horizontal scaling (the BFF session cookie's actual session state lives server-side in the same session store approach `kart-identity-service` already uses, not in per-pod memory).
- **Static assets** (JS/CSS bundles, images, fonts) are CDN-served with content-hash cache-busting (per the reusable performance standard) — the SSR pods serve rendered HTML and API-proxying only, never raw static file bytes at scale.
- **Scaling**: HPA on the SSR tier, same K8s posture the backend uses (`PLATFORM_BLUEPRINT.md` §15 Standards Catalog: "HPA on custom metrics where consumer-driven, not just CPU") — request-latency/queue-depth-driven scaling, since SSR render time is the tier's actual bottleneck resource, not raw CPU.
- **CI/CD**: `kart-devops`'s reusable workflow (build → lint/typecheck → unit/component tests → contract tests against the Gateway's published contracts → Lighthouse CI budget check → Docker build → deploy), same gate sequence shape as every backend service's pipeline (`PLATFORM_BLUEPRINT.md` §11 Quality Gates), substituting frontend-appropriate tools per gate.
- **Environments**: Local / Development / QA / UAT / Staging / Production, per the backend's own environment list (`kart-conventions.md`-adjacent convention) — no separate environment topology invented for the client.

## Real-Time Integration

`kart-web`'s `core/realtime/` connection manager holds exactly one WS/SSE connection to the Gateway's real-time surface per active session (per `agent-reusables/docs/standards/frontend/networking-resilience-standards.md`'s "one connection manager, not one per feature" rule), multiplexing subscriptions for: cart-sync, inventory/price updates on currently-viewed products, and order/delivery status for any order the customer has open. A dropped connection degrades to the last-cached value plus a visible reconnecting state (same standard) — it never blocks checkout, which always falls back to a synchronous re-quote (Domain Invariant #2) regardless of real-time channel health.

## Sign-off

- [ ] Reviewed by: _pending_
