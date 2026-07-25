---
doc_type: requirement-spec
service: kart-admin-web
status: pending-approval
generated_by: human-authored (requirement-agent equivalent, client tier)
source: docs/requirements/kart-requirements.md, docs/client/README.md
---

# Requirement Spec: kart-admin-web

## 1. Scope

The internal, authenticated-only Angular application for the `Support Agent` and `Admin` actors (BRD §24, `system-context.md`'s `Support/Admin Console`). Scoped deliberately lighter than [`kart-web`](../kart-web/requirement-spec.md) in this pass — it is an internal operations tool, not the platform's public showcase surface, and the user's own detailed enterprise-frontend brief (which drove `kart-web`'s full 30-category treatment) was written with a public storefront in mind. This spec covers what's structurally necessary now; expand it on demand rather than front-loading speculative detail an internal tool doesn't need yet.

Out of scope: anything customer-facing (that's `kart-web`); it does not duplicate `kart-admin-service`'s own backend RBAC logic — this app is a thin consumer of that service's already-defined permission model (`kart-admin-service/requirement-spec.md` §6), not a second implementation of it.

## 2. Technology & Architecture Decisions

Inherits every default from [`kart-web/requirement-spec.md`](../kart-web/requirement-spec.md) §2 (Angular LTS, TS strict, standalone/signals-first, NgRx Signal Store, zero-`any`, `agent-reusables` standards) **except** where the internal-tool profile genuinely differs:

| Decision | Choice | Why it differs from `kart-web` |
|---|---|---|
| Rendering | **Client-side rendering (SPA), no SSR** | No anonymous traffic, no SEO surface — every screen is behind an authenticated `Support Agent`/`Admin` session. SSR's cost (a Node runtime tier, hydration complexity) buys nothing here. |
| PWA / offline | Not required | An internal ops tool with no offline use case named anywhere in the BRD; add later only if a genuine field-support offline scenario emerges. |
| i18n | Single locale (the operating org's own language) at launch, structurally i18n-ready via the same reusable standard, not actively built out | Internal back-office staff, not a global customer base — BRD gives no signal Kart's own back-office operates multi-locale. |
| Deploy scale posture | Standard K8s deployment, no CDN-first/edge posture, no 10M-RPM load target | Internal traffic volume is orders of magnitude below the BRD §3 public ceiling — a handful to low hundreds of concurrent back-office users, not millions of customers. |
| Design tokens | Reuses `kart-web`'s brand tokens ([`design-tokens.md`](../kart-web/design-tokens.md)) directly, distributed via the shared `@kart/design-system` npm package ([`../design-system.md`](../design-system.md)) — no separate token file, no direct dependency on `kart-web`'s own repo | One brand, one design language — an internal tool with a visibly different brand from the storefront it manages would be confusing, not differentiated for a good reason; the package boundary keeps the two repos independent per ADR-0022 while still sharing tokens/components. |

## 3. Functional Requirements

Grouped by the four back-office categories `kart-admin-service` already defines (`kart-admin-service/requirement-spec.md` §6 Decision item 2), plus the two roles' distinct scopes:

### 3.1 Catalog & Inventory Management (`Admin` role)
- Product/category CRUD (`kart-product-service`, `kart-category-service`, via `kart-admin-service`'s own admin-write endpoints, per `container-diagram.md`'s `Admin -->|"sync REST, catalog management"| Product/Category` edges).
- Inventory replenishment (`kart-inventory-service`, per the same diagram's `Admin --> Inventory` edge).
- Coupon/promotion issuance and deactivation (`kart-offer-service`'s admin-only endpoints, per its own `api-contract.yaml`).

### 3.2 Order & Fulfillment Exception Handling (`Admin` role)
- Fulfillment-exception resolution (`POST /orders/{id}/resolve-fulfillment-exception`, per `container-diagram.md`, ADR-0015).
- Order lookup/detail view for support/investigation purposes.

### 3.3 Customer Support Operations (`Support Agent` role, capped grant)
- Order lookup and assisted actions within the Support Agent's capped RBAC grant (BRD §24.1) — refund initiation (`POST /payments/{id}/refund`, "support-agent driven" per `container-diagram.md`).
- Customer account assistance within the same capped grant (no full `Admin` capability).
- **Refund Requests queue** (new, closes `kart-web/checkout-and-refunds.md` §B.4's manual-review path): a worklist of customer-submitted `ReturnRequest`s that failed the auto-approval fast path (over the auto-approval amount threshold, a prior return already exists on the order, a manual-only payment rail, or a repeat-returner signal). Approve (triggers the existing `POST /payments/{id}/refund`, capped at the agent's own per-order grant) or Reject (a reason is mandatory and is shown verbatim to the customer — never a generic rejection, same rule as coupon-validation UX). An amount above the Support Agent's cap surfaces as `Admin`-escalation-required rather than a disabled control with no explanation.

### 3.4 Identity/User Administration (`Admin` role)
- User suspension/lock/unlock (`kart-identity-service`, per `container-diagram.md`'s `Admin --> Identity` edge).
- Permission-grant management — issuing/revoking another principal's category-scoped grant, and viewing the grant list (`kart-admin-service`'s `permission-management` meta-category, `kart-admin-service/requirement-spec.md` §6).

### 3.5 Audit & Compliance (`Admin` role, read-only, coarser access than the write categories above)
- Audit trail viewer over `AdminActionPerformed` (`kart-admin-service`'s own `GET /admin/actions`, deliberately readable by any `Admin`-role holder regardless of category grant, per that service's own spec §4).
- Analytics/compliance dashboards sourced from `kart-analytics-service`'s internal query API (`InternalBI` consumer path, per `container-diagram.md`) — funnels, order volume, the metrics that service's own dashboards expose.

## 4. Non-Functional Requirements

| Category | Target | Note |
|---|---|---|
| Availability | Best-effort, not 99.99% | Internal tool; a brief outage inconveniences staff, it does not stop customer revenue the way `kart-web` downtime would |
| Accessibility | WCAG 2.2 AA | Not relaxed just because it's internal — employees with disabilities still use this tool, per `agent-reusables/docs/standards/frontend/accessibility-i18n-standards.md` |
| Security | Same bar as `kart-web` (§5 below) | An internal tool with elevated privilege is a *higher*-value attack target per credential, not a lower one — never relax security standards for "it's just internal" |
| Test coverage | ≥ 80% business logic, ≥ 70% overall | Slightly relaxed from `kart-web`'s 90/80 given lower blast radius and smaller surface, not a quality shortcut — raise back to `kart-web`'s bar if this app's scope grows materially |

## 5. Security Requirements

- Enterprise SSO federation for `Admin` (BRD §24.2, `system-context.md`'s `Admin -. federates via .-> EnterpriseIdP` edge) — this app's login flow is SAML/OIDC-federated, not a native password form, for the `Admin` role. `Support Agent` may use native login per the platform's coarse role model.
- Every write action's UI surfaces the category-grant check `kart-admin-service` itself enforces (§3 above) — a control for an action the current principal's grant doesn't cover renders disabled/hidden, same "UX convenience, not the enforcement point" rule as `kart-web` (`agent-reusables/docs/standards/frontend/security-standards.md`).
- Session timeout is tighter than `kart-web`'s customer session (elevated-privilege sessions expire faster) — exact figures (idle timeout, absolute cap, warning popup, silent-refresh policy, multi-tab behavior, split by `Admin` vs `Support Agent`) are fully specified in [`../security.md`](../security.md) §2.2, closing the prior Open Question with a concrete, OWASP-ASVS-aligned policy rather than leaving it to be invented per-implementation.

## 6. Resolved Decisions (formerly Open Questions)

1. **Idle-session-timeout duration for elevated sessions — RESOLVED.** `Admin`: 15-minute idle timeout, 24-hour absolute cap (inherits `kart-identity-service`'s existing federated-refresh-token cap, no new number invented). `Support Agent`: 20-minute idle timeout, 8-hour absolute cap (one work shift — an elevated-privilege session never inherits `kart-web`'s 90-day native cap regardless of login method). Full policy, warning-popup timing, silent-refresh, and multi-tab behavior in [`../security.md`](../security.md) §2.2.
2. **One shell, role-gated sections — confirmed, final.** Matches the platform's own "one coarse role model, fine-grained per-service" pattern (BRD §24.1). The `support-console/` feature folder (`architecture.md`) stays structurally isolated from the four `Admin`-only folders specifically so this doesn't quietly become two shells by accretion — revisit only if the two roles' daily workflows prove materially incompatible in practice, which no signal today indicates.
3. **Scope growth** — this spec is intentionally light; expand §3 as `kart-admin-service`'s own back-office categories (§6 of its spec) evolve, rather than this doc drifting stale against that service's own source of truth. Not a gap — a stated maintenance policy.
