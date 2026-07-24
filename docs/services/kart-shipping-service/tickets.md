---
doc_type: tickets
service: kart-shipping-service
status: approved
generated_by: ticket-agent
source: [architecture.md, ddd-model.md, api-contract.yaml, database-design.md, event-contract.md, requirement-spec.md, edge-cases.md, design-decisions.md — all approved]
---

# Tickets: kart-shipping-service

Local draft. Not yet created as real GitHub Issues — that requires the target repo to exist (Project Scaffold Agent) and is a separate, explicit step. Ticket prefix `SHIP-` per `kart-conventions.md`.

## Epic: kart-shipping-service v1

Post-confirmation, fully-async fulfillment step (BRD §2.1 item 16) — carrier selection and label generation for an already-confirmed order. Sole trigger is consuming `OrderConfirmed` (ADR-0002); Shipping has no synchronous inbound endpoint Order calls, sits at the platform's secondary-availability tier by construction, and publishes `ShipmentDispatched`/`ShipmentCreationFailed` (ADR-0015) once the out-of-band carrier interaction resolves. One aggregate (`Shipment`, keyed on `order_id`), one PostgreSQL write model, no read-model projection — every ticket below decomposes directly from the five approved design docs, with no invented scope beyond them.

| ID | Task | Vertical Slice (Application/Features/) | Depends On | Design Source |
|---|---|---|---|---|
| SHIP-1 | Consume `OrderConfirmed` and persist Shipment intent | `CreateShipmentOnOrderConfirmed` | — | `event-contract.md` `OrderConfirmed` (consumed); `ddd-model.md` `Shipment` aggregate root creation + Uniqueness/Idempotent-consumption invariants; `database-design.md` `shipments`/`shipment_outbox` schema, `UNIQUE(order_id)`, pre-carrier-call existence check, `CarrierCallRequested` outbox marker inserted in the same transaction; establishes the write-path P95 < 300ms budget (requirement-spec §3) |
| SHIP-2 | Carrier-call worker — resolve carrier attempt, write terminal state + domain-event outbox rows | `ResolveCarrierCallForShipment` (`Infrastructure/CarrierCallWorker/` — out-of-band worker, not a request-path feature) | SHIP-1 | `database-design.md`'s carrier-call worker section (`idx_shipment_outbox_pending_carrier_calls`, `SELECT ... FOR UPDATE SKIP LOCKED`); `ddd-model.md` `CarrierSelectionPolicy` (ordered priority list), `ShipmentStatus` `Pending → {Dispatched, Failed}` monotonic-terminal transition, `trg_shipments_status_guard`; `design-decisions.md`'s Resilience Pattern decision (per-carrier circuit breaker + bulkhead, primary→secondary fallback); `event-contract.md`'s `ShipmentDispatched`/`ShipmentCreationFailed` (rows inserted here, not yet published to RabbitMQ — see SHIP-3); ADR-0015 |
| SHIP-3 | Outbox relay poller — publish resolved domain events to RabbitMQ | `PublishShipmentOutboxEvents` (`Infrastructure/OutboxRelay/`) | SHIP-2 | `database-design.md` `idx_shipment_outbox_pending_publish`; `event-contract.md`'s `ShipmentDispatched` (`shipping.shipment.dispatched`, `shipping.shipment-dispatched.dlq`) and `ShipmentCreationFailed` (`shipping.shipment.creation-failed`, `shipping.shipment-creation-failed.dlq`), both 3x retry standard tier per `design-decisions.md`'s Retry/DLQ Tiering decision; BRD §11 Outbox Pattern, same shape as `kart-order-service`'s/`kart-inventory-service`'s own relays |
| SHIP-4 | List/query shipments (ops triage) | `ListShipments` | SHIP-1 | `api-contract.yaml` `GET /v1/shipments` (`orderId`/`status`/`carrier` filters, cursor pagination, `opsPrincipal:shipments-read`); primary use case is filtering `status=Failed` for manual reconciliation (ddd-model.md's "must still reach a terminal, signaled state" invariant) |
| SHIP-5 | Get a single shipment by id | `GetShipment` | SHIP-1 | `api-contract.yaml` `GET /v1/shipments/{id}` (`opsPrincipal:shipments-read`); `ShipmentView` schema |
| SHIP-6 | Manually create a shipment (ops-only) | `CreateShipmentManually` | SHIP-1 | `api-contract.yaml` `POST /v1/shipments` (mandatory `Idempotency-Key`, `opsPrincipal:shipments-write`, `202`/`409`/`422`/`401`); reuses SHIP-1's exact existence-check + insert code path (`ddd-model.md` Modeling Decision #8: "a second access path onto one aggregate, not a second bounded-context concept"); narrow scope for the case an `OrderConfirmed` was never consumed for a genuinely-confirmed order |

## Flagged Gaps — Not Decomposed Into Tickets (would invent scope, not decompose it)

- **`shipment_outbox` retention/pruning job.** `database-design.md`'s "Where Does the Destination Address Live?" section recommends routine pruning of processed `CarrierCallRequested` rows (the only place the address-bearing payload lives) as a "defensible default," but explicitly does not fix a hard TTL number — no requirement-spec/architecture NFR states one. No ticket until a concrete retention policy is decided; premature to build against an invented number.
- **`Failed → Pending`/reopen retry transition for an already-Failed shipment.** `ddd-model.md` Modeling Decision #7 and `api-contract.yaml`'s `POST /v1/shipments` `409` response both explicitly decline to model this ("no automatic `Failed → Dispatched` retry transition of its own"). Flagged as an open question for a future pass — either a new aggregate transition or a documented manual-remediation runbook — not something this ticket list can build without a modeled transition to implement against.
- **Cross-service PII-redaction wiring for `UserDataErased`.** `database-design.md`'s GDPR Erasure section notes ADR-0016 does not name Shipping as a `UserDataErased` consumer, and `shipment_outbox` has no `user_id` column to key a redaction against even if it did; whether `OrderConfirmed`'s payload should carry `userId` so a future handler could key one is a `kart-order-service` event-contract decision, not this service's backlog.
- **Order's reconciliation of the `ShipmentCreationFailed` reaction.** `architecture.md`'s Dependencies table flags that `kart-order-service/edge-cases.md`'s existing reverse-compensation description (release Inventory, then refund Payment) has not yet been reconciled with ADR-0015's "held / fulfillment-exception" status — explicitly deferred to Order's own next pipeline pass (already tracked there, e.g. `ORD-11`/`ORD-12`), not a gap in this service's own ticket list.

## Notes for Sprint Planner Agent

- SHIP-1 is the one true root dependency — every other ticket needs the `shipments`/`shipment_outbox` schema and the existence-check/insert mechanism it establishes to exist first.
- SHIP-4, SHIP-5, and SHIP-6 only need SHIP-1's schema/row shape and are independent of each other and of SHIP-2/SHIP-3 — can all be built in parallel with SHIP-2 once SHIP-1 lands.
- SHIP-2 → SHIP-3 is a strictly sequential pair (SHIP-3 publishes rows SHIP-2 writes) — the same "carrier-call worker, then outbox-relay poller" shape `kart-order-service`'s ORD-1 → ORD-2 and `kart-inventory-service`'s equivalent Outbox pattern already use.
- SHIP-6 (`CreateShipmentManually`) shares its core creation logic (pre-carrier-call existence check, `Pending` insert, `CarrierCallRequested` marker) with SHIP-1's `OrderConfirmed` consumer — recommend the engineer who builds SHIP-1 also builds SHIP-6, or at minimum factors that shared logic into one internal call both entry points invoke, rather than duplicating the idempotency mechanism in two places. Same grouping rationale `kart-payment-service/tickets.md` gives for its own shared-mechanism tickets (PAY-6/PAY-7/PAY-8).
- No circular dependencies in this graph. Longest chain is SHIP-1 → SHIP-2 → SHIP-3, 3 deep.
- Out of scope for this service's own backlog: the four items in "Flagged Gaps" above — none require a ticket at this stage, either because no concrete number/transition/contract has been fixed yet to build against, or because the decision belongs to `kart-order-service`'s own pipeline pass.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner
- [x] Approved
