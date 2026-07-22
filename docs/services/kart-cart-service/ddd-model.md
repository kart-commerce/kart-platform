---
doc_type: ddd-model
service: kart-cart-service
status: pending-approval
generated_by: ddd-agent
source: docs/services/kart-cart-service/architecture.md
---

# DDD Model: kart-cart-service

One aggregate root in one bounded context. Per requirement-spec §1, Cart stands alone — unlike Offer (ADR-0001), no ADR merges it with a sibling BRD row, so there is no cross-aggregate merge-boundary question to resolve at the "which BRD rows share this context" level; the only aggregate-boundary question this model has to resolve is internal, at the merge-*operation* level (see Modeling Decision #1 below).

## Aggregate: Cart

**Aggregate root:** `Cart` — identified by `CartId`.

**Entities (child, within the Cart aggregate):**
- `CartLineItem` — identified by `Sku` *within its parent Cart* (not a globally unique id of its own); carries a `quantity` and a `LineItemAvailability` flag.

**Value objects:**
- `CartOwner` — a mutually exclusive `UserId` (logged-in) or `GuestSessionId` (anonymous session); a Cart has exactly one, never both, never neither.
- `CartVersion` — the optimistic-concurrency version counter checked and incremented on every write (direct mutation or merge); see `design-decisions.md`'s "Concurrency Control for Cart Mutations and Merge."
- `LineItemAvailability` — `Available` | `FlaggedUnavailable`; set when `InventoryReservationFailed` is consumed pre-checkout (Decision D3), cleared on the line item's next successful validation.
- `CartStatus` — `Active` | `CheckedOut`; `CheckedOut` is terminal for that Cart instance and is what makes D3's post-checkout handling of `InventoryReservationFailed` a no-op rather than a live mutation.

**Invariants:**
1. A Cart has exactly one `CartOwner` — either a `UserId` or a `GuestSessionId`, never both, never neither. (This is what makes "guest cart" vs. "logged-in cart" a well-defined distinction for merge to operate on at all.)
2. A Cart holds at most 100 distinct `CartLineItem`s, keyed by `Sku` (requirement-spec Decision D4) — enforced on both direct `/cart` mutation and on merge.
3. Within a single Cart, each `Sku` appears as at most one `CartLineItem` — quantity is additive onto the existing line, never a duplicate line for the same `Sku`. This is what makes Decision D2's "sum quantities on overlapping SKUs" well-defined: "overlap" *is* `Sku` equality.
4. Once a Cart's `CartStatus` is `CheckedOut`, it is terminal for domain-mutation purposes: no further direct `/cart` mutation, merge, or `InventoryReservationFailed`-driven availability change applies to it (requirement-spec Decision D3 — "no-op if the cart has already checked out"). A `CheckedOut` Cart is not deleted (it remains addressable for audit/analytics) but no invariant above 1–3 is re-checked or re-enforced against it again.
5. Cart's own storage-reclamation invariant (requirement-spec §4: "an expired cart must eventually be reclaimed") is satisfied entirely by infrastructure TTL configuration (sliding Redis TTL + PostgreSQL soft-expiry purge, Decision D1) — see Modeling Decision #2. It is deliberately *not* an in-aggregate invariant enforced by domain code (no `isExpired()` check gates any operation, and there is no terminal "Expired" `CartStatus` value): a Cart that still physically exists past its idle window but hasn't yet been purged is not an invalid business state, merely one eligible for cleanup.

**Domain events:**
- `CartCheckedOut` (published — existing, BRD §10 / ADR-0007). Transitions `CartStatus` `Active` → `CheckedOut`. Consumer: Analytics only, never Order (Order's own creation trigger is the client's synchronous `POST /orders`, confirmed by ADR-0007 and `kart-order-service/requirement-spec.md` §5) — audit/analytics-only, never Saga-triggering.
- `InventoryReservationFailed` (consumed — from `kart-inventory-service`, BRD §10). Applies `LineItemAvailability = FlaggedUnavailable` to the matching `CartLineItem` (by `Sku`), only while `CartStatus == Active` (invariant 4); a no-op otherwise. Idempotent by construction — re-applying the same flag transition twice yields the same state, which is why `design-decisions.md`'s "Reliable Event Publication and Idempotent Event Consumption" decision needs no separate inbox/dedup table for this consumer.

No other domain events are owned by this aggregate. `event-contract.md` already confirms, and this model does not disturb, that neither Decision D1 (expiry) nor Decision D2 (merge) produces a published event — both are private, internal-only outcomes with no external consumer, so no `CartExpired`/`CartMerged` (or similarly named) event is proposed here.

## Cross-Aggregate / Cross-Context Interaction

- `CartLineItem.sku` is a reference value only into `kart-product-service`'s catalog — resolved via the synchronous, timeout-guarded, fail-open gRPC validation call at checkout time (`architecture.md`'s Dependencies table; `design-decisions.md`'s "Resilience Pattern for Checkout-Time Stock/Price Validation"). Cart never owns or redefines catalog/price data; a stale or now-invalid `Sku` reference is a UX-surfacing concern, not a Cart-aggregate invariant violation (Inventory alone enforces the oversell invariant, per requirement-spec §4).
- `CartOwner.userId` references an identity issued and owned by `kart-identity-service` (BRD §2.1 item 1, "AuthN, tokens, sessions"). Cart never models authentication, token issuance, or session lifecycle — it only reads a `UserId` as an opaque owner key.
- Cart never models Order's own aggregate/state machine. `CartCheckedOut` is a one-way, Analytics-only signal; Order's creation path (`POST /orders`) bypasses Cart entirely at the service-boundary level (`architecture.md` — "No dependency edge to Order exists in either direction").
- Cart never models Inventory's reservation aggregate. `InventoryReservationFailed` is consumed only as a trigger for `LineItemAvailability`, never as a state Cart itself owns or reconciles further.

## Modeling Decisions & Assumptions (resolved here, not escalated — engineering defaults, revisable)

1. **Merge touches two Cart aggregate instances in one transaction — does this violate the "aggregate = transaction boundary" test?** Resolved: no, and this is a deliberate, narrow exception, not a modeling error. `POST /cart/merge` (Decision D2) reads the guest Cart once, folds its `CartLineItem`s into the target user Cart (sum-on-overlap, union-on-distinct, capped per invariant 2), bumps the user Cart's `CartVersion`, and terminates the guest Cart (deleted, not left as an ongoing peer subject to further concurrent invariant enforcement). After the transaction commits, exactly one live Cart aggregate instance remains for that owner going forward — the guest Cart was never a target of *repeated* or *ongoing* concurrent mutation alongside the user Cart, only a one-time terminal read-then-delete within the same transaction as the survivor's write. This is the same class of narrow multi-instance-of-one-aggregate-type transaction long-established for "merge and archive" operations, and is distinct from the failure mode the ddd-agent definition warns against (an invariant that structurally requires straddling two aggregates *on every write*, forever) — here it is a single, one-time reconciliation event per guest session, not a recurring coupling.
2. **Expiry (invariant 5) is infra-level TTL config, not in-aggregate domain logic.** Requirement-spec §4 lists "an expired cart must eventually be reclaimed" as a domain invariant, but Decision D1 resolves it entirely via Redis sliding TTL (30 days logged-in / 7 days guest) plus a 30-day PostgreSQL soft-expiry purge window — both infrastructure/storage-config concerns, not business rules the `Cart` aggregate itself must check before allowing an operation. No `CartStatus = Expired` value is modeled and no operation is gated on cart age; this keeps the aggregate's actual behavioral invariants (1–4) free of a concern that is really about storage lifecycle, not business correctness of a still-live cart.
3. **`CartLineItem` identity is `Sku`, not a synthetic line-item id.** Because invariant 3 forbids more than one line per `Sku` within a Cart, `Sku` is already a sufficient, stable identity key inside the aggregate boundary — introducing a separate synthetic line-item id would add no distinguishing power and would only invite the (forbidden) possibility of two lines for the same `Sku` coexisting.
4. **`GuestSessionId` is modeled locally, not asserted as owned by `kart-identity-service`.** Unlike `UserId` (clearly in Identity's stated scope — BRD §2.1 item 1), no service's requirement-spec or the BRD itself names an owner for an anonymous "guest session" concept; `kart-identity-service/requirement-spec.md` does not mention guest/anonymous sessions at all. Rather than assert a cross-context ownership fact not in evidence, `GuestSessionId` is modeled here as a value object local to Cart's own `CartOwner` — an opaque identifier Cart treats purely as an owner discriminator for merge/lookup purposes. Cart does not model or claim to own session *issuance* or *lifecycle* (who creates it, how long the surrounding client session itself lasts) — only that, whatever opaque identifier arrives with a request, it can serve as one of the two mutually exclusive `CartOwner` shapes. If a future Identity/session-infra pass formally names an owning context for anonymous sessions generally, this local modeling should be revisited as a reference-via-ACL instead.
5. **`CartVersion` is modeled as a first-class value object, not just infra plumbing.** `design-decisions.md`'s optimistic-concurrency decision introduces a version column to prevent lost updates between a direct mutation and a concurrent merge; since it participates directly in enforcing invariants 1–3 against concurrent writers, it is modeled explicitly here rather than treated as an implementation detail invisible to the domain model.

## Sign-off

- [ ] Reviewed by a human
- [ ] Approved to proceed to API/Database/Event Design Agents
