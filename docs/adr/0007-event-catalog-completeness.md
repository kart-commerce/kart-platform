---
doc_type: adr
status: accepted
---

# ADR-0007: Event Catalog Completeness Pass

## Status

Accepted

## Context

Several events were named as a service's own published event in `kart-requirements.md` §5.1–§5.4 but had no row at all in §10's Event Catalog — meaning no documented consumer, retry policy, or DLQ strategy. `docs/services/README.md` tracked five of these (`CartCheckedOut`, `WishlistPriceAlertTriggered`, `AdminActionPerformed`, `OrderCompensationTriggered`, `UserRegistered`/`SessionCreated`); the professional-grade review pass found three more by cross-checking each service's own Publishes row against §10: `InventoryReleased` (named in §12.2's compensation diagram, missing from both §5.2's Publishes row and §10), `InventoryReplenished` (named in §5.2's Publishes row, missing from §10), and `RefundIssued` (named in §5.3's Publishes row, missing from §10).

Unlike ADR-0002 through ADR-0006, none of these are genuine ambiguities requiring a judgment call between two readings — they're pure documentation gaps. This ADR exists to record the retry/DLQ tier assigned to each, following the tiering pattern §10's own footnote already establishes (money-moving > standard business event > fire-and-forget audit).

## Decision

Add all eight events to §10's Event Catalog:

| Event | Consumer(s) assigned | Retry tier | Rationale |
|---|---|---|---|
| `OrderCompensationTriggered` | Inventory, Notification, Analytics | 3x, `order.dlq` | Same tier as its sibling Order lifecycle events |
| `InventoryReleased` | Order, Analytics | 2x, `inventory.dlq` | Same tier as its sibling `InventoryReserved`/`InventoryReservationFailed` |
| `InventoryReplenished` | Analytics | 2x, `inventory.dlq` | Same tier as its sibling Inventory events; no other service acts on this synchronously |
| `RefundIssued` | Order, Notification, Analytics | 5x, `payment.dlq`, paged on-call | Money-moving — same tier as `PaymentCompleted`/`PaymentFailed` per §10's own stated rule |
| `CartCheckedOut` | Analytics | 2x, `cart.dlq` | Funnel/conversion tracking is Analytics' named responsibility (§2.1); no other confirmed synchronous consumer — Order's own trigger is the client's `POST /orders` call, not this event |
| `WishlistPriceAlertTriggered` | Notification, Analytics | 2x, `wishlist.dlq` | The event's own name states its purpose (alert the user) |
| `AdminActionPerformed` | Analytics | 1x, `admin.dlq` | Audit-only, same fire-and-forget tier as `NotificationSent` |
| `UserRegistered` | User, Notification, Analytics | 3x, `identity.dlq` | Account-creation event; Notification added for the welcome-email use case |
| `SessionCreated` | Analytics | 2x, `identity.dlq` | Login/session tracking only; no other service needs this synchronously |

## Consequences

- Every event named anywhere in the BRD now has exactly one authoritative row in §10 — no more "named in a service table but untraceable in the catalog" gap.
- `CartCheckedOut`'s consumer assignment (Analytics only) is a real decision, not just documentation: it means Order does **not** treat this as its creation trigger (the synchronous `POST /orders` API call is), which should be double-checked against `kart-cart-service`'s and `kart-order-service`'s eventual architecture-agent output in case a different integration style is chosen there.
- If any of these tier assignments turn out wrong once a service's actual failure modes are load-tested, that's a normal event-design-agent revision, not a re-opening of this ADR's premise (that these events needed *some* documented tier).
