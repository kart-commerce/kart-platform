---
doc_type: event-contract
service: kart-inventory-service
status: approved
generated_by: event-design-agent
source: docs/services/kart-inventory-service/requirement-spec.md, docs/services/kart-inventory-service/edge-cases.md, docs/services/kart-inventory-service/design-decisions.md, docs/services/kart-inventory-service/architecture.md, docs/services/kart-inventory-service/ddd-model.md, docs/services/kart-inventory-service/database-design.md, docs/adr/0007-event-catalog-completeness.md, docs/adr/0009-order-inventory-sync-scope.md
---

# Event Contract: kart-inventory-service

Exchange: `ecommerce.events` (per [kart-conventions.md](../../standards/kart-conventions.md)). Every consumer queue below gets its own DLQ per the reusable event standard — never shared.

## Published Events

| Event | Routing Key | Consumed By | Key Fields | Retry | DLQ | Criticality Justification |
|---|---|---|---|---|---|---|
| `InventoryReserved` | `inventory.reservation.reserved` | Order | `orderId`, `sku`, `qty` | 2x | `inventory.reserved.dlq` | Standard tier — requirement-spec.md Decision 7: the synchronous `/inventory/reserve` call already fails fast for the caller independent of this event's fate; PostgreSQL's `reservations` row is the durable source of truth regardless of delivery. |
| `InventoryReservationFailed` | `inventory.reservation.failed` | Order, Cart | `orderId`, `sku` | 2x | `inventory.reservation-failed.dlq` | Same standard tier and reasoning as above. |
| `InventoryReleased` | `inventory.reservation.released` | Order, Analytics | `orderId`, `sku`, `qty` | 2x | `inventory.released.dlq` | Standard tier (requirement-spec.md Decision 7) — the TTL sweep (ddd-model.md) self-heals a lost release regardless of whether this event is ever delivered, an independent safety net Payment's equivalent events lack. |
| `InventoryReplenished` | `inventory.stock.replenished` | Analytics | `sku`, `qtyAdded`, `warehouseId` | 2x | `inventory.replenished.dlq` | Standard tier, same reasoning — Analytics' own copy is a reporting projection, not a correctness-critical one; `warehouse_stock`'s own row remains authoritative regardless of delivery. |

**DLQ naming deliberately diverges from BRD §10/ADR-0007's simplified shared `inventory.dlq` label** — that label was shared across all four of this service's own events, exactly the shared/global DLQ pattern `event-standards.md` forbids ("every consumer queue has its own DLQ — never a shared/global DLQ"). This is the identical correction `kart-offer-service`, `kart-admin-service`, `kart-cart-service`, and `kart-category-service`'s own event contracts already made for their own BRD-simplified shared DLQ labels. Retry *counts* (2x) are unchanged from BRD §10/ADR-0007 — only the per-event queue names are corrected.

## Consumed Events

| Event | Published By | Triggers | Retry Handling |
|---|---|---|---|
| `OrderCancelled` | Order | Reservation release for the order's `orderId` (requirement-spec.md §2) | Idempotent by construction — releasing an already-terminal reservation is a no-op (ddd-model.md's `ReservationStatus` terminal-state machine); no separate dedup table needed |
| `OrderCompensationTriggered` | Order | Reservation release as the Order Saga's compensating action (BRD §12.2; ADR-0007 added this event's Event Catalog row: 3x retry, `order.dlq`, on Order's publishing side) | Same idempotent release path as `OrderCancelled` above — both, plus the explicit `POST /inventory/release` call and the internal TTL sweep, converge on one state-checked write (design-decisions.md, "Release Idempotency & State Machine Design") |

Retry/DLQ tiers for these two consumed events are set on Order's own publishing side (ADR-0007); this service's consumer-side handling only needs to be idempotent, which the `Reservation` state machine already guarantees regardless of redelivery count.

## Naming-Convention Compliance

All four published events follow the `<Entity><PastTenseVerb>` convention (`event-standards.md`): `InventoryReserved`, `InventoryReservationFailed`, `InventoryReleased`, `InventoryReplenished` — all `Inventory`/`InventoryReservation` entity + a past-tense verb. Routing keys follow the `service.entity.action` convention (`kart-conventions.md`). No collision found against any event name already registered in this repo's other `event-contract.md` files.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner
- [x] Approved
