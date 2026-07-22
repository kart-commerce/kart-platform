---
doc_type: tickets
service: kart-cart-service
status: approved
generated_by: ticket-agent
source: [requirement-spec.md, edge-cases.md, design-decisions.md, architecture.md, ddd-model.md, api-contract.yaml, database-design.md, event-contract.md]
---

# Tickets: kart-cart-service

Local draft. Not yet created as real GitHub Issues — that requires the target repo to exist (Project Scaffold Agent) and is a separate, explicit step.

All 9 upstream design artifacts for this service are `status: approved`. This ticket list is decomposed directly from that fully-approved set — six vertical slices map 1:1 to `api-contract.yaml`'s six operations, and three more cover the async/scheduled behaviors `event-contract.md`/`database-design.md`/`edge-cases.md` commit to. No endpoint or consumed event in the design package is left undecomposed.

## Epic: kart-cart-service v1

Cart lifecycle, merge, and expiry (BRD §2.1 item 7): the last place a customer's intent is mutable before Order takes over as Saga orchestrator (`architecture.md`, Boundary Rationale) — a customer-facing, pre-Saga edge service (99.9% availability tier, Decision D6) with Strong consistency (write-through Redis over an authoritative PostgreSQL write side, Decision D5).

| ID | Task | Vertical Slice (Application/Features/) | Depends On | Design Source |
|---|---|---|---|---|
| CART-1 | Get the caller's own current cart | `GetCurrentCart` | — | `api-contract.yaml` `GET /v1/cart`; `database-design.md` Redis write-through cache (`cart:{ownerKey}`), PostgreSQL fallback on miss |
| CART-2 | Add a line item to the caller's own cart | `AddCartItem` | CART-1 | `api-contract.yaml` `POST /v1/cart/items`; `ddd-model.md` `Cart`/`CartLineItem` invariants (unique per `(cart, sku)`, 100-line-item cap); `database-design.md` `carts`/`cart_line_items` tables, `uq_carts_user_active`/`uq_carts_guest_active`, `uq_cart_line_items_cart_sku` |
| CART-3 | Set a line item's quantity | `SetCartItemQuantity` | CART-2 | `api-contract.yaml` `PUT /v1/cart/items/{sku}`; `design-decisions.md`'s optimistic-concurrency decision (`CartVersion`/`ETag`/`If-Match`) |
| CART-4 | Remove a line item from the caller's own cart | `RemoveCartItem` | CART-2 | `api-contract.yaml` `DELETE /v1/cart/items/{sku}`; idempotent-DELETE semantics |
| CART-5 | Merge a guest cart into the caller's logged-in cart | `MergeGuestCartIntoUserCart` | CART-2 | `api-contract.yaml` `POST /v1/cart/merge`; `edge-cases.md` "Guest-to-user cart merge conflict" (sum-on-overlap, union-on-distinct, capped at 100); `ddd-model.md` Modeling Decision #1 (guest cart terminated in the same transaction, not left as an ongoing peer) |
| CART-6 | Checkout the caller's own cart | `CheckoutCart` | CART-2 | `api-contract.yaml` `POST /v1/cart/checkout`; `ddd-model.md` invariant 4 (`CartStatus` → `CheckedOut`, terminal); `database-design.md` `cart_outbox_events` (Transactional Outbox); `event-contract.md` `CartCheckedOut` (2x retry, `cart.dlq`, Analytics-only) |
| CART-7 | Flag a line item unavailable on `InventoryReservationFailed` | `HandleInventoryReservationFailed` | CART-2 | `event-contract.md` `InventoryReservationFailed` consumption (2x retry, `cart.inventory-reservation-failed.dlq`); `edge-cases.md` "Checkout races `InventoryReservationFailed`" (idempotent, pre-checkout-only, no-op post-checkout); `ddd-model.md` `LineItemAvailability` |
| CART-8 | Erase a user's cart data on `UserDataErased` | `EraseUserCartDataOnUserDataErased` | CART-2, CART-6 | `event-contract.md` `UserDataErased` consumption (5x retry, paged, `cart.user-data-erased.dlq`, compliance-critical tier per ADR-0016 item 7 — ADR updated this pass to name Cart); `design-decisions.md` "Erasure Mechanism for `UserDataErased`" (synchronous multi-store hard delete, overriding the normal `CheckedOut`-retention rule); `edge-cases.md` "Residual Cart State After a `UserDataErased` Event"; `database-design.md`'s GDPR Erasure Write Path (`DELETE FROM carts WHERE user_id = ?` cascading to line items, plus Redis eviction, one handler) |
| CART-9 | Scheduled soft-expiry purge job | `PurgeExpiredCarts` | CART-2 | `requirement-spec.md` Decision D1 (sliding TTL — 30 days logged-in / 7 days guest — plus a 30-day PostgreSQL soft-expiry recovery window); `edge-cases.md` "Abandoned-cart expiry races a returning user"; `database-design.md`'s Soft-Expiry Purge Job section, `idx_carts_active_updated_at` |

## Flagged Gaps — Not Decomposed Into Tickets (would invent scope, not decompose it)

- **No cross-service update to `kart-user-service/event-contract.md`'s `UserDataErased` Consumers column.** `event-contract.md`'s own cross-service consistency note already names this as User Service's own doc's follow-up, not Cart's — no ticket here; CART-8 already implements the consumer side regardless of that table's contents.
- **No `CartExpired`/`CartMerged` published event.** `event-contract.md`'s "Non-Event Decisions" section already confirms both expiry and merge are internal-only outcomes with no external consumer — not invented here.

## Notes for Sprint Planner Agent

- CART-1 (`GetCurrentCart`) and CART-2 (`AddCartItem`) are the foundation — CART-1 has no dependency, and every other ticket needs at least one existing cart/line-item to act on.
- CART-3, CART-4, CART-5, CART-6, and CART-7 each depend only on CART-2 and are otherwise independent of each other — parallelizable once CART-2 lands.
- CART-9 depends only on CART-2 (needs the `carts` table and its `updated_at` column to exist) and is otherwise fully independent — safe to build any time after CART-2.
- CART-8 is the longest chain (CART-2 → CART-6 → CART-8, 3 nodes) because it must delete a `CheckedOut` cart CART-6 would otherwise retain — build it last among the async/scheduled tickets, and re-verify it against CART-6's actual final checkout implementation before considering it done.
- No circular dependencies in this graph.
