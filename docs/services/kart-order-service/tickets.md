---
doc_type: tickets
service: kart-order-service
status: approved
generated_by: ticket-agent
source: [architecture.md, ddd-model.md, api-contract.yaml, database-design.md, event-contract.md, design-decisions.md — all approved]
---

# Tickets: kart-order-service

Local draft. Not yet created as real GitHub Issues — that requires the target repo to exist (Project Scaffold Agent) and is a separate, explicit step.

## Epic: kart-order-service v1

The platform's sole Saga orchestrator — order lifecycle state machine, Inventory/Payment/Shipping/Delivery Tracking coordination, and the two new post-approval reactions (`ChargebackReceived`, `ShipmentCreationFailed`/`FulfillmentException`) ADR-0012 and ADR-0015 named this service as needing.

| ID | Task | Vertical Slice (Application/Features/) | Depends On | Design Source |
|---|---|---|---|---|
| ORD-1 | Create order (sync Inventory reserve, idempotent) | `CreateOrder` | — | `api-contract.yaml` `POST /v1/orders`; `ddd-model.md` `Order`/`OrderLineItem`/`IdempotencyKey`; `database-design.md` `orders`/`order_items`/`order_events` write mechanics; `architecture.md`'s sync Inventory reserve edge |
| ORD-2 | Outbox poller (publish `order_events` rows to RabbitMQ) | `PublishOutboxEvents` | ORD-1 | `database-design.md` `idx_outbox_unpublished`; BRD §11 Outbox Pattern; `event-contract.md`'s five published events |
| ORD-3 | Read-model projector (`order_events` → MongoDB `order_read_model`) | `ProjectOrderReadModel` | ORD-1 | `database-design.md` Read Model section; BRD §7 CQRS |
| ORD-4 | Get order | `GetOrder` | ORD-3 | `api-contract.yaml` `GET /v1/orders/{id}` |
| ORD-5 | Cancel order (client-initiated, pre-Shipped only) | `CancelOrder` | ORD-1 | `api-contract.yaml` `POST /v1/orders/{id}/cancel`; `ddd-model.md`'s Legal Transitions + Compensation completeness invariants; edge-cases.md "Client Cancel Request Racing an In-Flight Saga" |
| ORD-6 | Advance saga on Inventory reservation outcome | `AdvanceOnInventoryOutcome` | ORD-1 | `event-contract.md` `InventoryReserved`/`InventoryReservationFailed` (consumed); `ddd-model.md` `Created → Reserved` transition |
| ORD-7 | Advance saga on payment completion (publish `OrderConfirmed`) | `ConfirmOrderOnPaymentCompleted` | ORD-6 | `event-contract.md` `PaymentCompleted` (consumed), `OrderConfirmed` (published); ADR-0002 |
| ORD-8 | Pre-confirmation compensation on payment failure | `CompensateOnPaymentFailed` | ORD-6 | `event-contract.md` `PaymentFailed` (consumed), `OrderCompensationTriggered`/`OrderCancelled` (published); edge-cases.md "Payment-Success/Shipping-Failure Compensation Ordering" (the reverse-order mechanism this ticket and ORD-11 both rely on) |
| ORD-9 | Advance saga on shipment dispatch | `AdvanceOnShipmentDispatched` | ORD-7 | `event-contract.md` `ShipmentDispatched` (consumed); `ddd-model.md` `Paid → Shipped` |
| ORD-10 | Advance saga on terminal delivery status (publish `OrderDelivered`) | `CompleteOrderOnDelivery` | ORD-9 | `event-contract.md` `DeliveryStatusUpdated` (consumed), `OrderDelivered` (published); ADR-0005; edge-cases.md's `Shipped`-guard and duplicate-delivery decisions |
| ORD-11 | Enter fulfillment exception on shipment creation failure | `EnterFulfillmentException` | ORD-7 | `event-contract.md` `ShipmentCreationFailed` (consumed, ADR-0015); `ddd-model.md` `Paid → FulfillmentException`; edge-cases.md "Shipment Creation Permanently Fails After Order Confirmation" |
| ORD-12 | Resolve fulfillment exception (admin-triggered retry or cancel-with-refund) | `ResolveFulfillmentException` | ORD-11 | `api-contract.yaml` `POST /v1/orders/{id}/resolve-fulfillment-exception`; `ddd-model.md`'s `FulfillmentException → Paid`/`→ Cancelled` transitions; design-decisions.md "Post-Confirmation Fulfillment Exception Handling" |
| ORD-13 | React to chargeback (direct `→ Refunded`, conditional inventory release) | `ReactToChargeback` | ORD-7 | `event-contract.md` `ChargebackReceived` (consumed, ADR-0012); `ddd-model.md`'s chargeback `→ Refunded` carve-out; design-decisions.md "Chargeback Reaction Mechanism"; shares the same conditional Inventory-release code path ORD-8 establishes |
| ORD-14 | Orphaned/stuck saga reconciliation sweep | `ReconcileStuckSagas` | ORD-1 | edge-cases.md "Orphaned/Stuck Saga Detection"; design-decisions.md's per-step staleness thresholds; `database-design.md`'s `idx_orders_status_created` |

## Notes for Sprint Planner Agent

- ORD-1 is the one true root dependency — every other ticket needs `orders`/`order_items`/`order_events` to exist first. ORD-2/ORD-3/ORD-5/ORD-6/ORD-14 can all start in parallel immediately after ORD-1 lands.
- The Saga-advancement chain is inherently sequential in dependency (ORD-6 → ORD-7 → {ORD-9 → ORD-10, ORD-11 → ORD-12}), mirroring the actual state machine's own shape — this is not an artificial ticket-ordering choice, it reflects that each slice's handler needs the prior transition's guard already in place to test against.
- ORD-8 and ORD-13 are the same shape of task (compensating action releasing Inventory, then a terminal write) and should share an implementation module — recommend the engineer who builds ORD-8 also builds ORD-13, the same grouping rationale `kart-offer-service/tickets.md` uses for its own shared-mechanism tickets (OFF-2/OFF-10).
- ORD-11/ORD-12 (the `FulfillmentException` pair) and ORD-13 (chargeback) are fully independent of each other — both only depend on ORD-7 (the order must be able to reach `Paid`), so they can be built in parallel once ORD-7 lands.
- No circular dependencies in this graph. Longest chain is ORD-1 → ORD-6 → ORD-7 → ORD-9 → ORD-10 (or → ORD-11 → ORD-12), 5 deep — the full happy-path-through-delivery chain, which is expected given Order's role as the single state machine every other slice advances.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner
