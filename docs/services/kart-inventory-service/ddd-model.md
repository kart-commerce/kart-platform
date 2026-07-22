---
doc_type: ddd-model
service: kart-inventory-service
status: approved
generated_by: ddd-agent
source: docs/services/kart-inventory-service/requirement-spec.md, docs/services/kart-inventory-service/edge-cases.md, docs/services/kart-inventory-service/design-decisions.md, docs/services/kart-inventory-service/architecture.md
---

# DDD Model: kart-inventory-service

Two aggregate roots, each its own transaction boundary under normal operation — the platform's highest-contention service, so the boundary/locking shape matters more here than almost anywhere else on the platform. This model formalizes what `design-decisions.md` and `architecture.md` already implied consistently.

## Aggregate: WarehouseStock

**Entity:** `WarehouseStock` — identified by `(WarehouseId, Sku)`. The row `SELECT ... FOR UPDATE` locks (design-decisions.md, "Concurrency Control Pattern for Stock Rows").

**Value objects:**
- `AvailableQuantity` — non-negative integer; the oversell invariant is exactly "this never goes below zero under concurrent writers."
- `ReplenishmentThreshold` — the per-SKU-per-warehouse reorder point (default 20% of target stocking level, requirement-spec.md Decision 5); crossing it below `AvailableQuantity` surfaces a reorder signal inside the same locked write that crossed it.

**Invariants:**
- `AvailableQuantity` must never go negative — the platform's canonical oversell-prevention rule (requirement-spec.md §2.2, §4).
- Every writer that touches a `WarehouseStock` row — reservation debit, release credit, or replenishment credit — takes the same `SELECT ... FOR UPDATE` lock inside one transaction; no writer is permitted an application-level read-then-write against this aggregate (edge-cases.md, "Replenishment racing an active reservation").
- Crossing below `ReplenishmentThreshold` is detected inside the same locked write that caused the crossing, never a separate polling pass (requirement-spec.md Decision 5).

**Domain events:**
- `InventoryReplenished` (published — existing, BRD §5.2/§10 per ADR-0007; payload `sku, qtyAdded, warehouseId`).

## Aggregate: Reservation

**Entity:** `Reservation` — identified by `ReservationId`; the hold created by a `POST /inventory/reserve` call, correlated 1:1 with one `orderId` line-item request.

**Child entity:**
- `WarehouseAllocation` — one `(WarehouseId, Qty)` pair per warehouse this reservation drew from; a single-warehouse reservation has exactly one, a multi-warehouse fallback (requirement-spec.md Decision 3) has two or more, all created atomically in the same transaction as the fallback's multi-row lock.

**Value objects:**
- `ReservationStatus` — `Reserved | Released | Expired`, a terminal-state machine (design-decisions.md, "Release Idempotency & State Machine Design"): once `Released` or `Expired`, no further transition is possible and any release trigger against it is a no-op that still returns success.
- `ReservationTtl` — fixed at 15 minutes from creation (requirement-spec.md Decision 2), the deadline the periodic sweep checks against.

**Invariants:**
- A `Reservation`'s total requested quantity resolves to exactly one all-or-nothing allocation decision across its `WarehouseAllocation` children, computed inside one transaction — never a partial success where some units are allocated and others are not (requirement-spec.md §4).
- Release — via explicit `POST /inventory/release`, consuming `OrderCancelled`, consuming `OrderCompensationTriggered`, or the TTL sweep — is idempotent: transitioning an already-terminal `Reservation` is a no-op, never a double-credit back to `WarehouseStock.AvailableQuantity` and never a duplicate `InventoryReleased` publish.
- `InventoryReserved` is published only after the `WarehouseStock` debit(s) and the `Reservation` row are durably committed in the same transaction (Outbox pattern) — never before, so Order cannot advance the saga on a reservation that could still fail to persist.
- `InventoryReleased` is published only after the compensating `WarehouseStock` credit(s) are durably committed, mirroring the invariant above.

**Domain events:**
- `InventoryReserved` (published — existing, BRD §10; payload `orderId, sku, qty`)
- `InventoryReservationFailed` (published — existing, BRD §10; payload `orderId, sku`)
- `InventoryReleased` (published — existing, BRD §10 per ADR-0007; payload `orderId, sku, qty`)
- `OrderCancelled` (consumed — existing, BRD §10; triggers release)
- `OrderCompensationTriggered` (consumed — existing, BRD §10 per ADR-0007; triggers release as the saga's compensating action)

## Cross-Aggregate Interaction

Reserving stock is the one operation that touches both aggregates in a single transaction: it locks one or more `WarehouseStock` rows (single-warehouse-first, multi-warehouse fallback locked in ascending `warehouse_id` order — requirement-spec.md Decision 3), debits `AvailableQuantity` on each, and creates the `Reservation` (with its `WarehouseAllocation` children) — all inside one PostgreSQL transaction, never as separate commits. This is a deliberate exception to "one transaction per aggregate," justified the same way `kart-identity-service/ddd-model.md`'s `UserDataErased` handler justifies its own cross-aggregate write: the two aggregates' invariants (never-negative stock, all-or-nothing allocation) can only both hold if the debit and the hold-creation are atomic together — a lock held on `WarehouseStock` without a corresponding durably-committed `Reservation` would leave stock decremented with no hold recorded to release it later.

Release runs the same shape in reverse: locks the `WarehouseStock` row(s) referenced by the `Reservation`'s `WarehouseAllocation` children, credits each back, and transitions `Reservation.ReservationStatus` to `Released`/`Expired` — one transaction, one Outbox-inserted `InventoryReleased` row.

## Modeling Decisions & Assumptions (resolved here, not escalated — engineering defaults, revisable)

1. **`WarehouseAllocation` is a child entity of `Reservation`, not a standalone aggregate.** It has no lifecycle or identity independent of the `Reservation` it belongs to, and is never queried or mutated except as part of creating or releasing its parent — the same reasoning `kart-identity-service/ddd-model.md` uses for `FederatedIdentity` as a child of `UserIdentity`.
2. **No `Warehouse` aggregate.** Nothing in requirement-spec.md or edge-cases.md describes warehouse metadata (address, capacity, operating hours) as this service's own responsibility — `WarehouseId` is treated as an opaque, externally-assigned identifier `WarehouseStock` is keyed by, not a concept this bounded context models or owns. If warehouse master-data management is ever needed, that is new scope for a future requirement-spec revision, not an omission here.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner, see docs/adr and this run's decision log
- [x] Approved to proceed to API/Database/Event Design Agents
