---
doc_type: edge-cases
service: kart-cart-service
status: pending-approval
generated_by: edge-case-analyzer-agent
source: docs/services/kart-cart-service/requirement-spec.md
---

# Edge Cases: kart-cart-service

## Edge Case: Guest-to-user cart merge conflict

- **What happens:** guest (anonymous-session) cart and the logged-in user's existing cart both hold the same SKU at different quantities — or entirely different SKUs — when `/cart/merge` runs at login.
- **Why it happens:** two independently-built carts are reconciled into one, and requirement-spec FR §2 states merge as a responsibility without a conflict-resolution rule (Open Question 2).
- **Solutions available (3):** sum quantities across both carts · take the max of the two quantities · logged-in cart wins on conflict, guest line item discarded.
- **Decision (3-5 bullets max):**
  - Chosen: unresolved — escalated, not decided here.
  - Why: each option has a different silent user-facing consequence (inflating a quantity the user didn't ask for vs. dropping a guest selection entirely), and the BRD gives no signal on which is acceptable — this is a business call, not an engineering default.
  - Trade-off accepted: none — carried to requirement-spec Open Question 2 for human resolution before the Architecture Agent designs the merge operation.

## Edge Case: Cart lost on Redis eviction or restart

- **What happens:** an in-progress cart held in Redis disappears — evicted under memory pressure, or lost on a Redis node restart — before it has been captured in the PostgreSQL snapshot.
- **Why it happens:** requirement-spec NFR §3 and FR §2 note Cart's storage is "Redis + PostgreSQL snapshot" without stating which store is authoritative or the write path between them (Open Question 3); Redis, as an in-memory cache, is not itself durable.
- **Solutions available (3):** write-through (every cart mutation synchronously also writes PostgreSQL) · write-behind / periodic async snapshot (Redis is source of truth, PostgreSQL lags) · Redis persistence only (AOF/RDB), no separate PostgreSQL sync path.
- **Decision (3-5 bullets max):**
  - Chosen: write-through on every cart-mutation write.
  - Why: consistent with the platform's existing precedent of write-through where staleness/loss is unacceptable (BRD §16 uses write-through for Promotion for the same reason); cart-mutation volume (BRD §4.1: ~3.2 items/cart) is far lower than the catalog-read volume that justifies cache-aside elsewhere, so the added write latency is affordable within the P95 < 150ms budget.
  - Trade-off accepted: every cart write pays a synchronous PostgreSQL round-trip instead of returning as soon as Redis acknowledges.

## Edge Case: Stale cart references a deleted or out-of-stock product

- **What happens:** a cart holds a SKU that Product Service has since deleted, or that Inventory now reports as zero stock, while it still sits in the customer's cart.
- **Why it happens:** requirement-spec API Surface (§5) shows Cart consuming only `InventoryReservationFailed` — a checkout-time reactive signal — not `ProductCreated`/`ProductPriceChanged` or any proactive stock-level event; Cart has no standing subscription that would tell it an item went away while idle in the cart.
- **Solutions available (3):** lazy validation — check Product/Inventory synchronously right before publishing `CartCheckedOut` · event-driven — Cart also subscribes to catalog/stock events to proactively prune stale line items · client-side re-check — re-validate on every cart view via a live API call, no server-side subscription.
- **Decision (3-5 bullets max):**
  - Chosen: lazy validation at checkout.
  - Why: matches the API surface the requirement-spec actually documents (Cart consuming only a checkout-time signal); adding new event subscriptions is an Event Design Agent decision, not assumed here.
  - Trade-off accepted: a user can build and view a cart containing an item that's already gone, and only discover it at the point of checkout rather than earlier in the cart view.

## Edge Case: Checkout races `InventoryReservationFailed`

- **What happens:** `CartCheckedOut` is published (or checkout otherwise proceeds) around the same time `InventoryReservationFailed` arrives for one of the same cart's items, with no guaranteed ordering between the two.
- **Why it happens:** requirement-spec FR §2 has these as two independent async paths with no stated ordering guarantee, and NFR §3 (Reliability) only guarantees at-least-once delivery, not cross-event ordering.
- **Solutions available (3):** treat `InventoryReservationFailed` as always actionable and reopen/restore the cart regardless of checkout state · make Cart's handling idempotent — actionable only while the cart is still pre-checkout, a no-op once already checked out · introduce an explicit checkout-state machine in Cart to gate which states accept the event.
- **Decision (3-5 bullets max):**
  - Chosen: idempotent no-op once the cart has already checked out.
  - Why: matches domain invariant §4 (a cart is not a reservation) and NFR §3's idempotent-consumer requirement; keeps Order — already a consumer of `InventoryReservationFailed` and the stated Saga orchestrator (BRD §5.1) — as the sole owner of post-checkout compensation, avoiding two services racing to resolve the same failure.
  - Trade-off accepted: Cart cannot itself undo a completed checkout; any user-facing recovery after that point is Order's compensation flow, not Cart's.

## Edge Case: Abandoned-cart expiry races a returning user

- **What happens:** a cart's TTL expires and it is evicted from Redis at the same moment the user who abandoned it returns to add another item or check out.
- **Why it happens:** requirement-spec FR §2 and domain invariant §4 name expiry as a responsibility, but the actual TTL value and whether it resets on activity (sliding) or not (absolute) are unstated (Open Question 1) — a fixed TTL with no touch-to-extend behavior will race a returning user against silent eviction.
- **Solutions available (3):** sliding TTL — reset expiry on every cart read/write · fixed absolute TTL from cart creation regardless of activity · fixed TTL plus a soft-expiry grace window, recoverable from the PostgreSQL snapshot for N days after Redis eviction.
- **Decision (3-5 bullets max):**
  - Chosen: unresolved — escalated, not decided here.
  - Why: the actual TTL duration is a product decision (how long counts as "abandoned") that the BRD gives no number for; picking one here would be inventing a requirement, not extracting one.
  - Trade-off accepted: none — carried to requirement-spec Open Question 1 for human resolution before the Architecture Agent sizes Redis TTL/eviction policy.
