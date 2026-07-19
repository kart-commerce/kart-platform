# Kart Services — Design Record Index

One folder per BRD service (`docs/services/<name>/`). This is the compiled index — it links out, it doesn't restate. Open a service's own folder to read its actual requirements, edge cases, and (once run) architecture/DDD/contracts/tickets.

Every doc's frontmatter carries its own `status` (`pending-approval` / `approved`) — check that before treating anything below as settled. `pending-approval` means drafted, not reviewed.

## Pipeline stage per service

| Service | Requirement Spec | Edge Cases | Architecture | DDD Model | API / DB / Event Contracts | Tickets |
|---|---|---|---|---|---|---|
| [`kart-offer-service`](kart-offer-service/) (Coupon+Pricing+Promotion merge, [ADR-0001](../adr/0001-offer-service-merge.md)) | [✅ approved](kart-offer-service/requirement-spec.md) | [⏳ pending-approval](kart-offer-service/edge-cases.md) | [✅ approved](kart-offer-service/architecture.md) | [✅ approved](kart-offer-service/ddd-model.md) | [✅ approved](kart-offer-service/api-contract.yaml) · [✅](kart-offer-service/database-design.md) · [✅](kart-offer-service/event-contract.md) | [✅](kart-offer-service/tickets.md) |
| [`kart-identity-service`](kart-identity-service/) | [⏳ pending-approval](kart-identity-service/requirement-spec.md) | [⏳ pending-approval](kart-identity-service/edge-cases.md) | — | — | — | — |
| [`kart-user-service`](kart-user-service/) | [⏳ pending-approval](kart-user-service/requirement-spec.md) | [⏳ pending-approval](kart-user-service/edge-cases.md) | — | — | — | — |
| [`kart-product-service`](kart-product-service/) | [⏳ pending-approval](kart-product-service/requirement-spec.md) | [⏳ pending-approval](kart-product-service/edge-cases.md) | — | — | — | — |
| [`kart-category-service`](kart-category-service/) | [⏳ pending-approval](kart-category-service/requirement-spec.md) | [⏳ pending-approval](kart-category-service/edge-cases.md) | — | — | — | — |
| [`kart-search-service`](kart-search-service/) | [⏳ pending-approval](kart-search-service/requirement-spec.md) | [⏳ pending-approval](kart-search-service/edge-cases.md) | — | — | — | — |
| [`kart-inventory-service`](kart-inventory-service/) | [⏳ pending-approval](kart-inventory-service/requirement-spec.md) | [⏳ pending-approval](kart-inventory-service/edge-cases.md) | — | — | — | — |
| [`kart-cart-service`](kart-cart-service/) | [⏳ pending-approval](kart-cart-service/requirement-spec.md) | [⏳ pending-approval](kart-cart-service/edge-cases.md) | — | — | — | — |
| [`kart-order-service`](kart-order-service/) | [⏳ pending-approval](kart-order-service/requirement-spec.md) | [⏳ pending-approval](kart-order-service/edge-cases.md) | — | — | — | — |
| [`kart-payment-service`](kart-payment-service/) | [⏳ pending-approval](kart-payment-service/requirement-spec.md) | [⏳ pending-approval](kart-payment-service/edge-cases.md) | — | — | — | — |
| [`kart-wishlist-service`](kart-wishlist-service/) | [⏳ pending-approval](kart-wishlist-service/requirement-spec.md) | [⏳ pending-approval](kart-wishlist-service/edge-cases.md) | — | — | — | — |
| [`kart-review-service`](kart-review-service/) | [⏳ pending-approval](kart-review-service/requirement-spec.md) | [⏳ pending-approval](kart-review-service/edge-cases.md) | — | — | — | — |
| [`kart-notification-service`](kart-notification-service/) | [⏳ pending-approval](kart-notification-service/requirement-spec.md) | [⏳ pending-approval](kart-notification-service/edge-cases.md) | — | — | — | — |
| [`kart-shipping-service`](kart-shipping-service/) | [⏳ pending-approval](kart-shipping-service/requirement-spec.md) | [⏳ pending-approval](kart-shipping-service/edge-cases.md) | — | — | — | — |
| [`kart-delivery-tracking-service`](kart-delivery-tracking-service/) | [⏳ pending-approval](kart-delivery-tracking-service/requirement-spec.md) | [⏳ pending-approval](kart-delivery-tracking-service/edge-cases.md) | — | — | — | — |
| [`kart-recommendation-service`](kart-recommendation-service/) | [⏳ pending-approval](kart-recommendation-service/requirement-spec.md) | [⏳ pending-approval](kart-recommendation-service/edge-cases.md) | — | — | — | — |
| [`kart-analytics-service`](kart-analytics-service/) | [⏳ pending-approval](kart-analytics-service/requirement-spec.md) | [⏳ pending-approval](kart-analytics-service/edge-cases.md) | — | — | — | — |
| [`kart-admin-service`](kart-admin-service/) | [⏳ pending-approval](kart-admin-service/requirement-spec.md) | [⏳ pending-approval](kart-admin-service/edge-cases.md) | — | — | — | — |

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
- **Identity ↔ User data ownership** — no event exists for Identity-side profile fields (email, name) changing and propagating to User Service.
- **Several published events are entirely absent from the BRD's Event Catalog (§10)**, despite being named in a service's own row: `CartCheckedOut`, `WishlistPriceAlertTriggered`, `AdminActionPerformed`, `OrderCompensationTriggered`, `UserRegistered`/`SessionCreated`. No retry/DLQ policy exists for any of them yet.

Full detail and citations for each are in the relevant service's `requirement-spec.md` and `edge-cases.md`, under "Open Questions" / escalated decisions.
