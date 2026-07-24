---
doc_type: adr
status: accepted
---

# ADR-0021: Review's `VerifiedPurchaseRecord` Additionally Consumes `OrderCreated`

## Status

Accepted

## Context

`kart-review-service`'s approved `architecture.md` and `design-decisions.md` both describe the verified-purchase eligibility gate's local projection (`VerifiedPurchaseRecord`) as keyed on `(customerId, orderId, sku)`, populated "by consuming `OrderDelivered`."

`ddd-agent`'s pass over this service's `ddd-model.md`, cross-checked directly against `kart-order-service/event-contract.md`'s own approved Published table (not assumed), found that `OrderDelivered`'s actual payload is `orderId, deliveredAt` only — it carries neither `userId` nor `sku`. `POST /reviews`'s hard eligibility gate needs all three fields to reject or admit a submission, so `OrderDelivered` alone cannot populate the projection as originally described.

This is the identical shape of gap ADR-0020 already found and closed for `kart-notification-service` (a consumer needs a field a triggering event doesn't carry, resolved by denormalizing the missing field from an *earlier* event in the same producer's stream that already carries it, rather than reopening the producer's own already-approved payload).

Two options were considered:

1. **Add `userId`/`sku` to `OrderDelivered`'s payload.** Rejected — this would reopen an already-approved, signed-off `kart-order-service/event-contract.md` for a field Order's own domain doesn't need to publish at delivery time, and would ripple to every other existing consumer of that event.
2. **`kart-review-service` additionally consumes `OrderCreated`** (which already carries `orderId, userId, items` per `kart-order-service/event-contract.md`, with `items` supplying the SKU set per `kart-order-service/ddd-model.md`'s `OrderLineItem`), denormalizing `userId`/`skus` from it into `VerifiedPurchaseRecord`, and continuing to source only `deliveredAt` from `OrderDelivered`. Chosen — the same "each service denormalizes what it needs to make its own decisions" pattern ADR-0020 already established.

## Decision

`kart-review-service` maintains `VerifiedPurchaseRecord`, a non-aggregate lookup projection keyed on `orderId`, populated from two consumed events:

- `OrderCreated` upserts `userId` and `skus: Set<Sku>` (derived from `items`).
- `OrderDelivered` upserts `deliveredAt`.

`POST /reviews`'s eligibility gate looks up by the client-supplied `orderId` and rejects unless a record exists with a non-null `deliveredAt`, a `userId` matching the authenticated caller, and the submitted `sku` present in `skus`.

**Ordering-race handling (no new mechanism invented):** RabbitMQ gives no cross-routing-key ordering guarantee, so `OrderDelivered` can in principle be consumed before the `OrderCreated` that seeds the same record's `userId`/`skus`. This is not a failure case: both upserts target the same key/row and commute regardless of arrival order — an `OrderDelivered` arriving first simply upserts `deliveredAt` onto a partial row, and the gate check above naturally continues to reject until `OrderCreated` fills in the rest. No retry-and-requeue mechanism is required (a simpler resolution than ADR-0020's own chained-lookup case, since here both writes target one row rather than two indexes).

## Consequences

- `docs/services/kart-review-service/ddd-model.md` and, at later stages, `database-design.md` and `event-contract.md` model `VerifiedPurchaseRecord` as consuming both `OrderCreated` and `OrderDelivered`.
- `docs/services/kart-review-service/architecture.md`'s Dependencies table is updated to add `OrderCreated` as an inbound (consumed) dependency from `kart-order-service`, alongside the existing `OrderDelivered` row.
- `kart-order-service/event-contract.md`'s `OrderCreated` consumer list (today: Payment, Notification, Analytics) should also be updated to add `kart-review-service` — a separate, already-flagged asymmetry this ADR's resolution now makes unambiguously blocking, the same posture ADR-0020 took toward its own equivalent flag. Not edited here — out of this ADR's own scope (a different service's already-approved file).
- No other service's already-approved `event-contract.md`, `ddd-model.md`, or payload shape changes. `kart-order-service` itself is otherwise unaffected — this ADR adds a reader, not a payload change.
