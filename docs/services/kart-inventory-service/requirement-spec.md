---
doc_type: requirement-spec
service: kart-inventory-service
status: pending-approval
generated_by: requirement-agent
source: docs/requirements/kart-requirements.md
---

# Requirement Spec: kart-inventory-service

## 1. Scope

Covers a single BRD service: **Inventory** (BRD §2.1 item 6: "Stock levels, reservations, warehouses"). No merge, no ADR needed — unlike `kart-offer-service`, this is a 1:1 mapping from BRD to service.

This is one of the BRD's three deep-dive services (§5.2, alongside Order §5.1 and Payment §5.3), not a condensed row (§5.4), so the BRD gives it real structural detail: a dedicated Responsibility/API/Database/Events/Boundary-Rationale table, an explicit concurrency-control mechanism (§6.1), a role as a mandatory participant in the Order Saga's both success and compensation flows (§12), and its own line in the domain-forcing-functions list (§2.2). This spec reflects that depth rather than condensing it.

`docs/PLATFORM_BLUEPRINT.md` independently flags `kart-inventory-service` as a **missing Phase 1 repo** and calls Inventory "the highest-contention service in the whole system," directly citing §5.2's `SELECT ... FOR UPDATE` oversell prevention and Order's Saga dependency on it as the reason it cannot be folded into Order or Payment. That framing (not itself a BRD requirement) is included here only as scope justification, not as a source of functional requirements.

## 2. Functional Requirements

### Stock & Reservation

- Maintain stock truth per warehouse, per SKU (§5.2 Responsibility; §2.1 item 6).
- Reserve stock synchronously when Order Service calls `POST /inventory/reserve` as the first step of the Order Saga (§12.1 Success Flow: `Order->>Inventory: Reserve stock`; §5.1 Dependencies: "Inventory Service (sync reserve call + async confirm)" — i.e. the call is synchronous, but saga advancement is confirmed via the async `InventoryReserved`/`InventoryReservationFailed` events).
- Reservation holds must carry a TTL (§5.2: "reservation holds with TTL") — duration and expiry behavior are not stated in the BRD (see Open Questions).
- On successful reservation, publish `InventoryReserved` (orderId, sku, qty), consumed by Order to advance the saga (§10).
- On failed reservation (insufficient stock), publish `InventoryReservationFailed` (orderId, sku), consumed by both Order (to trigger saga compensation) and Cart (§10) — Cart's consumption implies cart-level customer feedback (e.g. item no longer available), though the BRD does not specify Cart's exact reaction.
- Never oversell: stock must not go negative under concurrent reservation attempts against the same SKU — called out explicitly as a platform-level forcing function (§2.2), and as the reason this service exists as an isolated boundary (§5.2 Boundary Rationale: "so oversell logic ... can be scaled, locked, and load-tested independently").
- Enforce the oversell invariant via row-level `SELECT ... FOR UPDATE` locking on stock rows in PostgreSQL (§6.1) — see Open Questions for tension with §2.2's "optimistic locking" phrasing for the same rule.

### Release / Compensation

- Release a held reservation via `POST /inventory/release` (§5.2 API).
- Consume `OrderCancelled` and release the associated reservation (§5.2: "Consumes: `OrderCancelled` (release)"; confirmed in Event Catalog §10, where `OrderCancelled`'s consumers are "Inventory, Coupon").
- Consume `OrderCompensationTriggered` and release the associated reservation as the Order Saga's compensating action when a later saga step (Payment) fails (§5.2; §12.2 Failure & Compensation Flow: `Order->>Inventory: Release reservation (compensation)`).
- Release must be idempotent: a redelivered release call/event under at-least-once delivery (§3 Reliability NFR, platform-wide) must not double-credit the same hold back into available stock. This is inferred from the platform-wide idempotency NFR, not stated specifically for Inventory release — flagged as a Domain Invariant below rather than assumed silently.

### Replenishment

- Publish `InventoryReplenished` when warehouse stock is restocked (§5.2). The BRD gives no further detail: no listed consumer, no payload shape, and no stated trigger (manual admin action vs. an upstream supplier/warehouse feed) — see Open Questions.

### Read

- Serve current stock level for a SKU via `GET /inventory/{sku}` (§5.2).

## 3. Non-Functional Requirements

Pulled from the BRD's global NFR table (§3) and the platform-wide capacity/database sections (§4, §6.1), scoped to this service:

| Attribute | Target | Applies here because |
|---|---|---|
| Availability | 99.99% (order-path tier) — **inferred**, not named explicitly | Inventory sits synchronously on the Order Saga's critical path (§5.1: "sync reserve call"; §12.1's first saga step is `Reserve stock`) — unlike Offer, which the BRD explicitly places on a secondary path (§5.5). §3 names only "order path" vs. "secondary" tiers without listing services, so this is a reasoned inference, not a literal BRD statement — carried to Open Questions for confirmation |
| Consistency | Strong (PostgreSQL write path) | §6.1 explicitly classifies Order, Payment, and Inventory together as "Write-heavy... Correctness > raw read speed → PostgreSQL is source of truth" |
| Concurrency control | Row-level pessimistic locking (`SELECT ... FOR UPDATE`) on stock rows | §6.1 names this explicitly: "Prevents oversell under concurrent reservation" — see Open Questions for the tension with §2.2's "optimistic locking" phrasing describing the same rule |
| Throughput | 100K RPS sustained, 1M RPS burst (flash sale) | §4 capacity assumptions are platform-wide, but this ceiling is most binding here — Inventory is independently called out (PLATFORM_BLUEPRINT.md) as the platform's highest-contention service |
| Latency | Read: P95 < 150ms, P99 < 400ms (`GET /inventory/{sku}`). Write: P95 < 300ms, includes Outbox insert (`/inventory/reserve`, `/inventory/release`) | §3 global read/write latency budgets |
| Reliability | At-least-once delivery + idempotent consumers (platform-wide, §3) | §3's explicit "no data loss" guarantee names only Order/Payment events — it does not name Inventory's events, despite `InventoryReserved`/`InventoryReservationFailed` being equally load-bearing for saga correctness. Gap — see Open Questions |
| Retry/DLQ | `InventoryReserved`: 2x retry → `inventory.dlq`. `InventoryReservationFailed`: 2x retry → `inventory.dlq` (§10) | Neither is in the `Payment*` 5x-retry/paged tier, despite reservation events being the mechanism that prevents the Saga from stalling or overselling — see Open Questions |

## 4. Domain Invariants

- Stock must never go negative / be oversold under concurrent reservation attempts for the same SKU (§2.2) — the platform's canonical example of a domain rule forcing a hard concurrency-control decision, and the direct justification for this service's isolated boundary (§5.2).
- A reservation hold is time-bounded (TTL) and must not persist indefinitely once created (§5.2) — the BRD states the TTL exists but not its value or expiry mechanics (Open Questions).
- Reservation release — whether triggered by explicit `POST /inventory/release`, `OrderCancelled`, or `OrderCompensationTriggered` — must be idempotent, so that at-least-once delivery cannot double-release the same hold back into available stock (inferred from the platform-wide idempotency NFR at §3; the BRD does not state this specifically for Inventory release).
- `InventoryReserved` must only be published once the stock-row lock and reservation write are durably committed, never before, so Order cannot advance the saga on a reservation that could still fail to persist (inferred from the oversell invariant plus the Outbox pattern at §11; not stated explicitly in the BRD for this event).
- Replenished quantity must be reflected in stock truth before it can be reserved by a new request (inferred from the "Stock truth per warehouse" responsibility at §5.2; the BRD does not state replenishment's transactional relationship to concurrent reservations).

## 5. API Surface (from BRD, starting point only)

| Endpoint/Event | Direction | Notes |
|---|---|---|
| `POST /inventory/reserve` | Inbound API (sync) | BRD §5.2; called synchronously by Order (§5.1) as saga step 1 (§12.1) |
| `POST /inventory/release` | Inbound API (sync) | BRD §5.2; called by Order as the compensating action on saga failure (§12.2) |
| `GET /inventory/{sku}` | Inbound API (read) | BRD §5.2 |
| `InventoryReserved` | Published | Consumed by Order (BRD §10) |
| `InventoryReservationFailed` | Published | Consumed by Order, Cart (BRD §10) |
| `InventoryReplenished` | Published | No consumer, payload, or retry/DLQ policy listed anywhere in BRD §10 — see Open Questions |
| `OrderCancelled` | Consumed | Published by Order (BRD §10); triggers reservation release (§5.2) |
| `OrderCompensationTriggered` | Consumed | Published by Order (§5.1's publish list) as the saga compensation trigger (§12.2); has **no Event Catalog entry** in §10 at all — see Open Questions |

Final contract is the API Design Agent's job, not this spec's.

## 6. Open Questions / Flagged Ambiguities

Nothing below is resolved here — per the Requirement Agent's charter, contradictions and gaps are named for both readings, not picked for the BRD. All carry forward to later pipeline stages.

1. **Locking strategy contradiction.** §2.2 frames the oversell rule as forcing "optimistic locking / reservation patterns," while §6.1's concrete database design table prescribes pessimistic row-level locking (`SELECT ... FOR UPDATE`) for that same purpose. These are materially different concurrency-control strategies (optimistic: version-check at commit time, no held lock, retry on conflict; pessimistic: a held lock blocks concurrent access for the transaction's duration) with different throughput/contention trade-offs — a decision that matters most precisely because this is called the platform's highest-contention service. The BRD does not reconcile which reading is authoritative. Carried to the Architecture/DDD Agent stage.

2. **Reservation TTL — duration and expiry behavior unspecified.** §5.2 states reservation holds carry a TTL but never gives a value, and no BRD section states what happens on expiry: does an unreleased-but-expired reservation auto-return stock to the pool? Does expiry publish an event (reusing `InventoryReservationFailed`, or something distinct)? What component runs the expiry sweep? Blocking for the DDD/Architecture Agents' reservation aggregate design.

3. **Multi-warehouse allocation strategy — unspecified.** The Responsibility is explicitly "Stock levels, reservations, **warehouses**" (§2.1) and stock is tracked per warehouse (§5.2), but the BRD never states how a reservation should behave when a single order line's requested quantity isn't fully available at one warehouse: split allocation across warehouses (partial shipment), fail closed and let Order retry/reject, or prefer-nearest-then-fallback. No BRD text addresses this at all.

4. **Backorder handling — not addressed.** §2.2 states only "must never oversell." The BRD never says whether insufficient stock always yields a hard `InventoryReservationFailed`, or whether a backorder/waitlist path exists for temporarily out-of-stock SKUs.

5. **`OrderCompensationTriggered` has no Event Catalog entry.** §5.2 lists it as consumed by Inventory (release trigger) and §5.1 lists it as published by Order, but the Event Catalog (§10) — the section that defines payload/retry/DLQ for every other event in the platform — omits it entirely. No payload shape, retry count, or DLQ policy is defined for the one event that must reliably fire to release reserved stock when Payment fails.

6. **`InventoryReplenished` has no Event Catalog entry.** Same gap as #5: listed as published (§5.2) but absent from §10 entirely — no consumer, payload, or retry/DLQ policy, and no BRD text states what triggers replenishment (manual admin action vs. an automated supplier/warehouse feed).

7. **"No data loss" reliability guarantee doesn't name Inventory's events.** §3's Reliability row states "No data loss on Order/Payment events" by name — it does not extend that explicit guarantee to `InventoryReserved`/`InventoryReservationFailed`, even though losing one silently could strand the Saga mid-flight or misstate stock. Likely an oversight given Inventory's stated criticality, but the BRD does not say so explicitly.

8. **Retry/DLQ tier for Inventory events.** `InventoryReserved`/`InventoryReservationFailed` get the standard 2x-retry/DLQ tier (§10), not the `Payment*` 5x-retry/paged tier — despite Inventory correctness being listed alongside Payment correctness in the same "domain rules that force hard decisions" list (§2.2). Carried to the Event Design Agent stage to confirm this is intentional and not an oversight.

9. **Availability tier not explicitly named for Inventory.** §3 defines only two named tiers ("order path" 99.99%, "secondary" 99.9%) without listing which services fall in which tier. This spec infers 99.99% given Inventory's synchronous position in the Order Saga (§5.1, §12.1) — carried forward for human confirmation, not treated as a blocker.

## Sign-off

- [ ] Blocking open questions resolved
- [ ] Reviewed by: _______________
- [ ] Approved to proceed to Architecture Agent
