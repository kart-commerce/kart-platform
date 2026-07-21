---
doc_type: adr
status: accepted
---

# ADR-0008: Event Catalog Completeness Pass, Round 2

## Status

Accepted

## Context

ADR-0007 closed 8 events that were named as a service's own published event somewhere in `kart-requirements.md` §5.1–§5.4 but had no row in §10's Event Catalog. A follow-up BRD self-consistency audit, done after all 18 services' `requirement-spec.md`/`edge-cases.md` had been brought to `status: approved`, found ADR-0007's pass was itself incomplete and introduced one new violation of its own stated defaults:

- Four more events named as a service's own Publish in §5.4 had no §10 row at all: `CategoryUpdated` (Category), `PriceQuoteIssued` (Pricing/Offer), `PromotionActivated` (Promotion/Offer), `UserProfileUpdated` (User).
- `UserAccountUpdated`'s row (added by ADR-0006) omits Analytics as a consumer, which violates ADR-0004's own stated platform default: "every future new event automatically has Analytics as a consumer by default."
- `ProductPriceChanged`'s Publisher was still listed as "Pricing" in §10, contradicting §5.4's Product row (which lists `ProductPriceChanged` as Product's own publish) and contradicting `kart-offer-service`'s own approved `requirement-spec.md`, which already settled this reading (Product publishes; Pricing/Offer only consumes to compute quotes) — the exact question ADR-0001 explicitly left open pending that service's sign-off. §10's consumer list for this event also omitted Offer, even though §5.4's Offer row states it consumes `ProductPriceChanged`.

One further named event, `ProductUpdated` (mentioned only in §16's caching prose — never in Product's own Publishes list at §5.4, and absent from §10) was investigated and deliberately **not** added as a new catalog row: it's genuinely ambiguous whether this is a real third event distinct from `ProductPriceChanged` or a prose slip referring to the same event, and `kart-product-service/requirement-spec.md`'s own Open Question #6 already flags this. Inventing a full row (publisher, payload, retry/DLQ) would silently resolve that ambiguity rather than surface it — exactly what this project's standards forbid.

## Decision

1. Add four rows to §10, each with Analytics as the only consumer (per ADR-0004's default) — no other consumer is added, since none is stated or safely inferable elsewhere in the BRD:

| Event | Publisher | Retry tier | Rationale |
|---|---|---|---|
| `CategoryUpdated` | Category | 3x, `catalog.dlq` | Same tier as sibling catalog events (`ProductCreated`/`ProductPriceChanged`) |
| `PriceQuoteIssued` | Offer | 2x, `coupon.dlq` | Same tier as sibling Offer event (`CouponRedeemed`) — merged bounded context, shared DLQ |
| `PromotionActivated` | Offer | 2x, `coupon.dlq` | Same tier as sibling Offer event |
| `UserProfileUpdated` | User | 2x, `user.dlq` | Own DLQ, not Identity's — User is a separate service/repo from Identity even though both are identity-adjacent |

2. Add Analytics to `UserAccountUpdated`'s consumer list, correcting the ADR-0004 default violation.
3. Correct `ProductPriceChanged`'s Publisher from "Pricing" to "Product" in §10, and add Offer to its consumer list.
4. Leave `ProductUpdated` unresolved — no new row added. The ambiguity is preserved and cited, not silently closed.

## Consequences

- Whether any service besides Analytics needs to consume `CategoryUpdated`, `PriceQuoteIssued`, `PromotionActivated`, or `UserProfileUpdated` is not resolved by this ADR — if a downstream service's own requirement-spec later needs one of these (e.g., Product reacting to a category rename), that's a new, separate finding for that service's own docs, not something this ADR should be read as having already answered.
- `ProductPriceChanged`'s publisher correction has no behavioral consequence for any approved downstream doc — `kart-offer-service`, `kart-product-service`, `kart-wishlist-service` already read it as "Product publishes" in their own text; this ADR only makes the BRD's own Event Catalog agree with what they already assumed.
- `ProductUpdated` remains a real, open gap. It is carried forward, not closed by omission.
