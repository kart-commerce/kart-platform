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

## Known cross-service contradictions surfaced during drafting

These came up while drafting the 17 new requirement-specs — they're BRD-level issues, not per-service bugs, and are worth resolving centrally rather than letting each service guess independently:

- **Order ↔ Shipping integration direction** — BRD §12.1's Saga diagram implies Order synchronously calls Shipping before confirming, but §5.4/§10 describe Shipping as an async consumer of `OrderConfirmed`. These are two different integration styles; pick one.
- **Notification's actual consumed-event set** — §5.4 claims "almost every event," §10's Event Catalog lists only 3. This decides Notification's entire load profile and RabbitMQ bindings.
- **Analytics' actual ingestion scope** — same shape of contradiction: §2.2/§5.4 imply full fan-in, §10 lists 6 of 13 events.
- **`OrderCompleted` (consumed by Recommendation) has no publisher anywhere in the BRD** — Order only publishes `OrderCreated`/`OrderConfirmed`/`OrderCancelled`. Recommendation may be permanently starved of purchase signal until this is fixed.
- **`OrderDelivered` (consumed by Review, for verified-purchase gating) has no confirmed publisher anywhere in the BRD either** — same shape as the `OrderCompleted` gap above, surfaced during the professional-grade review pass. Order's publish list is only ever `OrderCreated`/`OrderConfirmed`/`OrderCancelled`/`OrderCompensationTriggered`.
- **Identity ↔ User data ownership** — no event exists for Identity-side profile fields (email, name) changing and propagating to User Service.
- **Several published events are entirely absent from the BRD's Event Catalog (§10)**, despite being named in a service's own row: `CartCheckedOut`, `WishlistPriceAlertTriggered`, `AdminActionPerformed`, `OrderCompensationTriggered`, `UserRegistered`/`SessionCreated`. No retry/DLQ policy exists for any of them yet.
- **`InventoryReleased` (shown as Inventory's reply to Order in BRD §12.2's compensation diagram) is absent from both §5.2's Publishes row and the §10 Event Catalog** — same missing-event pattern as above, surfaced during the professional-grade review pass.
- **`kart-requirements.md` §24.1 (Cross-Cutting RBAC Model) and §24.2 (SSO / Identity Federation) were added after `kart-identity-service` and `kart-admin-service`'s `requirement-spec.md`/`edge-cases.md` were drafted.** Both docs still treat "who issues roles, who's the source of truth" as an open question that the BRD now actually answers (Identity issues, every other service — including Admin — only consumes the claim). Both need a re-draft pass to reconcile with §24.1/§24.2 before re-review; see the NEEDS-WORK notes below.

Full detail and citations for each are in the relevant service's `requirement-spec.md` and `edge-cases.md`, under "Open Questions" / escalated decisions.

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
