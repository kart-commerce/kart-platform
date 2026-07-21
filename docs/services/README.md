# Kart Services — Design Record Index

One folder per BRD service (`docs/services/<name>/`). This is the compiled index — it links out, it doesn't restate. Open a service's own folder to read its actual requirements, edge cases, and (once run) architecture/DDD/contracts/tickets.

Every doc's frontmatter carries its own `status` (`pending-approval` / `approved`) — check that before treating anything below as settled. `pending-approval` means drafted, not reviewed. The table below also uses `⚠️ NEEDS-WORK` for docs that were reviewed against a professional-grade bar and found to have concrete gaps — frontmatter for those still reads `pending-approval` (unchanged) until the gaps are addressed and the doc is re-reviewed.

## Pipeline stage per service

| Service | Requirement Spec | Edge Cases | Architecture | DDD Model | API / DB / Event Contracts | Tickets |
|---|---|---|---|---|---|---|
| [`kart-offer-service`](kart-offer-service/) (Coupon+Pricing+Promotion merge, [ADR-0001](../adr/0001-offer-service-merge.md)) | [✅ approved](kart-offer-service/requirement-spec.md) | [⚠️ NEEDS-WORK](kart-offer-service/edge-cases.md) | [✅ approved](kart-offer-service/architecture.md) | [✅ approved](kart-offer-service/ddd-model.md) | [✅ approved](kart-offer-service/api-contract.yaml) · [✅](kart-offer-service/database-design.md) · [✅](kart-offer-service/event-contract.md) | [✅](kart-offer-service/tickets.md) |
| [`kart-identity-service`](kart-identity-service/) | [⚠️ NEEDS-WORK](kart-identity-service/requirement-spec.md) | [⚠️ NEEDS-WORK](kart-identity-service/edge-cases.md) | — | — | — | — |
| [`kart-user-service`](kart-user-service/) | [✅ approved](kart-user-service/requirement-spec.md) | [✅ approved](kart-user-service/edge-cases.md) | — | — | — | — |
| [`kart-product-service`](kart-product-service/) | [⚠️ NEEDS-WORK](kart-product-service/requirement-spec.md) | [⚠️ NEEDS-WORK](kart-product-service/edge-cases.md) | — | — | — | — |
| [`kart-category-service`](kart-category-service/) | [✅ approved](kart-category-service/requirement-spec.md) | [✅ approved](kart-category-service/edge-cases.md) | — | — | — | — |
| [`kart-search-service`](kart-search-service/) | [✅ approved](kart-search-service/requirement-spec.md) | [✅ approved](kart-search-service/edge-cases.md) | — | — | — | — |
| [`kart-inventory-service`](kart-inventory-service/) | [⚠️ NEEDS-WORK](kart-inventory-service/requirement-spec.md) | [⚠️ NEEDS-WORK](kart-inventory-service/edge-cases.md) | — | — | — | — |
| [`kart-cart-service`](kart-cart-service/) | [✅ approved](kart-cart-service/requirement-spec.md) | [✅ approved](kart-cart-service/edge-cases.md) | — | — | — | — |
| [`kart-order-service`](kart-order-service/) | [⚠️ NEEDS-WORK](kart-order-service/requirement-spec.md) | [⚠️ NEEDS-WORK](kart-order-service/edge-cases.md) | — | — | — | — |
| [`kart-payment-service`](kart-payment-service/) | [✅ approved](kart-payment-service/requirement-spec.md) | [✅ approved](kart-payment-service/edge-cases.md) | — | — | — | — |
| [`kart-wishlist-service`](kart-wishlist-service/) | [⚠️ NEEDS-WORK](kart-wishlist-service/requirement-spec.md) | [⚠️ NEEDS-WORK](kart-wishlist-service/edge-cases.md) | — | — | — | — |
| [`kart-review-service`](kart-review-service/) | [⚠️ NEEDS-WORK](kart-review-service/requirement-spec.md) | [⚠️ NEEDS-WORK](kart-review-service/edge-cases.md) | — | — | — | — |
| [`kart-notification-service`](kart-notification-service/) | [✅ approved](kart-notification-service/requirement-spec.md) | [✅ approved](kart-notification-service/edge-cases.md) | — | — | — | — |
| [`kart-shipping-service`](kart-shipping-service/) | [✅ approved](kart-shipping-service/requirement-spec.md) | [✅ approved](kart-shipping-service/edge-cases.md) | — | — | — | — |
| [`kart-delivery-tracking-service`](kart-delivery-tracking-service/) | [⚠️ NEEDS-WORK](kart-delivery-tracking-service/requirement-spec.md) | [⚠️ NEEDS-WORK](kart-delivery-tracking-service/edge-cases.md) | — | — | — | — |
| [`kart-recommendation-service`](kart-recommendation-service/) | [✅ approved](kart-recommendation-service/requirement-spec.md) | [✅ approved](kart-recommendation-service/edge-cases.md) | — | — | — | — |
| [`kart-analytics-service`](kart-analytics-service/) | [✅ approved](kart-analytics-service/requirement-spec.md) | [✅ approved](kart-analytics-service/edge-cases.md) | — | — | — | — |
| [`kart-admin-service`](kart-admin-service/) | [⚠️ NEEDS-WORK](kart-admin-service/requirement-spec.md) | [⚠️ NEEDS-WORK](kart-admin-service/edge-cases.md) | — | — | — | — |

## What each document type is

- **`requirement-spec.md`** — one service's structured requirements, extracted from the BRD by `requirement-agent`: scope, functional/non-functional requirements, domain invariants, starting API surface, and open questions where the BRD is silent or contradicts itself. See `agent-reusables/agents/requirement-agent.md` for the exact contract.
- **`edge-cases.md`** — bullet-only catalogue of that service's real domain edge cases, produced by `edge-case-analyzer-agent` from its *approved* requirement spec: what happens, why, solution options, and the decision taken (3-5 bullets, chosen + why). See `agent-reusables/agents/edge-case-analyzer-agent.md`.
- **`architecture.md`**, **`ddd-model.md`**, **`api-contract.yaml`**, **`database-design.md`**, **`event-contract.md`**, **`tickets.md`** — later pipeline stages, produced once the two docs above are approved. See `agent-reusables/workflows/new-service.workflow.yaml` for the full DAG.

## Cross-service BRD contradictions — RESOLVED

These came up while drafting the 17 new requirement-specs and the subsequent professional-grade review pass. All are now resolved via ADR in `docs/adr/`, and `kart-requirements.md` (both here and in the source `kart-requirements` repo) has been updated to reflect each resolution directly — these are no longer open questions at the BRD level:

- **Order ↔ Shipping integration direction** — resolved async, end to end. [ADR-0002](../adr/0002-order-shipping-async-integration.md).
- **Notification's actual consumed-event set** — resolved to all `order.*`/`payment.*` routed events plus a few explicitly-named alert events. [ADR-0003](../adr/0003-notification-consumed-event-scope.md).
- **Analytics' actual ingestion scope** — resolved to full fan-in (every published event). [ADR-0004](../adr/0004-analytics-full-fanin-ingestion.md).
- **`OrderCompleted` (Recommendation) and `OrderDelivered` (Review) missing publishers** — unified into one new event, `OrderDelivered`, published by Order. [ADR-0005](../adr/0005-unify-order-terminal-event.md).
- **Identity ↔ User data ownership** — resolved via a new `UserAccountUpdated` event, published by Identity, consumed by User. [ADR-0006](../adr/0006-identity-user-profile-sync-event.md).
- **`InventoryReleased`, `InventoryReplenished`, `RefundIssued`, `CartCheckedOut`, `WishlistPriceAlertTriggered`, `AdminActionPerformed`, `UserRegistered`, `SessionCreated` missing from the Event Catalog** — all eight now have a full row (consumers + retry/DLQ tier) in §10. [ADR-0007](../adr/0007-event-catalog-completeness.md).

**Still outstanding — not a BRD contradiction, but not yet propagated:** `kart-identity-service`, `kart-admin-service`, `kart-order-service`, and `kart-recommendation-service`'s own `requirement-spec.md`/`edge-cases.md` were drafted *before* these ADRs and still describe the old open questions rather than citing the resolutions. Each needs a re-draft pass (cite the relevant ADR, adopt its decision, remove the now-stale open question) before re-review — see the gap table below.

Full detail and citations for the original contradictions are preserved in each ADR's Context section.

## Professional-grade review pass (this round)

Reviewed against a bar of: functional coverage matches the BRD's actual scope for that service, relevant NFRs/invariants are addressed, BRD ambiguities are explicitly flagged rather than silently resolved, and edge cases are genuine domain scenarios (not a generic checklist) each with options considered + a chosen decision + rationale. 9 of 18 reviewed doc-pairs passed and are now `status: approved`; 9 have concrete, named gaps and remain `pending-approval`:

| Service | Gap |
|---|---|
| `kart-identity-service` | Spec/edge-cases predate BRD §24.1/§24.2 (SSO + RBAC issuance) — missing FRs and edge cases for both; Identity↔User event-sync gap not flagged |
| `kart-product-service` | Missing edge cases: discontinued/orphaned variant handling; price change racing an in-progress cart/checkout |
| `kart-inventory-service` | Missing edge case: replenishment racing an active reservation; TTL-firing-while-payment-is-merely-slow under-specified; newly found `InventoryReleased` event gap unflagged |
| `kart-order-service` | Two of three README-tracked contradictions (Order↔Shipping direction, `OrderCompleted` missing publisher) silently resolved/omitted instead of flagged as open questions — disqualifying given this service is the Saga orchestrator |
| `kart-wishlist-service` | Missing edge cases: price rebounds before an alert is delivered; item added to a wishlist after its price already dropped |
| `kart-review-service` | Missing edge cases: duplicate review submission for the same delivered order; moderation-rejection racing an already-updated rating average |
| `kart-delivery-tracking-service` | Missing edge cases: duplicate (not just out-of-order) carrier webhook delivery; unmapped carrier status as its own case; tracking query before the first status event has arrived |
| `kart-admin-service` | RBAC edge cases describe Admin maintaining its own authorization/permission state, conflicting with §24.1's fixed single-issuer (Identity) model |
| `kart-offer-service` (`edge-cases.md` only) | Chosen cache-invalidation strategy contradicts BRD §16's explicit write-through mandate for promotion/pricing flags; missing edge cases for coupon-expiry-racing-checkout and expired-`PricingQuote`-reuse (both already named as hard invariants in this service's own approved `ddd-model.md`) |

## Recommended Build Order

Derived from the actual event/API dependency graph (who consumes whose contract), business criticality (money-moving critical path), and the review-pass status above. Prerequisite for all of these: `kart-shared`, `kart-infra`, and `kart-devops` must exist first — every service's Dockerfile/CI calls `kart-devops`'s reusable workflow, and every contract is a versioned `kart-shared` package.

| # | Service | Why |
|---|---|---|
| 1 | `kart-identity-service` | Auth/RBAC/SSO foundation every service's gateway integration and Admin depend on. Build first despite NEEDS-WORK — fix §24.1/§24.2 gaps before scaffolding. |
| 2 | `kart-category-service` | Zero dependencies on any other service; feeds Product's denormalized category name. Approved — safe to start immediately. |
| 3 | `kart-inventory-service` | Stock truth both Cart and Order need (Order's reserve call is synchronous). Highest-contention code in the platform — wants the longest hardening runway. NEEDS-WORK — fix before scaffolding. |
| 4 | `kart-delivery-tracking-service` | Zero Kart-service dependencies (external carrier webhooks only) — but Order needs it later for `OrderDelivered` (ADR-0005), so start early. NEEDS-WORK. |
| 5 | `kart-product-service` | Catalog foundation for Search/Offer/Wishlist; depends on Category. NEEDS-WORK — fix before scaffolding. |
| 6 | `kart-user-service` | Consumes Identity's `UserRegistered`/`UserAccountUpdated` (ADR-0006). Approved — ready once Identity's contract is stable. |
| 7 | `kart-search-service` | Consumes Product's `ProductCreated`/`ProductPriceChanged`. Approved — ready once Product's contract is stable. |
| 8 | `kart-offer-service` | Consumes Product's `ProductPriceChanged`. Architecture/DDD/contracts already approved; only `edge-cases.md` NEEDS-WORK. |
| 9 | `kart-wishlist-service` | Consumes Product's `ProductPriceChanged`. NEEDS-WORK. |
| 10 | `kart-cart-service` | Consumes Inventory's `InventoryReservationFailed`. Approved — ready once Inventory's contract is stable. |
| 11 | `kart-payment-service` | Mutual contract dependency with Order (resolved via `kart-shared` schema-first, not a runtime blocker) — PCI-isolated and self-contained, pin its contract just ahead of Order. Approved. |
| 12 | `kart-order-service` | The Saga orchestrator — needs Inventory (sync), Payment (contract), Cart (checkout handoff) all stable. NEEDS-WORK — highest-scrutiny fix needed; this is the revenue-critical path. |
| 13 | `kart-shipping-service` | Consumes Order's `OrderConfirmed`. Approved — ready once Order exists. |
| 14 | `kart-notification-service` | Broadest consumer so far — `order.*`/`payment.*`, plus Wishlist and Identity events (ADR-0003). Approved — build once those producers are stable. |
| 15 | `kart-review-service` | Consumes Order's `OrderDelivered` — needs Order *and* Delivery Tracking wired together. NEEDS-WORK. |
| 16 | `kart-recommendation-service` | Consumes Order's `OrderDelivered` + clickstream. Approved — ready alongside Review. |
| 17 | `kart-admin-service` | Back-office spanning Identity/User/Product/Offer. NEEDS-WORK — RBAC edge cases still describe owning its own auth state, conflicting with §24.1 — fix before scaffolding. |
| 18 | `kart-analytics-service` | Full fan-in (ADR-0004) over every event above — naturally last for complete value. Approved; its bare ingestion consumer is simple enough to stand up early in parallel if historical event data matters. |
