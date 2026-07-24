---
doc_type: architecture
service: kart-order-service
status: approved
generated_by: architecture-agent
source: docs/services/kart-order-service/requirement-spec.md, docs/services/kart-order-service/edge-cases.md, docs/services/kart-order-service/design-decisions.md
---

# Architecture: kart-order-service

## Boundary Rationale

`kart-order-service` is the bounded context that answers "what state is this order in, and who drives it there" — it owns the order lifecycle state machine end-to-end (`Created → Reserved → Paid → Shipped → Delivered → Cancelled/Refunded`, extended with the non-terminal `FulfillmentException` hold state per ADR-0015) and is the platform's **sole Saga orchestrator** (BRD §5.1 Boundary Rationale): no other service may drive a cross-service business transaction. This is an architectural invariant, not a convenience — it exists specifically to prevent a "distributed monolith" where Inventory, Payment, and Shipping would otherwise need to call each other directly to coordinate a checkout.

Order does not own Inventory's stock truth, Payment's charge/refund lifecycle, or Shipping's carrier/label logic — it only orchestrates the sequence and owns the single source of truth for *where a given order is* in that sequence. This is the same boundary-rationale pattern already established for `kart-payment-service`'s and `kart-inventory-service`'s own approved architecture docs, both of which already record their side of these edges (see `docs/architecture/service-boundaries.md`) — this document formalizes the Order-side half of a contract those two services' own Architecture Agent passes already anticipated while waiting for this service to reach this stage.

Order sits in the platform's highest availability/consistency tier (99.99% order path, BRD §3) — its own write path (`POST /orders`) must remain fast and available even when downstream Saga participants (Payment, Shipping, Delivery Tracking) are degraded, which is exactly why every downstream leg except the one BRD-mandated synchronous call (Inventory reserve) is async.

## Dependencies

| Direction | Peer Service | Mechanism | Type | Notes |
|---|---|---|---|---|
| Inbound (client) | Client / Checkout UI, via API Gateway | `POST /orders`, `GET /orders/{id}`, `POST /orders/{id}/cancel` | **Sync** (REST) | `POST /orders` returns `202 Accepted` after the write-side transaction commits (BRD §7 CQRS), not after the Saga completes; `GET /orders/{id}` reads the MongoDB projection, never PostgreSQL directly |
| Outbound (saga step 1) | Inventory | `POST /inventory/reserve` | **Sync** (REST) | The one BRD-mandated synchronous saga leg (ADR-0009 confirms ADR-0002's async note does not extend here); 2s timeout budget, circuit breaker (design-decisions.md) |
| Outbound (saga compensation) | Inventory | `POST /inventory/release` | **Sync** (REST) | Fires on pre-confirmation compensation (Payment failed) or post-confirmation compensation ordering (edge-cases.md, Open Questions resolution #1); idempotent on `reservationId` per Inventory's own `ddd-model.md` |
| Outbound (saga compensation) | Payment | `POST /payments/{id}/refund` | **Sync** (REST) | Two distinct triggers: (a) reverse-order compensation when Payment succeeded but a later step fails (Open Questions resolution #1); (b) resolving a `FulfillmentException` into `Cancelled` (ADR-0015). Direct service-to-service call, not gateway-proxied — matches `kart-payment-service/architecture.md`'s already-recorded "Compensation-Refund Trigger" section exactly, including its deterministic `Idempotency-Key` derivation from `(orderId, paymentIntentId, "compensation-refund")` |
| Inbound (consumed, async) | Inventory | `InventoryReserved`, `InventoryReservationFailed` | **Async** | Saga-advancement signal for the synchronous reserve call above — the reservation call and this event are two different things (ADR-0009), not one round-trip |
| Inbound (consumed, async) | Payment | `PaymentCompleted`, `PaymentFailed` | **Async** | Payment initiates the charge on its own `OrderCreated` consumption — Order never calls Payment synchronously to charge (`kart-payment-service/architecture.md`'s Sync/Async Resolution) |
| Inbound (consumed, async) | Payment | `ChargebackReceived` (new, ADR-0012) | **Async** | Drives direct `→ Refunded` transition from any state `Paid` through `Delivered`; never triggers an outbound refund call — see requirement-spec.md's "Chargeback Reaction" |
| Inbound (consumed, async) | Shipping | `ShipmentDispatched` | **Async** | Informational status update only, per ADR-0002 — does not gate `OrderConfirmed` |
| Inbound (consumed, async) | Shipping | `ShipmentCreationFailed` (new, ADR-0015) | **Async** | Drives `Paid → FulfillmentException` — see requirement-spec.md's "Post-Confirmation Fulfillment Exception Handling" |
| Inbound (consumed, async) | Delivery Tracking | `DeliveryStatusUpdated` (terminal "delivered" value only) | **Async** | Sole trigger for `Shipped → Delivered` and the `OrderDelivered` publish (ADR-0005) |
| Inbound (internal, sync) | Admin Service | `POST /orders/{id}/resolve-fulfillment-exception` (new — resolves requirement-spec's carried-forward API-surface question) | **Sync** (REST, internal-only) | Manual resolution trigger for `FulfillmentException` (retry vs. cancel-with-refund). Resolved here as a dedicated Order-owned endpoint, callable only by Admin Service's client-credentials service principal — the same integration shape ADR-0010 already establishes for every other admin-triggered write on the platform (Admin calling Product/Category/Offer/Identity/Inventory's own APIs directly, never duplicating their state). No ops tooling outside this service's own API is introduced. |
| Outbound (published) | Payment, Analytics | `OrderCreated` | **Async** | 5x retry, `order.dlq`, paged on-call (requirement-spec §3, elevated tier) |
| Outbound (published) | Shipping, Notification, Analytics | `OrderConfirmed` | **Async** | Published as soon as `PaymentCompleted` is received (ADR-0002) — not gated on shipment creation |
| Outbound (published) | Inventory, Offer, Notification, Analytics | `OrderCancelled` | **Async** | Offer consumes to void a coupon redemption (`kart-offer-service/architecture.md`) |
| Outbound (published) | Inventory, Notification, Analytics | `OrderCompensationTriggered` | **Async** | Pre-confirmation compensation signal (ADR-0007) |
| Outbound (published) | Recommendation, Review, Notification, Analytics | `OrderDelivered` | **Async** | Unifies the BRD's phantom `OrderCompleted`/`OrderDelivered` naming (ADR-0005) |

## Sync/Async Resolution (confirms ADR-0002, ADR-0009 — no new ambiguity)

Order has exactly **three** synchronous outbound edges — Inventory reserve, Inventory release, Payment refund — and **one** synchronous inbound edge (Admin's fulfillment-exception resolution call). Every other cross-service interaction is async pub/sub. This is not an oversight requiring further resolution; it is the fully-settled shape ADR-0002 (Order↔Shipping fully async), ADR-0009 (Order↔Inventory reserve call is genuinely sync), and `kart-payment-service/architecture.md`'s own "Compensation-Refund Trigger" section (documenting the Payment-side half of the refund call this doc's Dependencies table records the Order-side half of) already establish. Nothing here reopens any of those three ADRs/decisions — this section exists only to confirm, from Order's own side, that its dependency table matches what Inventory's and Payment's already-approved docs independently expect of it.

## Distributed-Monolith Risk

**Bounded, not a distributed-monolith pattern, for three reasons:**

1. **No transitive synchronous chain.** Order's synchronous calls terminate at their target — Inventory's reserve/release and Payment's refund endpoints do not themselves synchronously call any other Kart service (confirmed against both services' own approved `architecture.md`). A slow Inventory or Payment does not cascade into a third service's latency budget through Order.
2. **Every synchronous edge is justified by BRD-stated necessity, not convenience.** Inventory reserve is the one leg BRD §5.1/§5.2 and ADR-0009 fix as genuinely blocking (it must complete before `POST /orders` can commit an order that has any chance of being fulfilled). Inventory release and Payment refund are compensating actions on the Saga orchestrator's own rare failure path (Payment-succeeded/later-step-failed, or `FulfillmentException` resolution) — not the common-case request path, and each carries its own circuit breaker and timeout (design-decisions.md).
3. **The one inbound sync edge (Admin's resolution call) is deliberately narrow.** It only exists to move an order out of the deliberately-manual `FulfillmentException` hold state — a low-frequency, operator-driven action, not a chatty dependency, and it mirrors the same Admin-calls-owning-service-directly pattern already used platform-wide (ADR-0010).

**One risk worth naming for the Database Design Agent:** the synchronous Inventory reserve call sits directly inside `POST /orders`'s own P95 < 300ms write-path budget (requirement-spec §3) — this means the write-side schema must support committing the order/outbox row immediately once Inventory's reserve response returns, with no additional synchronous work after it, consistent with the Outbox Pattern (BRD §11) already keeping event publication itself off the critical path.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner
- [x] Approved to proceed to DDD Agent
