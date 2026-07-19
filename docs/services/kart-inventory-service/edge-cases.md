---
doc_type: edge-cases
service: kart-inventory-service
status: pending-approval
generated_by: edge-case-analyzer-agent
source: docs/services/kart-inventory-service/requirement-spec.md
---

# Edge Cases: kart-inventory-service

## Edge Case: Oversell under concurrent reservation

- **What happens:** Two or more concurrent `POST /inventory/reserve` calls against the same SKU each see sufficient available stock and both succeed, driving stock negative / overselling the SKU.
- **Why it happens:** Read-then-write race on the same stock row with no serialization point between the availability check and the reservation write (requirement-spec Domain Invariant 1; BRD §2.2's "Inventory must never oversell" forcing function).
- **Solutions available (3):** Pessimistic row lock (`SELECT ... FOR UPDATE`) held for the transaction · Optimistic concurrency (version column, retry-on-conflict at commit) · Atomic conditional decrement (single `UPDATE ... SET qty = qty - N WHERE qty >= N` statement, no explicit lock)
- **Decision (4 bullets):**
  - Chosen: Pessimistic row-level locking (`SELECT ... FOR UPDATE`)
  - Why: requirement-spec §3/§6.1 already names this as the BRD's stated mechanism for Inventory stock rows
  - Trade-off accepted: Reduced concurrent throughput on hot SKUs (lock contention held for the transaction) vs. optimistic locking's higher throughput but retry-storm risk under heavy contention
  - Escalate: The BRD contradicts itself here (§2.2 says "optimistic locking," §6.1 prescribes pessimistic locking for the same rule — requirement-spec Open Question 1); this decision follows §6.1's concrete design table, but the wording conflict itself is unresolved and carried to the Architecture Agent

## Edge Case: Reservation left dangling by a failed/abandoned Saga step

- **What happens:** Order reserves stock (`InventoryReserved` published) but then crashes, times out, or never issues a subsequent release/compensation call — the reservation hold is never released and permanently locks stock away from other customers.
- **Why it happens:** Saga orchestration failure or partition between Order and Inventory after a successful reservation but before the next saga step or compensation trigger runs (requirement-spec §5.2 TTL requirement exists precisely because this can happen; exact TTL/expiry mechanics are unstated — Open Question 2).
- **Solutions available (3):** TTL-based auto-expiry sweep (background job releases holds past TTL) · Saga-side timeout watchdog in Order Service that force-triggers compensation after N seconds of silence · Manual/admin reconciliation tooling only, no automated expiry
- **Decision (4 bullets):**
  - Chosen: TTL-based auto-expiry sweep, owned entirely inside Inventory
  - Why: Reservation holds already carry a TTL per requirement-spec §5.2; keeping cleanup inside Inventory's own boundary matches its Boundary Rationale of being independently scalable/lockable without depending on Order staying healthy
  - Trade-off accepted: Gives up a saga-side watchdog as the sole safety net — if Order's own compensation call arrives after Inventory's TTL sweep already released the hold, release must be idempotent (see Compensating-transaction edge case below) rather than relying on a single authority to release exactly once
  - Escalate: Exact TTL duration and whether expiry publishes an event (and which one) is unresolved — requirement-spec Open Question 2

## Edge Case: Multi-warehouse split-stock allocation races

- **What happens:** An order line's requested quantity isn't available at any single warehouse but is available when summed across two or more warehouses; concurrent reservation attempts against the same SKU across warehouses can independently see "enough combined stock" and over-allocate the same units, or fail unnecessarily if warehouse rows are checked one at a time without coordination.
- **Why it happens:** Stock truth is scoped per warehouse (requirement-spec §5.2 Responsibility: "Stock levels, reservations, warehouses"), so a single stock-row lock no longer serializes an allocation spanning multiple rows across multiple warehouses — the BRD defines no cross-warehouse allocation strategy at all (requirement-spec Open Question 3).
- **Solutions available (3):** Lock all candidate warehouse rows for the SKU in one transaction, in a fixed deterministic order (e.g. warehouse-id ascending) to avoid deadlock, then allocate greedily · Single-warehouse-only reservation (reject/fail if no one warehouse fully satisfies the line; push any splitting decision up to Order/Cart) · Pre-aggregated cross-warehouse stock view with optimistic allocation plus a compensating re-check
- **Decision (3 bullets):**
  - Chosen: Unresolved — escalated
  - Why: Whether the platform supports split-shipment orders at all is a product/business call the BRD never states, not an engineering default (requirement-spec Open Question 3)
  - Trade-off accepted: N/A — no option chosen; this must be decided by a human before the Architecture/DDD Agents can shape the reservation aggregate boundary, since "one warehouse vs. many per reservation" changes the aggregate's identity

## Edge Case: Compensating-transaction rollback correctness if Payment fails after Inventory already reserved

- **What happens:** Order successfully reserves stock (`InventoryReserved`), Payment then fails, and Order triggers Inventory's compensating release — but the compensation call/event can be delivered more than once (at-least-once delivery), or arrive after the same reservation has already been auto-expired by its TTL.
- **Why it happens:** Saga compensation runs asynchronously and independently of the original reservation's lifecycle (BRD §12.2 Failure & Compensation Flow), and at-least-once delivery (BRD §3 Reliability NFR) plus TTL auto-expiry (see dangling-reservation edge case above) means two independent triggers can target the release of the same reservation.
- **Solutions available (3):** Idempotent release keyed on reservation ID (release is a no-op returning success if already released/expired) · Explicit reservation state machine with terminal states (`RESERVED → RELEASED`/`EXPIRED`) that rejects any transition out of a terminal state · Distributed lock/mutex around release per reservation ID to serialize concurrent release attempts
- **Decision (3 bullets):**
  - Chosen: Idempotent release keyed on reservation ID, backed by an explicit reservation state machine with terminal states
  - Why: Directly satisfies requirement-spec's release-idempotency domain invariant and resolves the double-release race against TTL expiry without new infrastructure
  - Trade-off accepted: Gives up the stronger single-point-of-truth guarantee a distributed lock would provide, in favor of a state-machine check inside the same PostgreSQL transaction — consistent with Inventory's PostgreSQL-as-source-of-truth NFR (requirement-spec §3)
