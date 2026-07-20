---
doc_type: adr
status: accepted
---

# ADR-0005: Unify `OrderCompleted`/`OrderDelivered` Into One Event, Published by Order

## Status

Accepted

## Context

`kart-requirements.md` §5.4 named two different terminal-order events with no publisher anywhere in the BRD:

- Recommendation's row: consumes `OrderCompleted` (its purchase-signal training input).
- Review's row: consumes `OrderDelivered` (its verified-purchase gate).

Order's own Publishes list (§5.1, §10) only ever contained `OrderCreated`/`OrderConfirmed`/`OrderCancelled`/`OrderCompensationTriggered` — neither `OrderCompleted` nor `OrderDelivered` existed anywhere as a published event. `docs/services/README.md` tracked the `OrderCompleted` gap; the professional-grade review pass additionally surfaced the `OrderDelivered` gap for Review (same shape of problem, previously untracked). Both Recommendation's and Review's docs correctly flagged their respective gap as blocking; neither gap had an actual resolution.

## Decision

Treat both names as referring to the same underlying concept — the order reaching its terminal successful state — and unify them into a single new event, **`OrderDelivered`**, published by Order Service:

- Chosen name over `OrderCompleted` because it matches Order's own state-machine vocabulary exactly (`Created → Reserved → Paid → Shipped → Delivered → Cancelled/Refunded`, §5.1) — `Delivered` is already a named state; `Completed` is not.
- Order publishes `OrderDelivered` when its state machine transitions to `Delivered`, triggered by consuming Delivery Tracking's `DeliveryStatusUpdated` and detecting the terminal "delivered" status (Order already consumes `DeliveryStatusUpdated` for exactly this purpose — added to its Consumes list alongside this ADR).
- Recommendation's row is updated to consume `OrderDelivered` instead of `OrderCompleted` (the BRD's original name is treated as an inconsistent early label for the same concept, not a second, separate event).
- Review's row already said `OrderDelivered` — it was correct, just missing a publisher; this ADR supplies one.

## Consequences

- One event, one publisher, one place in the BRD (§10) to look — instead of two similarly-named phantom events with no source.
- Order Service gains a new responsibility: consuming Delivery Tracking's status stream to detect terminal delivery (a light coupling, but Order already models the full lifecycle including `Delivered`, so this keeps state-machine ownership in one place rather than pushing "did this order complete" logic into Recommendation or Review).
- `kart-order-service`'s `requirement-spec.md`/`edge-cases.md` need this event added to their scope (new consume of `DeliveryStatusUpdated`, new publish of `OrderDelivered`); `kart-recommendation-service`'s docs need `OrderCompleted` renamed to `OrderDelivered` throughout.
