---
doc_type: architecture
service: kart-cart-service
status: pending-approval
generated_by: architecture-agent
source: docs/services/kart-cart-service/requirement-spec.md
---

# Architecture: kart-cart-service

## Boundary Rationale

`kart-cart-service` is the bounded context that answers "what is this customer about to buy, right now, before they commit" — it owns the mutable pre-checkout basket: lifecycle (add/update/remove line items), merge (guest-session cart reconciled into a logged-in user's cart), and expiry (abandoned-cart reclamation). Per the requirement-spec's own Scope (§1), Cart stands alone as its own bounded context — unlike Offer, no ADR merges it with a sibling BRD row.

Cart sits directly ahead of checkout: it is the **last place a customer's intent is still mutable** before Order takes over as the sole Saga orchestrator (BRD §5.1). This is a hard boundary, not just sequencing — Cart's own domain invariant (requirement-spec §4) is explicit that a cart line item is *not* a reservation; only Inventory enforces the oversell invariant. Cart never participates in the Order Saga (BRD §12: only Order, Inventory, Payment, Shipping have saga steps) and never gates or blocks `POST /orders` — the client calls Order directly and synchronously; Cart is not in that call path at all (confirmed by ADR-0007 and `kart-order-service/requirement-spec.md` §5, which does not list `CartCheckedOut` among Order's consumed events).

This places Cart in the same architectural tier as Product/Search/Identity: a customer-facing, pre-Saga edge service reached through the API Gateway. A Cart outage blocks browsing-to-checkout initiation (same failure mode as Product/Search) but cannot corrupt or stall an order Saga already in flight — the reasoning already recorded for its 99.9%-secondary availability tier (requirement-spec Decision D6).

## Dependencies

| Direction | Peer Service | Mechanism | Type | Notes |
|---|---|---|---|---|
| Inbound (client, via API Gateway) | Client / Checkout UI | `/cart` (add/update/remove), `POST /cart/merge` | **Sync** (REST) | Cart's own public surface (BRD §5.4); verb-level HTTP contract is non-blocking, carried to API Design Agent (requirement-spec D9) |
| Inbound (consumed) | Inventory | `InventoryReservationFailed` | **Async** | Cart is a secondary consumer alongside Order (BRD §10); idempotent, pre-checkout-only handling — flags the line item unavailable, no-op once the cart has already checked out (Decision D3) |
| Outbound (published) | Analytics | `CartCheckedOut` | **Async** | Funnel/conversion tracking only (BRD §10, ADR-0007). **Not consumed by Order** — Order's creation trigger is the client's own synchronous `POST /orders` call, confirmed by ADR-0007 and `kart-order-service/requirement-spec.md` §5. `CartCheckedOut` is audit/analytics-only, never a Saga-triggering event. |
| Outbound (sync, checkout-time only, best-effort) | Product, Inventory | Lazy stock/price validation call | **Sync** (gRPC), timeout-guarded + circuit breaker, **fails open** | Resolved in `design-decisions.md`'s "Resilience Pattern for Checkout-Time Stock/Price Validation": reserved for this exact shape per the reusable API standards ("internal, high-throughput synchronous calls... e.g. an inventory reserve check"). On breaker-open/timeout, checkout proceeds *without* the pre-check rather than blocking — this call is a UX improvement (surface unavailability earlier), never a gate, since Inventory alone enforces the oversell invariant at reservation time. |

No dependency edge to Order exists in either direction at the service-boundary level — `CartCheckedOut` is Analytics-only, and Order's own creation path bypasses Cart entirely.

## Sync vs. Async Resolution

Cart has exactly one synchronous *outbound* dependency (the checkout-time Product/Inventory validation call), and it is deliberately non-blocking on failure. Every other cross-service edge is async (event pub/sub) or inbound-only (the client's own REST calls into Cart). This keeps Cart's own availability decoupled from Product/Inventory's — consistent with Cart (99.9%, Decision D6) and Inventory (order-path tier, per its own requirement-spec) sitting in different availability tiers; a Product/Inventory slowdown must not become a Cart/checkout-initiation outage.

## Distributed-Monolith Risk

**Low, and explicitly mitigated at the design-decision stage, not just noted here.** The one place Cart reaches out synchronously to another service (Product/Inventory, for pre-checkout validation) is guarded by a timeout and circuit breaker that **fail open** — a downstream slowdown degrades UX (a stale item isn't flagged early) rather than blocking checkout initiation or cascading into a Cart outage. This is the correct shape specifically because Cart's own domain invariant already treats a cart line item as non-authoritative (Inventory is the sole enforcer of oversell) — the sync call is an optimization, never a hard gate, so there is no risk of Cart becoming unable to function without Product/Inventory being up.

The remaining edges are async and one-directional in effect (Cart consumes `InventoryReservationFailed`, Cart publishes `CartCheckedOut` to Analytics only) — none of these create a synchronous chain. In particular, Cart is **not** wired into the Order Saga at all (BRD §12), so there is no risk of a chatty Cart↔Order coupling that should have been async: there is no Cart↔Order coupling of any kind at the service-boundary level.

One item worth flagging forward to the API Design Agent for Product/Inventory: today their only documented public surface is REST (`GET /products/{id}`, `GET /inventory/{sku}`) — the gRPC channel `design-decisions.md` calls for on Cart's side implies Product and/or Inventory must also expose an internal gRPC endpoint for this validation call. This is a downstream contract-sizing detail, not a boundary-level gap; Cart's own boundary and dependency direction are unaffected either way.

## Sign-off

- [ ] Reviewed by a human
- [ ] Approved to proceed to DDD Agent
