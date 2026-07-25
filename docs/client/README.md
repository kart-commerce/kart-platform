---
doc_type: index
service: null
status: living-document
---

# Kart Client Applications — Design Record Index

Same purpose as [`docs/services/README.md`](../services/README.md), for the client tier instead of the backend services: one folder per client app, each with its own requirements → architecture → design-tokens/api-integration record. This is the compiled index — it links out, it doesn't restate.

## Why two client apps, not one

Kart's own architecture already draws this line before this folder existed — [`docs/architecture/container-diagram.md`](../architecture/container-diagram.md) and [`system-context.md`](../architecture/system-context.md) model **`Client / Mobile / Web`** (the `Customer` actor) and the **`Support/Admin Console`** (the `Support Agent`/`Admin` actors) as two distinct consumers of the API Gateway, not one. This folder formalizes that existing split into two Angular applications rather than inventing a new one:

| App | Serves | Repo (planned) | Why separate from the other |
|---|---|---|---|
| [`kart-web`](kart-web/) | `Customer` — the public storefront | `kart-web` | Public, anonymous-heavy traffic at the BRD's full load ceiling (§3: load-tested to 10M RPM, 99.99% availability on the order path) — needs SSR/SEO, a CDN-first edge posture, and PWA/offline behavior that a back-office tool never will. |
| [`kart-admin-web`](kart-admin-web/) | `Support Agent` + `Admin` — the internal back-office console | `kart-admin-web` | Authenticated-only, low-traffic, no SEO/SSR need, different data shape (data grids/dashboards over `kart-admin-service`, `kart-analytics-service`, and read access into other services rather than a shopping funnel). Bundling it into `kart-web` would coincidentally weigh the public storefront down with admin-only code and couple two independently-evolving release cadences — the same "independent deploy" principle the BRD already enforces for every backend service ([`content-placement-policy.md`](../standards/content-placement-policy.md)), applied to the client tier. |

`Partner API Consumer` (BRD §24.1) is non-interactive (client-credentials only) and has no UI — no third client app is needed for it.

**This is a documented engineering default, not a BRD-mandated split** — the BRD never states "two client apps" explicitly, but the actor/console distinction it already draws (§24, `system-context.md`) makes two apps the defensible reading, for the same reasons any two BRD services with materially different scaling/security/release-cadence profiles are never merged into one deployable. This is now formalized in [ADR-0022](../adr/0022-client-app-split-confirmation.md), with the full deployment/scaling/CI-CD/security implications — a future proposal to merge the two apps must supersede that ADR explicitly, not edit this file silently.

## Pipeline stage per app

`kart-web` is the flagship, fully-specified app — it is what the BRD's own scale numbers (§3) and the platform's premium-ecommerce ambition are actually about. `kart-admin-web` is intentionally scoped lighter in this pass (internal tool, not the platform's showcase surface) — its own `requirement-spec.md` says so explicitly and can be expanded later without touching `kart-web`'s docs.

| App | Requirement Spec | Architecture | Design Tokens | API Integration Map | Edge Cases | Design Decisions | Tickets |
|---|---|---|---|---|---|---|---|
| [`kart-web`](kart-web/) | [✅ drafted](kart-web/requirement-spec.md) | [✅ drafted](kart-web/architecture.md) | [✅ drafted](kart-web/design-tokens.md) | [✅ drafted](kart-web/api-integration-map.md) | [✅ drafted](kart-web/edge-cases.md) | [✅ drafted](kart-web/design-decisions.md) | [✅ drafted](kart-web/tickets.md) |
| [`kart-admin-web`](kart-admin-web/) | [✅ drafted](kart-admin-web/requirement-spec.md) | [✅ drafted](kart-admin-web/architecture.md) | — (inherits `kart-web`'s brand tokens via `@kart/design-system`, see [`design-system.md`](design-system.md)) | — (folded into architecture.md, scope is small) | [✅ drafted](kart-admin-web/edge-cases.md) | [✅ drafted](kart-admin-web/design-decisions.md) | [✅ drafted](kart-admin-web/tickets.md) |

### Cross-cutting documents (shared by both apps)

| Document | Covers |
|---|---|
| [`localization.md`](localization.md) | Languages (en/bn/de), detection, persistence, runtime switching, currency (USD/BDT), exchange-rate strategy, order-currency locking, RTL policy |
| [`security.md`](security.md) | Token handling, session-timeout policy (per-app, per-role concrete numbers), PCI DSS scope (SAQ A), OWASP ASVS Level 2 alignment |
| [`privacy.md`](privacy.md) | Cookie consent (categories, banner, preference center, versioning, withdrawal), full GDPR rights (access/export/delete/rectify), audit logging |
| [`design-system.md`](design-system.md) | The `@kart/design-system` shared npm package — how both apps consume tokens/components without sharing source, versioning, CI publishing, backward compatibility |
| [`api-strategy.md`](api-strategy.md) | OpenAPI-generated clients, MSW mocking, mock fixtures, feature flags, API versioning, contract validation, the four-stage 🚧→✅ integration workflow |
| [`approval-checklist.md`](approval-checklist.md) | Architecture / Security / Performance / Accessibility / Frontend-Readiness / Deployment-Readiness review checklists — overall client-tier approval status |

### `kart-web`-specific documents (no SSR/SEO or checkout surface in `kart-admin-web`)

| Document | Covers |
|---|---|
| [`kart-web/seo.md`](kart-web/seo.md) | Exact SSR/CSR page classification, meta tags, structured data, OpenGraph/Twitter cards, canonical URLs, sitemap, robots.txt, lazy hydration, TransferState, route-prerender policy |
| [`kart-web/checkout-and-refunds.md`](kart-web/checkout-and-refunds.md) | Full checkout flow + the customer-initiated return/refund workflow (eligibility, auto-approval fast path, manual review, payment-gateway interaction, notifications, audit trail, fraud prevention) |

Every doc below carries `status: pending-approval` in its frontmatter until a human reviews it — same convention as `docs/services/<name>/`, see [`AGENTS.md`](../../AGENTS.md) §2. See [`approval-checklist.md`](approval-checklist.md) for the consolidated sign-off status of the full client-tier documentation set.

## What each document type is

- **`requirement-spec.md`** — the client app's structured requirements: scope, the technology/architecture decisions made and why, functional requirements grouped by e-commerce capability, NFR targets (traced back to BRD §3 where the client consumes a backend NFR, stated as a client-tier default where the BRD is silent), and open questions.
- **`architecture.md`** — folder structure, the feature-module ↔ backend-microservice consumption map, SSR/hosting/deployment topology, real-time integration points, and how this app's standalone repo relates to `kart-platform`/`agent-reusables`/`kart-devops`/`kart-infra`.
- **`design-tokens.md`** (`kart-web` only) — Kart's actual brand values (palette, type, spacing scale, logo/asset registry) layered on top of `agent-reusables`' project-agnostic `docs/standards/frontend/design-system-standards.md` (resolved via this repo's `reusables.config.json`, same pattern [`kart-conventions.md`](../standards/kart-conventions.md) already uses for the backend).
- **`api-integration-map.md`** (`kart-web` only) — the concrete table an LLM/codegen agent reads to know, for every feature module, which of the 18 backend services + gateway it calls, which endpoints, and whether the channel is REST, real-time (WebSocket/SSE), or both. This is what operationalizes "generate code consistently across all microservices" for the client.

## Relationship to the standards this is built on

Same three-repo split the rest of the platform uses ([`content-placement-policy.md`](../standards/content-placement-policy.md)):

- **Project-agnostic frontend engineering standards** (Angular architecture, coding standards, design-token *system*, state management, networking/resilience, performance, accessibility/i18n, security, testing, observability) live in `agent-reusables/docs/standards/frontend/` — would read identically pasted into a different project. Resolved via `reusables.config.json`, same as every backend standard.
- **Kart-specific content** — the actual brand tokens, the actual 18-service consumption map, the actual feature list mapped to Kart's real domain — lives here, in this folder.
- **Deployable client code** — never here. Once `kart-web`/`kart-admin-web`'s docs are approved, the actual Angular repos are scaffolded as their own `kart-web`/`kart-admin-web` repos, the same way every backend service's code lives in its own `kart-<name>-service` repo, built *from* what's documented here.
