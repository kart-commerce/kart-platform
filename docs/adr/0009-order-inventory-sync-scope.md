---
doc_type: adr
status: accepted
---

# ADR-0009: The Order↔Inventory Reserve Call Is Synchronous — ADR-0002's Note Does Not Extend To It

## Status

Accepted

## Context

ADR-0002 resolved the Order↔Shipping integration direction as fully async, and a clarifying prose note was added directly under `kart-requirements.md` §12.1's Saga diagram to record that resolution. That note's original wording said "**every arrow above** is async pub/sub over the message bus, not synchronous RPC" — but §12.1's diagram's first two arrows are `Order->>Inventory: Reserve stock` / `Inventory-->>Order: InventoryReserved`, and "every arrow" as literally written covers those too.

This is a real, uncovered contradiction, found during a BRD self-consistency audit: §5.1's Dependencies row states plainly that Inventory reservation is a "**sync reserve call** + async confirm," and §5.2 gives Inventory a REST API for it (`POST /inventory/reserve`) consistent with a synchronous call — not an event Order publishes and Inventory consumes asynchronously. ADR-0002's Context and Decision sections both scope themselves explicitly to Order↔**Shipping**; Inventory is never mentioned in either. The overreach was introduced only in the note's summary phrase ("every arrow"), not in ADR-0002's actual decision.

`kart-inventory-service`'s and `kart-order-service`'s own approved `requirement-spec.md` docs both already describe the reserve call as synchronous, consistent with §5.1/§5.2 — neither downstream doc inherited the note's overreach. This ADR exists solely to correct the BRD's own internal contradiction, not to change any decision already made and relied upon downstream.

## Decision

The §12.1 note is narrowed to cover only the Payment→Shipping portion of the diagram (from `Order->>Payment: Charge` onward), matching ADR-0002's actual scope. A new sentence is added immediately after it, stating explicitly that the Inventory reserve step is the one exception: it is a genuine synchronous RPC (`POST /inventory/reserve`), with `InventoryReserved` published afterward for the async saga-advancement side of that same step — the reservation call itself and the saga-advancement event are two different things, not one async round-trip.

## Consequences

- No downstream service doc needs to change: `kart-inventory-service` and `kart-order-service` already read the reserve call as synchronous, and this ADR just makes the BRD's own note stop contradicting them.
- Future readers of §12.1 won't misread the note as claiming Inventory reservation is async — the prior wording's blanket "every arrow" was the actual bug, not any downstream design.
- This ADR is scoped narrowly on purpose: it does not re-open ADR-0002's Order↔Shipping resolution, and does not touch any other arrow in §12.1 or §12.2.
