---
doc_type: development-plan
service: null
status: living-document
source: docs/services/README.md (build order), docs/client/api-strategy.md (FE workflow), docs/requirements/kart-requirements.md §25 (load tiers), PLATFORM_BLUEPRINT.md §11 (quality gates)
---

# Kart Development Plan — Release Sequencing, FE Timing, Load/Stress Testing

Answers three questions the design docs establish the *rules* for but never assembled into one execution plan: which backend service to build first, when frontend work happens relative to backend, and when load/stress testing happens. This document is the assembly — it does not re-derive decisions already made elsewhere, it links to them. Update the checkboxes as releases complete; this is a living document, not a one-time plan — do not silently re-order releases without a note explaining why (same discipline as `service-boundaries.md`).

---

## Three rules that govern every release below

### 1. Frontend does not wait for backend deployment

Per [`docs/client/api-strategy.md`](client/api-strategy.md) §8, every FE feature moves through a 4-stage lifecycle, independent of whether the real backend service has shipped yet:

1. **Mocked** — built entirely against MSW, generated from the service's *approved* `api-contract.yaml`. Fully implemented, tested, demoable. Feature flag OFF everywhere except Dev/QA.
2. **Contract-Tested** — real contract lands; generated client replaces the mock in an integration-test lane; contract validation passes against a Staging deployment. Flag still OFF in Production.
3. **Staged** — flag ON in Staging/UAT against the real service; one full QA soak cycle, contract-validation gate continuously green.
4. **GA** — flag ON in Production; flag deleted same/next sprint.

**Consequence for planning:** the FE column in the release table below starts the **same release the backend service's contract is approved**, not the release after it deploys. A `🚧`-flagged feature that ships mocked is still "done" for that release's purposes — the backend release two rows down is what flips it live.

### 2. Load testing has two different cadences — don't collapse them

Per BRD §25 (`kart-requirements.md`) and the Performance Tests gate (`PLATFORM_BLUEPRINT.md` §11):

- **Routine, every release:** Baseline (100 RPM) → Low (1K) → Medium (100K) tiers run as part of the standard per-service Performance Tests quality gate, before that service's first production deploy. This is not scheduled separately below — it is inherent to "ship the service."
- **Milestone stress/chaos (High 1M RPM, Extreme 10M+ RPM, BRD §26 chaos suite):** only meaningful once there's a real end-to-end path worth breaking. Scheduled explicitly at specific releases below — running these earlier tests nothing real; skipping them until the very end misses hardening runway for the services that need it most (Inventory, Order Saga).

### 3. Backend sequencing is not re-derived here

The build order below is [`docs/services/README.md`](services/README.md)'s "Recommended Build Order" — already derived from the actual event/API dependency graph and cross-checked against every service's approved docs. This document only groups that existing order into shippable releases and layers FE + load-testing timing on top. If the build order in that file ever changes, this file's release groupings must be re-checked, not assumed still valid.

**Prerequisite for Release 1 (not itself a release):** `kart-shared`, `kart-infra`, `kart-devops` must exist first — every service's Dockerfile/CI calls `kart-devops`'s reusable workflow, and every contract is a versioned `kart-shared` package (`PLATFORM_BLUEPRINT.md` §2.4). Stand up `kart-web`/`kart-admin-web` repo shells + `@kart/design-system` + generated-API-client tooling in the same window. No load test yet — nothing exists to test.

---

## Release Plan

Ticket counts are from each service's own `tickets.md` / the client apps' `tickets.md` (distinct ticket IDs) — use them as *relative* sizing across releases, not calendar estimates; velocity with the agent pipeline is unproven at time of writing. Recalibrate the "weeks" column yourself after Release 1 actually ships.

### Release 1 — Identity & Navigation Foundation

- [ ] Backend: [`kart-identity-service`](services/kart-identity-service/) (26 tickets), [`kart-category-service`](services/kart-category-service/) (6 tickets)
- [ ] Frontend: auth flows (login/register/MFA/SSO/password-reset) in both `kart-web` and `kart-admin-web`; category navigation
- [ ] Load/stress: Identity — Baseline → **Medium** tier minimum (every authenticated request depends on it; this is not optional even at MVP scale)
- **Exit milestone:** a user can register/log in; site navigation renders real categories.

### Release 2 — Catalog & Stock Core

- [ ] Backend: [`kart-inventory-service`](services/kart-inventory-service/) (8), [`kart-delivery-tracking-service`](services/kart-delivery-tracking-service/) (8), [`kart-product-service`](services/kart-product-service/) (7)
- [ ] Frontend: PLP/PDP browsing, stock/availability display
- [ ] Load/stress: **Inventory gets an early High-tier + concurrency/oversell stress test now** — platform's highest-contention service (`SELECT ... FOR UPDATE` hot path); it "wants the longest hardening runway" (`services/README.md`) — do not defer this to Release 5 just because Order hasn't shipped yet.
- **Exit milestone:** browse the full catalog with real stock status.

### Release 3 — Discovery, Pricing & Account

- [ ] Backend: [`kart-user-service`](services/kart-user-service/) (11), [`kart-search-service`](services/kart-search-service/) (13), [`kart-offer-service`](services/kart-offer-service/) (13)
- [ ] Frontend: search bar/results/facets, pricing & promo badges on PDP/PLP, coupon input, profile/address book
- [ ] Load/stress: Search — Medium (read-heavy, 20:1 read:write ratio per BRD §4.4); Offer's pricing-quote path — Medium (documented hot read path)
- **Exit milestone:** search works, prices/promos are real, users manage their profile.

### Release 4 — Cart & Wishlist

- [ ] Backend: [`kart-wishlist-service`](services/kart-wishlist-service/) (9), [`kart-cart-service`](services/kart-cart-service/) (10)
- [ ] Frontend: cart page (add/remove/merge-on-login), wishlist page, price-drop alert UI hooks
- [ ] Load/stress: Cart — Medium → High (checkout-adjacent, sits just upstream of the money path)
- **Exit milestone:** the full pre-checkout shopping experience works end-to-end.

### Release 5 — Money Path: Checkout, Payment, Order Saga ⚠️ highest-priority gate in the plan

- [ ] Backend: [`kart-payment-service`](services/kart-payment-service/) (11), [`kart-order-service`](services/kart-order-service/) (20) — the Saga orchestrator
- [ ] Frontend: full checkout flow ([`kart-web/checkout-and-refunds.md`](client/kart-web/checkout-and-refunds.md)), order confirmation, order history/detail, refund-initiation UI
- [ ] Load/stress: **the big one.**
  - Full Order Saga end-to-end load test at High tier (1M RPM) — Order → Inventory reserve → Payment charge → confirm.
  - Run the full BRD §26 chaos suite against this path: kill an Order pod mid-request, saturate RabbitMQ queue depth, introduce PostgreSQL replica lag, drop 20% inter-service packets.
  - Then an Extreme-tier (10M+ RPM) flash-sale breaking-point test — deliberately find where it degrades and confirm it degrades gracefully, not cascadingly.
- **Exit milestone: MVP-complete.** A customer can actually buy something, and the order-critical-path is hardened for flash-sale scale before you call anything past this point "done." Do not compress this release to hit a date — everything downstream assumes this path is solid.

### Release 6 — Fulfillment Visibility

- [ ] Backend: [`kart-shipping-service`](services/kart-shipping-service/) (16), [`kart-notification-service`](services/kart-notification-service/) (16)
- [ ] Frontend: shipment tracking UI, notification preference center, transactional email/SMS/push wiring
- [ ] Load/stress: Notification — High tier (platform's broadest fan-in consumer, per `service-boundaries.md`) — verify consumer autoscaling under full event fan-in volume, not just the happy path
- **Exit milestone:** orders ship, track, and notify automatically.

### Release 7 — Post-purchase Engagement

- [ ] Backend: [`kart-review-service`](services/kart-review-service/) (21), [`kart-recommendation-service`](services/kart-recommendation-service/) (13)
- [ ] Frontend: review submit/display/moderation-visible state, recommendation widgets (home, PDP, post-purchase)
- [ ] Load/stress: Recommendation — Medium, explicitly verifying its documented fail-open degrade behavior under load (it must not couple its own uptime to Inventory/Product per `architecture.md`'s distributed-monolith-risk note)
- **Exit milestone:** the engagement loop is complete.

### Release 8 — Admin & Analytics

- [ ] Backend: [`kart-admin-service`](services/kart-admin-service/) (22), [`kart-analytics-service`](services/kart-analytics-service/) (17)
- [ ] Frontend: `kart-admin-web` full build-out — RBAC-gated dashboards, catalog/coupon/user-management consoles, analytics dashboards/funnels
- [ ] Load/stress: Analytics — High tier. This is the true full-fan-in stress test, since Analytics consumes every event published by every other service simultaneously (ADR-0004).
- **Exit milestone:** back office complete, full observability across the platform.

### Release 9 — GA Hardening (final release, no new services)

- [ ] Remove all remaining feature flags platform-wide (`docs/client/approval-checklist.md` deployment-readiness check)
- [ ] `kart-web` Lighthouse / Core Web Vitals / SEO audit ([`kart-web/seo.md`](client/kart-web/seo.md))
- [ ] Full-system Extreme tier (10M+ RPM) load test across the *entire* platform simultaneously — not just the Order path this time
- [ ] Full BRD §26 chaos-engineering suite run platform-wide
- [ ] Security review / pen-test pass (`docs/client/security.md` + backend security standards)
- **Exit milestone:** v1.0 / GA-ready.

---

## Totals

| | Backend tickets | Frontend tickets |
|---|---|---|
| Sum across all releases | 247 | 96 (58 `kart-web` + 38 `kart-admin-web`) |

## How to use this document

- Check off each bullet as it's completed; check off the release header line only once every bullet under it (including its load-test bullet) is done.
- If a release's backend grouping changes because `services/README.md`'s build order is amended, update this file's grouping in the same PR — don't let the two silently diverge.
- Routine Baseline→Medium load tests are *not* tracked here per-release; they're inherent to each service's own CI/CD Performance Tests gate (`PLATFORM_BLUEPRINT.md` §11). Only the milestone-level stress/chaos work is tracked as its own checklist item above.
- Record every executed load test — routine or milestone — in [`docs/benchmarks/`](benchmarks/README.md), one dated file per run, using [`0000-benchmark-template.md`](benchmarks/0000-benchmark-template.md).

## Tooling: generate a complete per-release document in seconds

This table is also encoded machine-readably in [`docs/releases/releases.json`](releases/releases.json). Run [`scripts/release.sh`](../scripts/release.sh) to generate a full release document — scope, PLATFORM_BLUEPRINT.md §11 quality-gate checklist, this release's top common mistakes ([`docs/releases/COMMON_MISTAKES.md`](releases/COMMON_MISTAKES.md)), and GitHub release items (tag, milestone, Keep-a-Changelog release-notes template) — for any release N in under a second:

```bash
./scripts/release.sh --list        # see every release + status
./scripts/release.sh 2             # generate docs/releases/generated/release-2-<slug>.md
./scripts/release.sh 2 --create-github   # also create the GitHub milestone + tracking issue (opt-in, requires gh auth)
```

See [`docs/releases/README.md`](releases/README.md) for full usage. If you change a release's scope, edit `releases.json` and this table together — they must never silently diverge.
