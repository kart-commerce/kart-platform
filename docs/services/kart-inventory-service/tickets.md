---
doc_type: tickets
service: kart-inventory-service
status: approved
generated_by: ticket-agent
source: [requirement-spec.md, edge-cases.md, design-decisions.md, architecture.md, ddd-model.md, api-contract.yaml, database-design.md, event-contract.md]
---

# Tickets: kart-inventory-service

Local draft. Not yet created as real GitHub Issues — that requires the target repo to exist (Project Scaffold Agent) and is a separate, explicit step.

All 9 upstream design artifacts for this service are `status: approved`. Eight vertical slices below cover every REST endpoint, the internal gRPC RPC, the two consumed events, and the one background process (`api-contract.yaml`'s three REST paths + one gRPC RPC, `event-contract.md`'s two consumed events, and the TTL sweep `design-decisions.md`/`ddd-model.md` both require) — nothing is left undecomposed.

## Epic: kart-inventory-service v1

Stock truth per warehouse/SKU, synchronous reservation holds with TTL, and oversell prevention via row-level pessimistic locking — the platform's highest-contention service and a mandatory Order Saga participant (`architecture.md`, Boundary Rationale).

| ID | Task | Vertical Slice (Application/Features/) | Depends On | Design Source |
|---|---|---|---|---|
| INV-1 | Reserve stock (single-warehouse-first, multi-warehouse fallback) | `ReserveStock` | — | `api-contract.yaml` `POST /inventory/reserve`; `ddd-model.md` `WarehouseStock`/`Reservation`/`WarehouseAllocation`; `database-design.md` `warehouse_stock` (`SELECT ... FOR UPDATE`), `reservations`, `reservation_allocations`; `design-decisions.md` "Concurrency Control Pattern for Stock Rows", "Resilience Budget" (lock_timeout); `event-contract.md` `InventoryReserved`/`InventoryReservationFailed` |
| INV-2 | Release a reservation (explicit call) | `ReleaseReservation` | INV-1 | `api-contract.yaml` `POST /inventory/release`; `ddd-model.md` `ReservationStatus` terminal-state machine; `database-design.md` `reservations.status`/`release_reason = 'explicit_call'`; `event-contract.md` `InventoryReleased` |
| INV-3 | Consume `OrderCancelled` — release the associated reservation | `ConsumeOrderCancelled` | INV-1 | `event-contract.md` Consumed Events; `database-design.md` `idx_reservations_order_id`, `release_reason = 'order_cancelled'`; same idempotent release path as INV-2 |
| INV-4 | Consume `OrderCompensationTriggered` — release as saga compensation | `ConsumeOrderCompensationTriggered` | INV-1 | `event-contract.md` Consumed Events; `database-design.md` `release_reason = 'compensation_triggered'`; same idempotent release path as INV-2 |
| INV-5 | TTL sweep — auto-release expired reservations | `SweepExpiredReservations` | INV-1 | `requirement-spec.md` Decision 2 (15-min TTL, 60s sweep interval); `database-design.md` `idx_reservations_expiry_sweep`, `release_reason = 'ttl_expiry'`; `edge-cases.md` "Reservation left dangling", "TTL firing while Payment is merely slow"; same idempotent release path as INV-2 |
| INV-6 | Get current stock level (public read) | `GetStockLevel` | — | `api-contract.yaml` `GET /inventory/{sku}`; `design-decisions.md` "Read-Path Caching Strategy" (short-TTL Redis cache-aside); `database-design.md` `idx_warehouse_stock_sku` |
| INV-7 | Check availability (internal gRPC, consumed by Cart) | `CheckAvailability` | INV-6 | `api-contract.yaml`'s `InventoryAvailabilityService.CheckAvailability`; `architecture.md`'s "API Surface Consistency Note — Resolved"; reuses INV-6's same cache-aside read path under a different protocol |
| INV-8 | Replenish stock (threshold-triggered automated reorder + manual admin path) | `ReplenishStock` | — | `requirement-spec.md` Decision 5 (20% default reorder threshold, per-SKU override); `edge-cases.md` "Replenishment racing an active reservation" (same lock-compatible write as reservation); `database-design.md` `warehouse_stock.replenishment_threshold`; `event-contract.md` `InventoryReplenished` |

## Flagged Gaps — Not Decomposed Into Tickets (would invent scope, not decompose it)

- **No public endpoint for configuring `replenishment_threshold`/`target_stocking_level` per SKU.** requirement-spec.md Decision 5 states per-SKU override is supported but names no admin-facing endpoint for setting it — consistent with `kart-category-service`/`kart-identity-service`'s own precedent of not inventing a management UI/endpoint the BRD never asks for. No ticket; INV-8's write path accepts a threshold value but who sets it administratively is a future API Design Agent pass if a self-service need emerges.
- **No ticket for warehouse master-data management** (address, capacity, operating hours) — `ddd-model.md`'s Modeling Decision #2 confirms this is explicitly out of scope; `warehouse_id` is treated as an opaque, externally-assigned identifier.

## Notes for Sprint Planner Agent

- INV-1 (`ReserveStock`) is the foundation task — INV-2, INV-3, INV-4, and INV-5 all need at least one existing reservation to release. Build it first among the write slices.
- INV-2, INV-3, INV-4, and INV-5 are four independent entry points into the *same* idempotent release path (`ddd-model.md`'s terminal-state machine) — they share nearly all their domain logic and differ only in trigger source. Recommend implementing the shared release-path logic once (as part of INV-2) and having INV-3/INV-4/INV-5 each wire a different trigger into it, rather than four separate implementations.
- INV-6 (`GetStockLevel`) has no dependency and can start immediately; INV-7 (`CheckAvailability`) reuses its cache-aside path, so build INV-6 first.
- INV-8 (`ReplenishStock`) is independent of every reservation/release ticket — it only touches `warehouse_stock`, never `reservations` — and can be built in parallel with INV-1 through INV-7.
- No circular dependencies in this graph. Longest chain is 2 nodes (INV-1 → any of INV-2/INV-3/INV-4/INV-5, or INV-6 → INV-7).
