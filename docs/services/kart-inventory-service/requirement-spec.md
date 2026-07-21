---
doc_type: requirement-spec
service: kart-inventory-service
status: approved
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
- Consume `OrderCancelled` and release the associated reservation (§5.2: "Consumes: `OrderCancelled` (release)"; confirmed in Event Catalog §10, where `OrderCancelled`'s consumers are "Inventory, Coupon, Notification, Analytics").
- Consume `OrderCompensationTriggered` and release the associated reservation as the Order Saga's compensating action when a later saga step (Payment) fails (§5.2; §12.2 Failure & Compensation Flow: `Order->>Inventory: Release reservation (compensation)`). `OrderCompensationTriggered` previously had no Event Catalog entry at all despite being named as consumed here and published by Order (§5.1) — **now resolved by ADR-0007** (Event Catalog Completeness Pass): §10 gives it a full row (publisher Order; consumers Inventory, Notification, Analytics; payload `orderId, reason`; 3x retry; `order.dlq`). See the former Open Question #5, now resolved, in §6 below.
- **On releasing a reservation — via the explicit API call, `OrderCancelled`, or `OrderCompensationTriggered` — publish `InventoryReleased` (orderId, sku, qty)**, the compensating counterpart to `InventoryReserved`, closing the loop back to Order so the Saga knows the compensating release actually completed before marking `OrderCancelled` (§12.2's diagram: `Order->>Inventory: Release reservation (compensation)` immediately followed by `Inventory-->>Order: InventoryReleased`, then `Order->>Order: Mark OrderCancelled`). This event is now stated directly in §5.2's own Publishes row and given a full Event Catalog entry at §10 (consumers Order, Analytics; payload `orderId, sku, qty`; 2x retry; `inventory.dlq`), both added per **ADR-0007**. The prior draft of this spec described the release *action* in full (API endpoint, `OrderCancelled`/`OrderCompensationTriggered` consumption) but never once stated that Inventory publishes an event when it happens — a gap this redraft closes.
- Release must be idempotent: a redelivered release call/event under at-least-once delivery (§3 Reliability NFR, platform-wide) must not double-credit the same hold back into available stock, and correspondingly must not re-publish a duplicate `InventoryReleased` for a hold already released. This is inferred from the platform-wide idempotency NFR, not stated specifically for Inventory release — flagged as a Domain Invariant below rather than assumed silently.

### Replenishment

- Publish `InventoryReplenished` when warehouse stock is restocked (§5.2). The prior draft of this spec flagged a double gap here: no listed consumer/payload/retry policy in the Event Catalog, and no stated trigger. **The Event Catalog portion is now resolved by ADR-0007**: §10 gives `InventoryReplenished` a full row (publisher Inventory; consumer Analytics; payload `sku, qtyAdded, warehouseId`; 2x retry; `inventory.dlq`). **What remains unresolved — verified directly against the current BRD text, not carried forward by assumption** — is the trigger: neither §5.2 nor §10 (nor any other section) states whether replenishment is a manual admin action, an automated upstream supplier/warehouse feed, or something else. See Open Questions (renumbered #5).

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
| Reliability | At-least-once delivery + idempotent consumers (platform-wide, §3) | §3's explicit "no data loss" guarantee names only Order/Payment events — it does not name Inventory's events, despite `InventoryReserved`/`InventoryReservationFailed`/`InventoryReleased` being equally load-bearing for saga correctness (the latter now confirmed as a real, cataloged event per ADR-0007, not just a spec gap). Gap — see Open Questions |
| Retry/DLQ | `InventoryReserved`, `InventoryReservationFailed`, `InventoryReleased`: 2x retry → `inventory.dlq` (§10; `InventoryReleased`'s row added per **ADR-0007**). `InventoryReplenished`: 2x retry → `inventory.dlq` (§10, also added per ADR-0007) | None of these are in the `Payment*` 5x-retry/paged tier, despite the reservation/release pair being the mechanism that prevents the Saga from stalling or overselling — see Open Questions |

## 4. Domain Invariants

- Stock must never go negative / be oversold under concurrent reservation attempts for the same SKU (§2.2) — the platform's canonical example of a domain rule forcing a hard concurrency-control decision, and the direct justification for this service's isolated boundary (§5.2).
- A reservation hold is time-bounded (TTL) and must not persist indefinitely once created (§5.2) — the BRD states the TTL exists but not its value or expiry mechanics (Open Questions).
- Reservation release — whether triggered by explicit `POST /inventory/release`, `OrderCancelled`, or `OrderCompensationTriggered` — must be idempotent, so that at-least-once delivery cannot double-release the same hold back into available stock, nor cause a duplicate `InventoryReleased` to be published for a hold already released (inferred from the platform-wide idempotency NFR at §3; the BRD does not state this specifically for Inventory release or for `InventoryReleased`, which itself was entirely absent from this spec prior to this redraft — see §2 and §6).
- `InventoryReserved` must only be published once the stock-row lock and reservation write are durably committed, never before, so Order cannot advance the saga on a reservation that could still fail to persist (inferred from the oversell invariant plus the Outbox pattern at §11; not stated explicitly in the BRD for this event).
- `InventoryReleased` must only be published once the compensating release (crediting the hold's quantity back to available stock) is durably committed, mirroring `InventoryReserved`'s atomicity requirement above — so Order cannot mark `OrderCancelled` on a compensating release that could still fail to persist (inferred from the same Outbox-pattern reasoning at §11; not stated explicitly in the BRD for this event, which was previously missing from this spec entirely — see §2 above and ADR-0007).
- Replenished quantity must be reflected in stock truth before it can be reserved by a new request (inferred from the "Stock truth per warehouse" responsibility at §5.2; the BRD does not state replenishment's transactional relationship to concurrent reservations).

## 5. API Surface (from BRD, starting point only)

| Endpoint/Event | Direction | Notes |
|---|---|---|
| `POST /inventory/reserve` | Inbound API (sync) | BRD §5.2; called synchronously by Order (§5.1) as saga step 1 (§12.1) |
| `POST /inventory/release` | Inbound API (sync) | BRD §5.2; called by Order as the compensating action on saga failure (§12.2) |
| `GET /inventory/{sku}` | Inbound API (read) | BRD §5.2 |
| `InventoryReserved` | Published | Consumed by Order (BRD §10) |
| `InventoryReservationFailed` | Published | Consumed by Order, Cart (BRD §10) |
| `InventoryReleased` | Published | Compensating counterpart to `InventoryReserved` — published on release of a held reservation, whether via `POST /inventory/release`, `OrderCancelled`, or `OrderCompensationTriggered` (§5.2; §12.2's Saga diagram: `Inventory-->>Order: InventoryReleased`). Consumed by Order, Analytics; payload `orderId, sku, qty`; 2x retry; `inventory.dlq` (BRD §10). Previously entirely absent from this spec despite being named in §12.2's diagram — resolved per **ADR-0007** (Event Catalog Completeness Pass), which also added the missing entry to §5.2's own Publishes row and to §10. |
| `InventoryReplenished` | Published | Consumed by Analytics; payload `sku, qtyAdded, warehouseId`; 2x retry; `inventory.dlq` (BRD §10, added per **ADR-0007**). The BRD still states no trigger for replenishment (manual admin action vs. automated feed) — see Open Questions. |
| `OrderCancelled` | Consumed | Published by Order (BRD §10); triggers reservation release (§5.2) |
| `OrderCompensationTriggered` | Consumed | Published by Order (§5.1's publish list) as the saga compensation trigger (§12.2); consumed by Inventory (release), Notification, Analytics; payload `orderId, reason`; 3x retry; `order.dlq` (BRD §10, added per **ADR-0007**). Previously had no Event Catalog entry in §10 at all — resolved. |

Final contract is the API Design Agent's job, not this spec's.

## 6. Open Questions / Flagged Ambiguities

**Resolved since the prior draft.** Three gaps this spec previously carried as open (or, in one case, never named as a publish obligation at all) are now closed by **ADR-0007** (Event Catalog Completeness Pass):

- *`OrderCompensationTriggered` had no Event Catalog entry* (prior #5) — §5.2 already listed it as consumed by Inventory and §5.1 listed it as published by Order, but §10 omitted it entirely: no payload shape, retry count, or DLQ policy for the one event that must reliably fire to release reserved stock when Payment fails. **ADR-0007** added a full row: publisher Order; consumers Inventory, Notification, Analytics; payload `orderId, reason`; 3x retry; `order.dlq`. See §2's Release/Compensation FRs and §5's API Surface table.
- *`InventoryReplenished` had no Event Catalog entry* (prior #6) — listed as published (§5.2) but absent from §10 entirely. **ADR-0007** added a full row: publisher Inventory; consumer Analytics; payload `sku, qtyAdded, warehouseId`; 2x retry; `inventory.dlq`. This resolves only the Event Catalog half of prior #6 — **the BRD still never states what triggers replenishment** (manual admin action vs. an automated supplier/warehouse feed), verified directly against §5.2 and §10, neither of which addresses it. That surviving substance carries forward below as #5, not dropped.
- *`InventoryReleased` was missing entirely, and not just from the Event Catalog.* The prior draft's "Release / Compensation" FRs described the release *action* (API endpoint, `OrderCancelled`/`OrderCompensationTriggered` consumption) in full, but never once stated that Inventory **publishes an event** when a release happens — despite `InventoryReleased` being named directly in §12.2's Saga diagram (`Inventory-->>Order: InventoryReleased`). This was a real gap in this spec, not just a BRD gap: the BRD's own §5.2 Publishes row and §10 Event Catalog were also missing it until **ADR-0007** added it to both (consumers Order, Analytics; payload `orderId, sku, qty`; 2x retry; `inventory.dlq`). It is now a stated FR (§2), Domain Invariant (§4), and API Surface entry (§5) — there is nothing ambiguous left about it once ADR-0007 is applied, so it is not carried forward as an open question.

Remaining genuinely open items, renumbered (former #5 fully resolved and removed; former #6's Event Catalog half resolved and removed, its trigger question surviving below as #5):

1. **Locking strategy contradiction.** §2.2 frames the oversell rule as forcing "optimistic locking / reservation patterns," while §6.1's concrete database design table prescribes pessimistic row-level locking (`SELECT ... FOR UPDATE`) for that same purpose. These are materially different concurrency-control strategies (optimistic: version-check at commit time, no held lock, retry on conflict; pessimistic: a held lock blocks concurrent access for the transaction's duration) with different throughput/contention trade-offs — a decision that matters most precisely because this is called the platform's highest-contention service. The BRD does not reconcile which reading is authoritative. Carried to the Architecture/DDD Agent stage.

2. **Reservation TTL — duration and expiry behavior unspecified.** §5.2 states reservation holds carry a TTL but never gives a value, and no BRD section states what happens on expiry: does an unreleased-but-expired reservation auto-return stock to the pool? Does expiry publish an event (reusing `InventoryReservationFailed`, or something distinct — possibly `InventoryReleased` itself)? What component runs the expiry sweep? Blocking for the DDD/Architecture Agents' reservation aggregate design.

3. **Multi-warehouse allocation strategy — unspecified.** The Responsibility is explicitly "Stock levels, reservations, **warehouses**" (§2.1) and stock is tracked per warehouse (§5.2), but the BRD never states how a reservation should behave when a single order line's requested quantity isn't fully available at one warehouse: split allocation across warehouses (partial shipment), fail closed and let Order retry/reject, or prefer-nearest-then-fallback. No BRD text addresses this at all.

4. **Backorder handling — not addressed.** §2.2 states only "must never oversell." The BRD never says whether insufficient stock always yields a hard `InventoryReservationFailed`, or whether a backorder/waitlist path exists for temporarily out-of-stock SKUs.

5. **`InventoryReplenished`'s trigger is still unstated.** ADR-0007 resolved the Event Catalog gap (consumer, payload, retry/DLQ — see "Resolved since the prior draft" above), but no BRD section — §5.2's Responsibility/Publishes row, §10's Event Catalog, or anywhere else — states what actually triggers a replenishment: a manual admin action, an automated upstream supplier/warehouse feed, or something else. This is narrower than the prior draft's framing (which conflated it with the now-resolved catalog gap), but it is still genuinely open and still blocks the DDD Agent from modeling how a replenishment event gets created in the first place.

6. **"No data loss" reliability guarantee doesn't name Inventory's events.** §3's Reliability row states "No data loss on Order/Payment events" by name — it does not extend that explicit guarantee to `InventoryReserved`, `InventoryReservationFailed`, or `InventoryReleased`, even though losing any of the three silently could strand the Saga mid-flight (unreleased stock, or a compensating release Order never learns happened) or misstate stock. Likely an oversight given Inventory's stated criticality, but the BRD does not say so explicitly.

7. **Retry/DLQ tier for Inventory events.** `InventoryReserved`, `InventoryReservationFailed`, `InventoryReleased`, and `InventoryReplenished` all get the standard 2x-retry/DLQ tier (§10), not the `Payment*` 5x-retry/paged tier — despite Inventory correctness being listed alongside Payment correctness in the same "domain rules that force hard decisions" list (§2.2). Carried to the Event Design Agent stage to confirm this is intentional and not an oversight.

8. **Availability tier not explicitly named for Inventory.** §3 defines only two named tiers ("order path" 99.99%, "secondary" 99.9%) without listing which services fall in which tier. This spec infers 99.99% given Inventory's synchronous position in the Order Saga (§5.1, §12.1) — carried forward for human confirmation, not treated as a blocker.

## Sign-off

- [ ] Blocking open questions resolved
- [ ] Reviewed by: _______________
- [ ] Approved to proceed to Architecture Agent
