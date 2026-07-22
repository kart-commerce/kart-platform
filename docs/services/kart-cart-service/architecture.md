---
doc_type: architecture
service: kart-cart-service
status: approved
generated_by: architecture-agent
source: docs/services/kart-cart-service/requirement-spec.md, docs/services/kart-cart-service/edge-cases.md, docs/adr/0016-user-gdpr-erasure-policy.md
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
| Inbound (consumed, new) | User Service | `UserDataErased` | **Async** | **ADR-0016** (User Data Erasure Policy) was updated this pass to name Cart directly as an expected consumer — closes the gap found during this service's own documentation pass (no prior draft of any of Cart's docs mentioned ADR-0016). Payload `userId`, `erasedAt`; 5x retry, exponential backoff, on-call paging on DLQ exhaustion (compliance-critical tier, ADR-0016 item 7); consumer-side DLQ `cart.user-data-erased.dlq`. Triggers hard deletion of every `Cart` row (Active or CheckedOut) owned by that `userId`, plus its Redis cache entry (requirement-spec §2, §4, §6 D10; `edge-cases.md`'s "Residual Cart State After a `UserDataErased` Event" decision). |

No dependency edge to Order exists in either direction at the service-boundary level — `CartCheckedOut` is Analytics-only, and Order's own creation path bypasses Cart entirely. The new `UserDataErased` inbound edge above widens Cart's own async fan-in from one publisher (Inventory) to two (Inventory, User Service) — this does not change the Distributed-Monolith Risk assessment below, since it remains async and does not sit on the `/cart` request path.

## Sync vs. Async Resolution

Cart has exactly one synchronous *outbound* dependency (the checkout-time Product/Inventory validation call), and it is deliberately non-blocking on failure. Every other cross-service edge is async (event pub/sub) or inbound-only (the client's own REST calls into Cart). This keeps Cart's own availability decoupled from Product/Inventory's — consistent with Cart (99.9%, Decision D6) and Inventory (order-path tier, per its own requirement-spec) sitting in different availability tiers; a Product/Inventory slowdown must not become a Cart/checkout-initiation outage.

## Distributed-Monolith Risk

**Low, and explicitly mitigated at the design-decision stage, not just noted here.** The one place Cart reaches out synchronously to another service (Product/Inventory, for pre-checkout validation) is guarded by a timeout and circuit breaker that **fail open** — a downstream slowdown degrades UX (a stale item isn't flagged early) rather than blocking checkout initiation or cascading into a Cart outage. This is the correct shape specifically because Cart's own domain invariant already treats a cart line item as non-authoritative (Inventory is the sole enforcer of oversell) — the sync call is an optimization, never a hard gate, so there is no risk of Cart becoming unable to function without Product/Inventory being up.

The remaining edges are async and one-directional in effect (Cart consumes `InventoryReservationFailed`, Cart publishes `CartCheckedOut` to Analytics only) — none of these create a synchronous chain. In particular, Cart is **not** wired into the Order Saga at all (BRD §12), so there is no risk of a chatty Cart↔Order coupling that should have been async: there is no Cart↔Order coupling of any kind at the service-boundary level.

**Resolved on Inventory's side:** `kart-inventory-service/architecture.md` and `api-contract.yaml` now define `InventoryAvailabilityService.CheckAvailability`, a minimal read-only gRPC RPC distinct from the public `GET /inventory/{sku}` REST endpoint — the gRPC channel this service's own `design-decisions.md` calls for. Product's own equivalent endpoint remains a downstream contract-sizing detail for whenever Product's Architecture/API Design stages run; Cart's own boundary and dependency direction are unaffected either way.

**The new `UserDataErased` inbound edge adds no new risk.** It is async, one-way (Cart never calls back synchronously to User Service to consume it), and a slow/down publisher only widens Cart's own compliance-response window for erasure — a risk ADR-0016 item 7's own compliance-critical retry/paging tier already exists to bound, not something Cart's architecture needs to compensate for structurally.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner
- [x] Approved to proceed to DDD Agent
