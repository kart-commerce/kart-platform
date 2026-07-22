---
doc_type: edge-cases
service: kart-cart-service
status: approved
generated_by: edge-case-analyzer-agent
source: docs/services/kart-cart-service/requirement-spec.md
---

# Edge Cases: kart-cart-service

## Edge Case: Guest-to-user cart merge conflict

- **What happens:** guest (anonymous-session) cart and the logged-in user's existing cart both hold the same SKU at different quantities — or entirely different SKUs — when `/cart/merge` runs at login.
- **Why it happens:** two independently-built carts are reconciled into one, and requirement-spec FR §2 states merge as a responsibility without a conflict-resolution rule (Open Question 2).
- **Solutions available (3):** sum quantities across both carts · take the max of the two quantities · logged-in cart wins on conflict, guest line item discarded.
- **Decision (3-5 bullets max):**
  - Chosen: sum quantities on overlapping SKUs; union (keep both) on non-overlapping SKUs; cap the merged cart at 100 distinct line items (dropping lowest-value overflow if the cap is exceeded).
  - Why: sum-on-overlap is the only option that treats both sessions' additions as real user intent rather than silently discarding one of them — a guest who added a SKU and later, now logged in, adds more of the same SKU (e.g. from a second device) most plausibly meant both to count. Union-on-distinct-SKUs is the only non-lossy choice when the carts don't overlap at all. This resolves requirement-spec Decision D2 (see `requirement-spec.md` §6) as a single-service engineering default — no ADR needed, since the rule is entirely internal to Cart's own merge logic and not visible to any other service's contract.
  - Trade-off accepted: a user may see a summed quantity larger than they explicitly intended in either individual session (e.g. they meant to replace, not add to, a guest-cart quantity) — judged acceptable and correctable at checkout, versus the alternative of silently dropping a guest-cart line item the user never explicitly abandoned.

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
  - Chosen: sliding TTL (resets on every read/write) — 30 days idle for a logged-in user's cart, 7 days idle for a guest cart — plus a 30-day PostgreSQL soft-expiry recovery window past Redis eviction before the row is purged outright.
  - Why: sliding, not absolute, matches the intuitive meaning of "abandoned" — an actively-touched cart should never expire mid-use, which directly closes this edge case's race. The 30/7-day asymmetry mirrors the platform's general pattern of trusting authenticated identity more than an anonymous session. This resolves requirement-spec Decision D1 (see `requirement-spec.md` §6) as a single-service engineering default, grounded in the BRD's own average-cart-size signal (§4.1) and general e-commerce practice — no ADR needed, since Redis TTL sizing is entirely internal to Cart.
  - Trade-off accepted: a guest who returns after more than 7 days loses their cart outright with no recovery path (no durable identity exists to reattach a snapshot to); a returning user within the sliding window never experiences the race this edge case describes, since the touch that triggers the race also resets the TTL.

## Edge Case: Residual Cart State After a `UserDataErased` Event

- **What happens:** A user submits a verified GDPR erasure request (processed by User Service per ADR-0016); if Cart does nothing further, that user's `Cart` row(s) — both any live `Active` cart and any retained `CheckedOut` cart (ddd-model.md invariant 4's normal-case retention for audit/analytics) — persist in PostgreSQL, and the corresponding Redis cache entry persists until its own sliding TTL happens to expire, which for an actively-used cart could be up to 30 more days.
- **Why it happens:** ADR-0016 was updated this pass to name Cart directly as an expected `UserDataErased` consumer (requirement-spec §2's GDPR Erasure Consumption FR, §6 D10) — a gap this service's own documentation had never previously addressed, since Cart's own domain model normally treats a `CheckedOut` cart as retained, not disposable (ddd-model.md invariant 4), and the sliding-TTL expiry mechanism (Decision D1) has no concept of an explicit, out-of-band deletion trigger distinct from ordinary idle-timeout.
- **Solutions available (3):** delete only the PostgreSQL `Cart` row(s) for the erased `userId`, leaving the Redis entry to expire naturally on its own sliding TTL · delete the PostgreSQL row(s) and synchronously evict the Redis cache entry in the same handler · defer the deletion to the next scheduled expiry-sweep pass rather than an immediate event-driven purge.
- **Decision (3-5 bullets max):**
  - Chosen: option 2 — on consuming `UserDataErased`, synchronously delete every `Cart` row (Active or CheckedOut) owned by the erased `userId` from PostgreSQL, and evict the corresponding Redis cache entry, in one handler.
  - Why: ADR-0016 item 7's compliance-critical retry/paging tier for `UserDataErased` reflects that "an erasure event silently swallowed... is a compliance failure, not a tolerable staleness window" — leaving the Redis entry to expire on its own sliding TTL (option 1) could leave an erased user's cart contents readable for up to 30 more days (Decision D1's own logged-in-user TTL), and deferring to a scheduled sweep (option 3) reintroduces the same avoidable window for no benefit.
  - Trade-off accepted: the erasure handler must reach two stores (PostgreSQL and Redis) instead of one, and — unlike ordinary expiry — must also delete a `CheckedOut` cart the normal-case invariant would otherwise retain; accepted because a compliance-critical event is exactly the case where "erasure is fully synchronous and complete, not eventually consistent" is the correct bias, and neither cart state is BRD-required retained history (ADR-0016 item 3).
  - Idempotency: a redelivered `UserDataErased` for an already-erased `userId` finds nothing left to delete in either store and is a no-op, not an error — the same idempotent-consumer discipline this service's own `InventoryReservationFailed` handling (Decision D3) already relies on.
  - Relation to other decisions above: this is orthogonal to the sliding-TTL expiry mechanism (D1) and the write-through caching decision (D5) — both continue to operate exactly as decided for every user who has *not* been erased; this decision only adds an explicit, immediate teardown path triggered by a distinct external event, reusing the same delete-the-row mechanism D1's own purge already implements.
