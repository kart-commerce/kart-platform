---
doc_type: adr
status: accepted
---

# ADR-0001: Merge Coupon, Pricing, and Promotion into `kart-offer-service`

## Status

Accepted

## Context

The BRD (`docs/requirements/kart-requirements.md` §2.1, §5.4) lists Coupon, Pricing, and Promotion as three separate services:

| Service | Core Concept |
|---|---|
| Pricing | Price computation, tax, currency |
| Promotion | Campaigns, flash sales, bundle deals |
| Coupon | Issuance, redemption, limits |

All three answer the same ubiquitous-language question — "what does this customer pay, and why" — and Promotion directly modifies the pricing computation, which is a domain coupling, not just a code-reuse opportunity. Building all three as separate day-one repos (of 20 total BRD services) also doesn't pass the phasing bar in §2.4 of the platform blueprint.

## Decision

Merge Coupon, Pricing, and Promotion into a single bounded context and repo: `kart-offer-service`.

This is valid **only if** the write model keeps them as three distinct aggregate roots — `PricingQuote`, `Coupon`, `PromotionCampaign` — sharing one bounded context, not one god-aggregate. The DDD Agent must enforce this when it produces the DDD model for this service.

## Consequences

- One repo, one pipeline, one on-call rotation covers all three concepts — reduces day-one repo count as the phasing plan requires.
- Risk accepted: Pricing sits on the hot read path (every cart/checkout computation) while Promotion is low-QPS and admin-driven. If they need to scale independently in practice, split them later — this is expected to be revisited, not a permanent commitment.
- The BRD's event catalog (§10) and the service table (§5.4) disagree on who publishes `ProductPriceChanged` (Product per §5.4, Pricing per §10). This ADR does not resolve that — it's flagged as an open question in `docs/services/kart-offer-service/requirement-spec.md` for human sign-off before the Architecture Agent proceeds.
