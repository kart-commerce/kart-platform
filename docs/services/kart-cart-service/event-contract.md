---
doc_type: event-contract
service: kart-cart-service
status: pending-approval
generated_by: event-design-agent
source: docs/services/kart-cart-service/requirement-spec.md, docs/services/kart-cart-service/edge-cases.md, docs/services/kart-cart-service/design-decisions.md, docs/services/kart-cart-service/architecture.md
---

# Event Contract: kart-cart-service

Exchange: `ecommerce.events` (per [kart-conventions.md](../../standards/kart-conventions.md)). Every consumer queue below gets its own DLQ per the reusable event standard — never shared.

## Pipeline Note (read before reviewing the table)

No `docs/services/kart-cart-service/ddd-model.md` exists yet — per the reusable `new-service.workflow.yaml` DAG, the `event-design` stage `depends_on: [ddd]`, and `design-decisions.md`/`architecture.md` (this service's own upstream inputs to a DDD pass) are themselves still `status: pending-approval`, not yet signed off. This contract was nonetheless produced now, as instructed, directly from the two docs that are fully closed out and internally consistent — `requirement-spec.md` (`status: approved`) and `edge-cases.md` (`status: approved`) — both of which already fully specify Cart's only two domain events (schema, consumer, retry, DLQ), with no open questions remaining (see requirement-spec §6, Decisions D1–D9). Nothing below depends on a DDD-Agent-only fact (e.g. aggregate boundaries) that isn't already settled in those two docs. A DDD Agent pass should still run and be checked against this contract for contradiction before this file is moved to `status: approved`; that check is expected to be a no-op given the current state of the approved docs, but it hasn't formally happened, so this file's own status is left at `pending-approval` pending that confirmation and human sign-off — consistent with the `pending-approval` state already carried by `design-decisions.md` and `architecture.md`.

## Events

| Event | Routing Key | Published/Consumed | Key Fields | Retry | DLQ | Criticality Justification |
|---|---|---|---|---|---|---|
| `CartCheckedOut` | `cart.cart.checked-out` | Published (Analytics) | `cartId`, `userId`, `items` | 2x | `cart.dlq` | Standard (not highest) tier: Analytics-only consumer, funnel/conversion tracking (BRD §10, ADR-0007) — confirmed **not** consumed by Order (Order's creation trigger is the client's own synchronous `POST /orders`, per ADR-0007 and `kart-order-service/requirement-spec.md` §5), so this event is audit/analytics-only, never Saga-triggering. A lost/retried/DLQ'd delivery costs an inaccurate funnel metric, not a financial or inventory-correctness failure — the same risk class the reusable standard reserves the loosest, non-`Payment*` tier for. `cart.dlq` is already this event's own dedicated queue (Cart publishes only this one event, so the BRD's label was never a shared-DLQ violation to begin with — unlike Offer's `coupon.dlq`, which did need splitting in that service's own contract). |
| `InventoryReservationFailed` | `inventory.reservation.failed` | Consumed (from Inventory) | `orderId`, `sku` | 2x | `cart.inventory-reservation-failed.dlq` | Standard tier, matching the criticality the BRD/ADR-0007 assign this event generally — confirmed appropriate for Cart specifically (not escalated to the `Payment*` 5x/paged tier) because Cart's own handling (edge-cases.md → "Checkout races `InventoryReservationFailed`", Decision D3) is a pre-checkout-only, idempotent UX flag (mark the line item unavailable, no-op once already checked out): a DLQ'd delivery here means a stale "available" flag persists slightly longer, not an oversell or a lost financial transaction — Inventory's own PostgreSQL row remains the sole, authoritative source of truth regardless of whether this event is ever delivered to Cart (Inventory's own requirement-spec, Decision 6/7). **DLQ deliberately diverges from the BRD's simplified shared `inventory.dlq` label**: that label is shared across all of Inventory's own published events *and* across this event's three separate consumers (Order, Cart, Analytics per BRD §10) — a shared-DLQ pattern the reusable event standard explicitly forbids ("every consumer queue has its own DLQ — never a shared/global DLQ"). Cart's own consumer queue therefore gets its own DLQ, scoped to Cart's consumption only, independent of whatever Order's and Analytics' own event contracts eventually name theirs. This mirrors the identical override already established as precedent in `kart-offer-service/event-contract.md` (`PriceQuoteIssued`, overriding the BRD's shared `coupon.dlq`). |

## Non-Event Decisions (confirmed here, no schema impact)

Two of this service's requirement-spec decisions were flagged in an earlier analysis pass as blocking items for this stage to settle. Both are now fully resolved upstream (requirement-spec §6, mirrored in edge-cases.md) and neither produces a domain event, so neither adds a row to the table above:

- **Cart TTL / expiry (Decision D1):** sliding TTL — 30 days idle (logged-in), 7 days idle (guest), 30-day PostgreSQL soft-expiry recovery window past Redis eviction. Confirmed internal-only: no `CartExpired`/`CartAbandoned` event is published on expiry or purge — Decision D1 itself states this is "not visible to, or depended on by, any other service's contract," and neither the BRD's Event Catalog (§10) nor this service's own API Surface (§5) lists such an event. Expiry is a private storage/TTL-config detail, not a domain event.
- **Guest-to-user cart merge conflict rule (Decision D2):** sum-on-overlap, union-on-distinct-SKUs, capped at the 100-line-item limit (Decision D4). Confirmed internal-only: `POST /cart/merge` (requirement-spec §5) is a synchronous REST operation with no associated published event — no other service observes or reacts to a merge happening, so no `CartMerged` (or similar) event is warranted.

## Sign-off

- [ ] Reviewed by a human
- [ ] Approved
