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
- **CanRead/CanWrite/CanDelete ownership (BRD §24.1.2 — service-owned, decided here rather than left implicit now that it is a named platform requirement).** A `WarehouseStock` row has no per-user ownership dimension — it is warehouse/SKU-keyed operational data, not a resource any individual Customer owns. **Mechanism chosen: unconditional `CanRead`** (`GET /inventory/{sku}` — any principal, including unauthenticated storefront "in stock" checks), **coarse-role/service-principal-gated `CanWrite`** — the replenishment write path (Decision 5) accepts either Admin's own operator identity (manual replenishment) or the internal threshold-trigger process, an inline check with no persisted grant table (there is no further per-warehouse or per-SKU distinction to make beyond "is this an authorized replenishment source"). `CanDelete` is never exposed — a `WarehouseStock` row is never removed, only debited/credited.
- **Audit-actor invariant (BRD §24.3).** Every mutation to `warehouse_stock` (database-design.md) stamps `created_by`/`updated_by` with the resolved acting principal — Order Service's client identity for a reservation debit, the same for a release credit, or Admin's operator identity / `system:inventory-replenishment-trigger` for a replenishment credit (requirement-spec.md Decision 5). Auto-injected by the shared `kart-shared` `Kart.Shared.Auditing` package's `SaveChanges` interceptor (§24.3 — one platform-wide implementation referenced as a NuGet dependency, not built locally by this service; see database-design.md), never populated from a request-handler-supplied value, and never `NULL`.

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
- **CanRead/CanWrite/CanDelete ownership (BRD §24.1.2).** A `Reservation` correlates to an `orderId`, not a `userId` — the same shape the BRD's own §24.1.4 worked example gives for Payment's `payment_intents` ("never stores `user_id` directly... keys only on the opaque `order_id`"), so an ownership-comparison mechanism (§24.1.2's Cart/Wishlist/User bucket) does not apply here. **Mechanism chosen: inline service-principal check** — `CanWrite` on `POST /inventory/reserve`/`POST /inventory/release` is granted only to Order Service's own client-credentials principal, since these are synchronous service-to-service calls (requirement-spec.md §2/§5), never a direct end-customer or Admin write; the async release triggers (`OrderCancelled`/`OrderCompensationTriggered` consumption, the TTL sweep) are internal processes with no external caller to gate at all. `CanRead` on an individual `Reservation`'s status has no dedicated end-user-facing endpoint today (`api-contract.yaml`) — not a gap this invariant needs to close, since `GET /inventory/{sku}` only ever exposes aggregate `WarehouseStock` availability, never a `Reservation` row itself. `CanDelete` is never exposed — release is a state transition (`Reserved → Released/Expired`), never a hard delete.
- **Audit-actor invariant (BRD §24.3).** Every mutation to `reservations`/`reservation_allocations` (database-design.md) stamps `created_by`/`updated_by` with the resolved acting principal — Order Service's client identity for the creating reserve call and for an explicit release call, or a well-known `system:*` id (e.g. `system:inventory-ttl-sweep`, `system:inventory-order-cancelled-consumer`, `system:inventory-compensation-consumer`) for the TTL sweep and the two async release-trigger consumers — never a client-suppliable value, never `NULL`, auto-injected by the same shared `kart-shared` interceptor as `WarehouseStock`.

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
