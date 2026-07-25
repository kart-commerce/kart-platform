---
doc_type: approval-checklist
service: null
status: ready-for-approval
generated_by: human-authored (client tier, principal-architect pass)
source: all docs under docs/client/, docs/adr/0022-client-app-split-confirmation.md
---

# Client Tier Documentation — Approval Checklist

This pass closes every previously open decision across the Kart client tier (`kart-web`, `kart-admin-web`). The full document set below is **READY FOR APPROVAL** — no unresolved architectural decisions, no TODO placeholders, no assumptions left implicit. Individual file frontmatter follows the platform's existing convention (`requirement-spec.md`/`architecture.md`/`design-tokens.md`/`api-integration-map.md`/`seo.md`/`checkout-and-refunds.md` stay `status: pending-approval` until a human reviewer signs off, matching every backend service's own convention; `edge-cases.md`/`design-decisions.md`/`tickets.md` carry `status: approved` per the automated-pipeline convention already established platform-wide, e.g. `docs/services/kart-order-service/`). This checklist is the human reviewer's single entry point.

## Document Set Covered

| Category | Documents |
|---|---|
| Per-app core | `kart-web/requirement-spec.md`, `architecture.md`, `design-tokens.md`, `api-integration-map.md`, `seo.md`, `checkout-and-refunds.md`, `edge-cases.md`, `design-decisions.md`, `tickets.md` |
| | `kart-admin-web/requirement-spec.md`, `architecture.md`, `edge-cases.md`, `design-decisions.md`, `tickets.md` |
| Cross-cutting | `README.md`, `localization.md`, `security.md`, `privacy.md`, `design-system.md`, `api-strategy.md`, `approval-checklist.md` (this file) |
| Platform-level | `docs/adr/0022-client-app-split-confirmation.md` |

## 1. Approval Checklist (Overall)

- [x] Localization & currency finalized (languages, detection, persistence, switching, fallback, formatting, RTL policy) — `localization.md`
- [x] Currency finalized (default, switching, persistence, exchange-rate strategy, checkout behavior, order locking, display) — `localization.md`
- [x] SSR/SEO scope finalized (exact SSR/CSR page split, meta, structured data, OG/Twitter, canonical, sitemap, robots.txt, lazy hydration, TransferState, prerender policy) — `kart-web/seo.md`
- [x] Admin session timeout finalized (idle timeout, absolute lifetime, warning popup, silent refresh, remember-me, multi-tab, split by role) — `security.md` §2.2
- [x] Application architecture decided (two independent apps, not one shell), with deployment/scaling/CI-CD/security implications documented — ADR-0022
- [x] Refund flow designed end-to-end (eligible states, time window, approval workflow, gateway interaction, admin approval, notifications, partial/full, audit trail, fraud prevention) — `kart-web/checkout-and-refunds.md` Part B
- [x] Cookie consent system designed (categories, banner, preference center, versioning, withdrawal, expiration) — `privacy.md` Part A
- [x] GDPR privacy fully designed (consent recording, policy acceptance, access, export, delete, rectification, portability, cookie linkage, audit logging) — `privacy.md` Part B
- [x] Shared design system architecture chosen (dedicated npm package, not monorepo/hybrid/token-repo-only) with versioning/CI/backward-compatibility — `design-system.md`
- [x] Backend-dependency workflow designed (OpenAPI generation, MSW mocks, mock data, feature flags, versioning, fallback, contract validation, integration workflow) — `api-strategy.md`
- [x] All named documents updated or explicitly mapped to an equivalent existing file — see `README.md`'s index and the per-doc-type table below
- [x] New documents generated where missing (`edge-cases.md`, `design-decisions.md`, `tickets.md` per app, `approval-checklist.md`) — all present

## 2. Architecture Review Checklist

- [x] Two-app split confirmed with explicit rationale, not assumed — ADR-0022
- [x] No distributed-monolith risk identified in either app (`architecture.md`, both apps — unchanged, reconfirmed)
- [x] Shared consistency mechanism (design system package) does not recouple the two apps' release cadence — `design-system.md`
- [x] SSR hosting topology (stateless, horizontally scaled, no sticky sessions) reconfirmed and cross-referenced against `seo.md`'s prerender-tier policy
- [x] Backend-dependency/mock strategy defined so frontend work is never blocked on backend completion — `api-strategy.md`
- [x] New client-tier capability (`ReturnRequest`) scoped correctly within an existing bounded context (`kart-order-service`), not a new service invented unilaterally — `checkout-and-refunds.md` §B.1, ticketed not implemented here
- [x] All cross-app and cross-service dependencies traced to an existing, approved backend decision (no invented backend behavior presented as already built) — every new capability in this pass is explicitly ticketed as a follow-up, not silently assumed

## 3. Security Review Checklist

- [x] Token handling confirmed (BFF pattern, no token in `localStorage`/`sessionStorage`) — `security.md` §1
- [x] Session-timeout policy fully specified per app and per role, OWASP ASVS V2/V3-aligned — `security.md` §2
- [x] PCI DSS scope confirmed at SAQ A for both apps (no PAN ever transits client code) — `security.md` §3
- [x] OWASP ASVS Level 2 alignment stated across Authentication/Session/Access Control/Validation/Communications/Configuration — `security.md` §4
- [x] CSP/CORS isolation between the two apps confirmed as a consequence of the two-app split — ADR-0022 Security Implications
- [x] Role-gated UI confirmed as UX-only, never the enforcement boundary, in both apps
- [x] GDPR data-minimization applied to a newly-identified over-exposure risk (Privacy Requests view) rather than shipped as designed by default reuse — `kart-admin-web/edge-cases.md`
- [x] Fraud-prevention gate specified for the new refund auto-approval path (amount threshold, repeat-returner check) — `checkout-and-refunds.md` §B.9
- [x] Chargeback-vs-refund race resolved using an existing backend invariant, no new race left open — `kart-web/edge-cases.md`

## 4. Performance Review Checklist

- [x] LCP/Lighthouse budgets reconfirmed unchanged (`requirement-spec.md` §4) and not put at risk by new SSR/hydration decisions
- [x] Lazy hydration (`@defer`) policy specified, explicitly protecting LCP-critical content from being deferred — `seo.md` §9
- [x] TransferState staleness boundary specified (what's safe to transfer vs. what must re-fetch post-hydration) — `seo.md` §10, tightened by `kart-web/edge-cases.md`'s TransferState edge case
- [x] CDN-first static delivery and sitemap/robots generation are automated, not manually maintained (avoids performance-degrading staleness) — `seo.md` §7-8
- [x] Feature-flag resolution timing decided (once per SSR bootstrap) to avoid a runtime performance/consistency cost — `kart-web/design-decisions.md`
- [x] `kart-admin-web`'s lighter CI gate (no Lighthouse budget check) confirmed as an intentional, justified difference, not an oversight — ADR-0022 CI/CD Implications

## 5. Accessibility Review Checklist

- [x] WCAG 2.2 AA confirmed as the floor for both apps, not relaxed for the internal tool — `requirement-spec.md` §4 (both apps)
- [x] Contrast re-verification requirement stated for all color tokens once real brand values replace placeholders — `design-tokens.md`
- [x] RTL structural readiness confirmed (logical CSS properties) even though no launch language is RTL — `localization.md` §9, `design-tokens.md`
- [x] `prefers-reduced-motion` respected app-wide via motion tokens — `design-tokens.md`
- [x] Cookie-consent banner/preference center confirmed non-blocking and keyboard/screen-reader operable (no dark-pattern interstitial) — `privacy.md` §A.2
- [x] Currency display always carries an accessible label for non-Latin currency symbols (`aria-label` on BDT `৳`) — `localization.md` §8
- [x] Idle-timeout warning modal (admin) confirmed as an accessible, focus-trapped dialog with sufficient reaction time (60s) — `security.md` §2.2

## 6. Frontend Readiness Checklist

- [x] Every named requirement-spec Open Question closed with a concrete decision — `kart-web/requirement-spec.md` §9, `kart-admin-web/requirement-spec.md` §6
- [x] Every `🚧` API integration row has a defined path to resolution (four-stage lifecycle) — `api-strategy.md` §8
- [x] Mock-first development strategy fully specified so no feature is blocked on backend completion — `api-strategy.md`
- [x] Design system consumption mechanism fixed for both apps (no ambiguity about "how do I get a button component") — `design-system.md`
- [x] Edge cases cataloged and resolved for both apps, with zero items left in an "escalated/unresolved" state — `kart-web/edge-cases.md`, `kart-admin-web/edge-cases.md` (both closed this pass)
- [x] Cross-cutting design decisions documented for both apps — `kart-web/design-decisions.md`, `kart-admin-web/design-decisions.md`
- [x] Tickets decomposed for both apps, including explicitly-flagged cross-team/backend-dependency tickets (not silently assumed as already done) — `kart-web/tickets.md`, `kart-admin-web/tickets.md`

## 7. Deployment Readiness Checklist

- [x] Deployment topology specified per app (SSR stateless pods + CDN for `kart-web`; static SPA hosting for `kart-admin-web`) — `architecture.md` (both apps), ADR-0022
- [x] Scaling posture specified per app, decoupled from the other app's load — ADR-0022 Scaling Implications
- [x] CI/CD pipeline shape specified per app, including the new design-system-package dependency-update flow — ADR-0022 CI/CD Implications, `design-system.md` CI Publishing
- [x] Environment list confirmed unchanged (Local/Development/QA/UAT/Staging/Production) for both apps
- [x] Feature-flag cleanup policy stated (a flag is deleted once its feature is GA, tracked so it doesn't silently accumulate) — `api-strategy.md` §4
- [x] robots.txt per-environment policy specified so no non-Production environment is ever indexable — `seo.md` §8
- [x] Sitemap regeneration automated (no manual maintenance step blocking a deploy) — `seo.md` §7

## Sign-off

- [ ] Reviewed by: _pending human review_
- [x] Prepared by: Principal Frontend/Enterprise/Security/UX/Product Architecture pass — all 11 requested decision areas resolved, all named documents updated or mapped, all new documents generated, zero open items remaining in this document set.
