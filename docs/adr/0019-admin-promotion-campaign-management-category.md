---
doc_type: adr
status: accepted
---

# ADR-0019: Promotion Campaign Management Added as a Fifth Admin Back-Office Category — Extends ADR-0010's Closed Enumeration

## Status

Accepted

## Context

`kart-offer-service/requirement-spec.md` §2 (Promotion) already resolved, as a single-service engineering default, that campaign creation/deactivation is exposed via internal, admin-invoked write endpoints (`POST /promotions`, `POST /promotions/{campaignId}/deactivate`), "following the identical integration pattern ADR-0010 already establishes for coupon issuance." At the time, that same section noted a gap: ADR-0010's Decision #1 closed-enumeration table (Catalog management, Coupon issuance, User suspension, Inventory replenishment) names Coupon issuance explicitly but does not name Promotion campaign management as its own category — and BRD §24.1's own illustrative `Admin` role examples ("Catalog management, coupon issuance, user suspension") don't list it either. requirement-spec.md treated this as "a minor, low-risk gap in that ADR's own enumeration... formally extending that table is a trivial follow-up edit belonging to that ADR's own file, not a blocker for this service's sign-off" — deferred, not ignored.

This ADR is that follow-up, triggered now because completing `kart-offer-service`'s own pipeline (`api-contract.yaml`, `database-design.md`, `event-contract.md`, `tickets.md`) requires actually building the four admin-write endpoints ADR-0010's pattern governs — at which point "Promotion campaign management isn't in the closed enumeration" stops being a deferrable footnote and starts being a real gap between what Offer's own docs assume Admin is authorized to call and what ADR-0010's table actually lists. The identical situation already arose once before: ADR-0017 added a fifth category ("Compliance / erasure request intake") to this same table for the identical reason (a downstream service's completed pipeline needed the category ADR-0010 hadn't yet named). This ADR follows that exact precedent, not a new pattern.

## Decision

**Promotion campaign management is added as a fifth business category to ADR-0010's closed enumeration**, alongside Catalog management, Coupon issuance, User suspension, and Inventory replenishment (Compliance/erasure-request intake was already added as a fifth by ADR-0017, making this the sixth entry in the table as it now stands):

| Category | Concrete operations | Owning service whose data is mutated |
|---|---|---|
| Promotion campaign management | Create/deactivate a `PromotionCampaign` | Offer Service (`PromotionCampaign` aggregate, per ADR-0001) |

- **Mechanically identical to Coupon issuance**, the category it sits beside: Admin Service invokes `kart-offer-service`'s own `POST /promotions`/`POST /promotions/{campaignId}/deactivate` endpoints synchronously (internal, client-credentials service-to-service call, per ADR-0010 Decision #2) — Admin's own PostgreSQL database gains no new stored data beyond its existing `admin_permission_grants`/`AdminActionPerformed` rows; it does not become a second owner of `PromotionCampaign` state, the same non-negotiable property ADR-0010 established for every other category.
- **Grant-gated the same way as Admin's other categories**: a `promotion-management` value is added to `admin_permission_grants.category` — a `TEXT` column, not a fixed enum at the database layer (the same accommodation ADR-0017 already used to add its own fifth category without a schema change).
- **Why a separate category from Coupon issuance, not folded into it:** `Coupon` and `PromotionCampaign` are distinct aggregate roots in the same bounded context (`kart-offer-service/ddd-model.md`) but are still two different resources with two different write endpoints — Admin's own grant model is scoped per concrete operation set, not per owning service, so a grant covering Coupon issuance does not implicitly authorize Promotion campaign management, matching how User suspension and Compliance/erasure-request intake remain separate categories despite both ultimately touching user-scoped state.
- **Why not deferred further:** the underlying operations (`POST /promotions`, `POST /promotions/{campaignId}/deactivate`) are being formally added to `kart-offer-service/api-contract.yaml` in this same pass — leaving the calling authorization category unresolved while the callee endpoint goes fully specified would recreate exactly the "Offer's coupon-creation write endpoint is likewise unstated" gap ADR-0010's own Consequences section originally flagged, just shifted one category over.

## Consequences

- `kart-offer-service/requirement-spec.md`'s Open Question #6 (Promotion half) is closed by citation — no further "trivial follow-up edit" remains outstanding.
- `kart-admin-service`'s own `requirement-spec.md`/`architecture.md` need this fifth category (sixth overall, after ADR-0017's compliance addition) added in a future documentation pass for that service specifically — not applied to those files by this ADR itself, the same "decide the integration pattern, don't edit the sibling service's docs directly" boundary ADR-0010 and ADR-0017 already observed for their own cross-service consequences.
- Admin Service's synchronous outbound fan-out gains no new *peer* (it already calls Offer for Coupon issuance) — this is a new grant category against an already-existing outbound edge, not a new distributed-monolith risk.
- Accepted risk: identical to every other ADR-0010 category — authorization is gated only by the coarse `Admin` role plus this new category-scoped grant, no additional approval workflow specified, consistent with the platform's existing back-office authorization posture.
