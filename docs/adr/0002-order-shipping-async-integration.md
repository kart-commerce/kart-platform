---
doc_type: adr
status: accepted
---

# ADR-0002: Order ↔ Shipping Integration Is Fully Async

## Status

Accepted

## Context

`kart-requirements.md` §12.1's Saga diagram shows `Order->>Shipping: Create shipment` / `Shipping-->>Order: ShipmentDispatched` using the same request/reply arrow notation as a synchronous call, and places `Order->>Order: Mark OrderConfirmed` *after* that exchange — reading as if Order blocks on Shipping before confirming. This contradicted §5.4 and §10, which both describe Shipping as an async consumer of `OrderConfirmed`, publishing `ShipmentDispatched` back independently. `docs/services/README.md` tracked this as an open cross-service contradiction; `kart-order-service`'s own design docs did not flag it as unresolved before this ADR, which was one reason that service's professional-grade review came back NEEDS-WORK.

## Decision

Order ↔ Shipping is async, end to end — matching §5.4/§10, not the literal call/reply reading of the §12.1 diagram:

- `OrderConfirmed` is published by Order as soon as Payment clears (`PaymentCompleted` received) — this is the actual confirmation trigger, not shipment creation.
- Shipping is a pure async consumer of `OrderConfirmed`; it has no synchronous inbound endpoint from Order.
- `ShipmentDispatched` flows back to Order (and Notification, Tracking) as an informational status update, not as a gate on order confirmation.

The same arrow notation in §12.1 is used for the Payment step too, and Payment is unambiguously async per §5.1's Dependencies row — so the notation itself never carried sync/async meaning, only causal sequence. A clarifying note was added directly under the §12.1 diagram in `kart-requirements.md` so this doesn't need re-litigating per service.

## Consequences

- Shipping's API surface needs no synchronous inbound endpoint for shipment creation — only its existing async consumer and its own `/shipments` query API.
- Order's confirmation latency is decoupled from Shipping's fulfillment latency/availability — consistent with the platform's stated goal of independent service availability.
- The original diagram is left as-is (not redrawn) to avoid a large, risky Mermaid edit; the prose note is the authoritative clarification going forward.
- `kart-order-service`'s `requirement-spec.md` should cite this ADR instead of leaving the integration direction as an open question.
