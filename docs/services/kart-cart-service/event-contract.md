---
doc_type: event-contract
service: kart-cart-service
status: approved
generated_by: event-design-agent
source: docs/services/kart-cart-service/requirement-spec.md, docs/services/kart-cart-service/edge-cases.md, docs/services/kart-cart-service/design-decisions.md, docs/services/kart-cart-service/architecture.md, docs/services/kart-cart-service/ddd-model.md, docs/adr/0016-user-gdpr-erasure-policy.md, docs/services/kart-user-service/event-contract.md
---

# Event Contract: kart-cart-service

Exchange: `ecommerce.events` (per [kart-conventions.md](../../standards/kart-conventions.md)). Every consumer queue below gets its own DLQ per the reusable event standard — never shared.

## Pipeline Note (resolved)

An earlier draft of this contract was produced before `docs/services/kart-cart-service/ddd-model.md` existed, directly from the already-approved `requirement-spec.md`/`edge-cases.md` (both fully specified Cart's original two domain events with no open questions). `ddd-model.md` has since been produced and approved — it confirms the `Cart` aggregate exactly as this contract already assumed (no contradiction), and adds one new consumed event, `UserDataErased` (invariant 6), which this pass adds below. This file's own status is now `approved`.

## Events

| Event | Routing Key | Published/Consumed | Key Fields | Retry | DLQ | Criticality Justification |
|---|---|---|---|---|---|---|
| `CartCheckedOut` | `cart.cart.checked-out` | Published (Analytics) | `cartId`, `userId`, `items` | 2x | `cart.dlq` | Standard (not highest) tier: Analytics-only consumer, funnel/conversion tracking (BRD §10, ADR-0007) — confirmed **not** consumed by Order (Order's creation trigger is the client's own synchronous `POST /orders`, per ADR-0007 and `kart-order-service/requirement-spec.md` §5), so this event is audit/analytics-only, never Saga-triggering. A lost/retried/DLQ'd delivery costs an inaccurate funnel metric, not a financial or inventory-correctness failure — the same risk class the reusable standard reserves the loosest, non-`Payment*` tier for. `cart.dlq` is already this event's own dedicated queue (Cart publishes only this one event, so the BRD's label was never a shared-DLQ violation to begin with — unlike Offer's `coupon.dlq`, which did need splitting in that service's own contract). |
| `InventoryReservationFailed` | `inventory.reservation.failed` | Consumed (from Inventory) | `orderId`, `sku` | 2x | `cart.inventory-reservation-failed.dlq` | Standard tier, matching the criticality the BRD/ADR-0007 assign this event generally — confirmed appropriate for Cart specifically (not escalated to the `Payment*` 5x/paged tier) because Cart's own handling (edge-cases.md → "Checkout races `InventoryReservationFailed`", Decision D3) is a pre-checkout-only, idempotent UX flag (mark the line item unavailable, no-op once already checked out): a DLQ'd delivery here means a stale "available" flag persists slightly longer, not an oversell or a lost financial transaction — Inventory's own PostgreSQL row remains the sole, authoritative source of truth regardless of whether this event is ever delivered to Cart (Inventory's own requirement-spec, Decision 6/7). **DLQ deliberately diverges from the BRD's simplified shared `inventory.dlq` label**: that label is shared across all of Inventory's own published events *and* across this event's three separate consumers (Order, Cart, Analytics per BRD §10) — a shared-DLQ pattern the reusable event standard explicitly forbids ("every consumer queue has its own DLQ — never a shared/global DLQ"). Cart's own consumer queue therefore gets its own DLQ, scoped to Cart's consumption only, independent of whatever Order's and Analytics' own event contracts eventually name theirs. This mirrors the identical override already established as precedent in `kart-offer-service/event-contract.md` (`PriceQuoteIssued`, overriding the BRD's shared `coupon.dlq`). |
| `UserDataErased` | `user.data-erased` | Consumed (from User Service) | `userId`, `erasedAt` | 5x, exponential backoff, on-call paging on final DLQ landing | `cart.user-data-erased.dlq` | **Compliance-critical tier**, per ADR-0016 item 7 — the same tier `kart-identity-service/event-contract.md` and `kart-wishlist-service/event-contract.md` already commit to on their own consumer sides for this same event. New this pass: **ADR-0016** was updated to name Cart directly as an expected consumer, closing a gap found during this service's own documentation pass (no prior draft of any of Cart's docs mentioned ADR-0016). Triggers hard deletion of every `Cart` row (Active or CheckedOut) owned by the erased `userId`, plus its Redis cache entry (`ddd-model.md` invariant 6; `design-decisions.md`'s "Erasure Mechanism" decision; `edge-cases.md`'s "Residual Cart State" decision). |

**Cross-service consistency note:** `kart-user-service/event-contract.md`'s own `UserDataErased` row currently lists seven consumers (Order, Notification, Analytics, Review, Recommendation, Wishlist, Identity) and does not yet include Cart, even though ADR-0016 — that row's own cited source — was updated by this pass to name Cart. This is a known, non-blocking asymmetry, not a contradiction this document can resolve unilaterally: User Service's own contract is the publish-side source of truth for that row and its DLQ list, and updating it is that service's own future documentation pass, the same "decide the integration pattern, don't edit the sibling service's docs directly" boundary ADR-0016/ADR-0017 already observe for their own cross-service consequences (mirroring the identical situation `kart-wishlist-service/event-contract.md` documents for `ProductDiscontinued`). Cart's own consumer-side retry/DLQ tier above is fully specified regardless of whether User Service's table catches up.

## Non-Event Decisions (confirmed here, no schema impact)

Two of this service's requirement-spec decisions were flagged in an earlier analysis pass as blocking items for this stage to settle. Both are now fully resolved upstream (requirement-spec §6, mirrored in edge-cases.md) and neither produces a domain event, so neither adds a row to the table above:

- **Cart TTL / expiry (Decision D1):** sliding TTL — 30 days idle (logged-in), 7 days idle (guest), 30-day PostgreSQL soft-expiry recovery window past Redis eviction. Confirmed internal-only: no `CartExpired`/`CartAbandoned` event is published on expiry or purge — Decision D1 itself states this is "not visible to, or depended on by, any other service's contract," and neither the BRD's Event Catalog (§10) nor this service's own API Surface (§5) lists such an event. Expiry is a private storage/TTL-config detail, not a domain event.
- **Guest-to-user cart merge conflict rule (Decision D2):** sum-on-overlap, union-on-distinct-SKUs, capped at the 100-line-item limit (Decision D4). Confirmed internal-only: `POST /cart/merge` (requirement-spec §5) is a synchronous REST operation with no associated published event — no other service observes or reacts to a merge happening, so no `CartMerged` (or similar) event is warranted.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner
- [x] Approved
