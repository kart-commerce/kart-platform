---
doc_type: adr
status: accepted
---

# ADR-0014: Review Owns the Canonical Rating Aggregate; Product Consumes `ReviewSubmitted` for a Denormalized Copy

## Status

Accepted

## Context

Two BRD sections disagree about who is responsible for a product's rating aggregate, and this disagreement independently blocks two services' sign-off:

- BRD §2.1 (item 14) names "Ratings, reviews, moderation" as **Review Service's** primary responsibility.
- BRD §5.4's condensed service table lists Product's Consumes column as `—` (nothing) — implying Product does not react to any Review event at all.
- BRD §10's Event Catalog lists **Product** as a consumer of `ReviewSubmitted`, annotated "rating recalc" — directly contradicting the §5.4 row above.
- BRD §6.2's example `product_read_model` document embeds `ratingSummary: { avg, count }` directly on the Product-owned MongoDB collection, not on any Review-owned collection.

`kart-review-service/requirement-spec.md` (this pass, Open Question #4, pre-resolution) and `kart-product-service/requirement-spec.md` (already `status: approved`, its own Open Question #2, still carried as blocking) both independently flag the same underlying contradiction from their own side of the boundary. Neither service's spec can assert a rating-aggregate domain invariant with confidence until it's resolved once, in one place, rather than each service guessing independently — the same rationale ADR-0003/0004 already established for consumer-scope questions that touch more than one service.

This is not covered by any existing ADR: ADR-0001 through ADR-0009 address Offer's merge, Order-Shipping async integration, Notification's consumed-event scope, Analytics' fan-in, the Order terminal event, the Identity/User boundary, two event-catalog completeness passes, and Order-Inventory sync scope — none of them touch Review, Product, or rating-aggregate ownership.

## Decision

1. **§5.4's "Product Consumes: —" is the stale/incomplete reading, not §10's.** This project's own event-catalog completeness passes (ADR-0007, ADR-0008) already established the precedent that §5.4's condensed table is the less reliable of the two sources when it conflicts with §10 or with a service's own detailed section — see ADR-0008's `ProductPriceChanged` publisher correction, made on exactly this same kind of §5.4-vs-§10 mismatch. Applying the same precedent here: **Product does consume `ReviewSubmitted`**, confirming §10's "rating recalc" row.
2. **Review Service is the canonical system-of-record for ratings**, per BRD §2.1's explicit assignment of "ratings" to Review (item 14). Review computes and persists its own rating aggregate (`avg`, `count`) from its own PostgreSQL-sourced review history, exposed via Review's own read surface (`GET /reviews/{sku}/summary` or equivalent — final shape is the API Design Agent's job).
3. **Product's "rating recalc" is a denormalized, eventually-consistent copy, not a second canonical computation.** Product consumes `ReviewSubmitted` purely to keep its own `product_read_model.ratingSummary` field populated for product-page read locality (BRD §6.2's stated reason for denormalizing: "MongoDB has no cross-shard joins; embedding trades storage/staleness for read latency"). Product does not reconcile its copy against Review's canonical aggregate synchronously — it trusts its own incremental recompute from the event stream, consistent with the platform's standing CQRS/eventual-consistency default (BRD §7).
4. This makes the two services' aggregates two independent projections of the same event stream (`ReviewSubmitted`), not a client-server relationship — Product never calls Review synchronously to read the "real" number, and Review never blocks on Product's copy being up to date.

## Consequences

- Review's `requirement-spec.md` Domain Invariants can now assert "rating aggregate correctness is Review's own accountability" without hedging.
- Product's `requirement-spec.md` Open Question #2 is resolved by this ADR the next time that service's docs are revisited: Product does consume `ReviewSubmitted`, and its rating-recalc logic is a denormalization, not primary ownership. That file is out of scope for this pass (different service) and is not edited here — the resolution is recorded so a later pass can close it by citation, the same way this pass closes Review's side.
- Two independently-maintained rating numbers (Review's canonical aggregate, Product's denormalized copy) can drift transiently under eventual consistency — accepted, same risk profile the platform already accepts for every other denormalized read model (BRD §7).
- No new event or payload change is required by this decision alone — `ReviewSubmitted`'s existing `orderId, sku, rating` payload is sufficient for Product's incremental recompute. (Whether the payload should also carry `reviewId`/`userId`/review text is a separate question, resolved on its own merits in Review's `requirement-spec.md`.)
