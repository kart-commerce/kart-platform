---
doc_type: ddd-model
service: kart-offer-service
status: approved
generated_by: ddd-agent
source: docs/services/kart-offer-service/architecture.md, docs/services/kart-offer-service/requirement-spec.md, docs/services/kart-offer-service/edge-cases.md, docs/services/kart-offer-service/design-decisions.md, docs/adr/0019-admin-promotion-campaign-management-category.md
---

# DDD Model: kart-offer-service

Three aggregate roots in one bounded context, per [ADR-0001](../../adr/0001-offer-service-merge.md). Each is its own transaction boundary — none of the invariants below require a cross-aggregate transaction, which is the test that validates the merge is legitimate DDD, not just convenient packaging.

## Aggregate: Coupon

**Entity:** `Coupon` — identified by `CouponCode` (value object).

**Value objects:** `RedemptionLimit` (per-user cap, global cap, validity window — see Modeling Decision #1).

**Invariants:**
- A coupon must never be redeemed twice for the same order (idempotency on `orderId`).
- Total redemptions must never exceed `RedemptionLimit.globalCap`, if set.
- Per-user redemptions must never exceed `RedemptionLimit.perUserCap`, if set.
- Redemption is only valid within `RedemptionLimit.validityWindow`.
- **Deactivation never retroactively invalidates a redemption that already completed before the deactivation write committed** (requirement-spec §4 Domain Invariant) — deactivating only prevents *future* `/coupons/validate`/`/coupons/redeem` calls from seeing the code as active. Modeled as **early-truncating `RedemptionLimit.validityWindow`'s end**, not a separate `Active`/`Deactivated` status field — see Modeling Decision #4.
- Admin-invoked issuance (`POST /coupons`) requires a globally unique `couponCode` — enforced by the existing PRIMARY KEY (database-design.md), the same identifying value object property that already makes `CouponCode` the aggregate's identity; a duplicate-code creation attempt is a conflict, not a new invariant.

**Domain events:**
- `CouponRedeemed` (published — existing, BRD §10)
- `CouponRedemptionVoided` (published — **new**, not in the BRD's event catalog; needed to fulfill the requirement spec's "consume `OrderCancelled` to reverse/void a coupon redemption." Published so Analytics' funnel numbers stay accurate after an order cancellation reverses a redemption. Proposed addition to the ubiquitous language and event catalog — flagged for review, not blocking.)
- `CouponIssued` (published — **new**, not in the BRD's event catalog; fired on `POST /coupons`, the write path requirement-spec §2/§6 item 6 resolved. Symmetric to `PromotionActivated`'s "campaign goes live" signal below — gives Analytics' full fan-in (ADR-0004) visibility into the coupon lifecycle's start, not only its terminal `CouponRedeemed`/`CouponRedemptionVoided` events.)
- `CouponDeactivated` (published — **new**, not in the BRD's event catalog; fired only on explicit admin deactivation (`POST /coupons/{couponCode}/deactivate`), **never** on a coupon simply reaching the end of its natural `validityWindow` — natural expiry needs no event, since `/coupons/validate` already checks the window at read time and no scheduled sweep job exists or is needed to detect it. Symmetric to `PromotionDeactivated` below, same reasoning.)

## Aggregate: PricingQuote

**Entity:** `PricingQuote` — identified by `QuoteId`, immutable once issued (a snapshot, never mutated after creation).

**Value objects:** `Money` (amount + currency).

**Invariants:**
- A quote reflects the product price and any active promotion at the moment of quoting — never recomputed retroactively.
- A quote expires after a TTL (see Modeling Decision #2) — an expired quote must be re-issued, not reused, at checkout.

**Domain events:**
- `PriceQuoteIssued` (published — existing, BRD §5.4; consumer confirmed as Analytics-only, requirement-spec Q5 resolved via ADR-0008/ADR-0004)

## Aggregate: PromotionCampaign

**Entity:** `PromotionCampaign` — identified by campaign id.

**Value objects:** `DiscountRule`, `CampaignWindow`.

**Invariants:**
- A campaign only applies within its `CampaignWindow`.
- Precedence when multiple campaigns apply to the same SKU is defined (see Modeling Decision #3) — the aggregate must resolve this deterministically, not leave it to caller order.
- **Deactivation never retroactively invalidates a `PricingQuote` already issued before the deactivation write committed** (requirement-spec §4 Domain Invariant, the same rule stated for `Coupon` above, applied identically here) — a quote is an immutable snapshot regardless of what happens to the campaign afterward (see `PricingQuote`'s own invariants). Modeled as **early-truncating `CampaignWindow`'s end** (`ends_at`), not a separate status field — see Modeling Decision #4, the same mechanism as `Coupon`'s deactivation.
- Admin-invoked creation (`POST /promotions`) assigns a new campaign id; no uniqueness constraint beyond the generated identifier itself (unlike `CouponCode`, a campaign has no caller-supplied natural key to conflict on).

**Domain events:**
- `PromotionActivated` (published — existing, BRD §5.4; consumer confirmed as Analytics-only, requirement-spec Q5 resolved via ADR-0008/ADR-0004) — fired on `POST /promotions` (campaign creation/activation, requirement-spec §2/§6 item 6).
- `PromotionDeactivated` (published — **new**, symmetric counterpart; not in the BRD, added so Analytics' fan-in ingestion (ADR-0004) has a matching "campaign ended" signal instead of only ever seeing activations. Same Analytics-only consumer resolution as `PromotionActivated`.) — fired only on explicit admin deactivation (`POST /promotions/{campaignId}/deactivate`), **never** on a campaign simply reaching the end of its natural `CampaignWindow` — the identical "no event on natural expiry, only on explicit action" rule as `Coupon.CouponDeactivated` above, for the identical reason (no scheduled sweep job exists or is needed; `/promotions/active` already checks the window at read time).

## Cross-Aggregate Interaction

`PricingQuote` computation reads `PromotionCampaign` (for active discounts) and the locally materialized product price (from `ProductPriceChanged`, per architecture.md's caching note) **in-process, synchronously, within the same bounded context** — not via an event, per architecture.md's resolution of requirement-spec Q4. This is a read, not a transaction: issuing a `PricingQuote` never writes to `PromotionCampaign` or vice versa, so the transaction-boundary test still holds.

## Modeling Decisions & Assumptions (resolved here, not escalated — engineering defaults, revisable)

1. **Coupon redemption limit semantics (requirement-spec Q3, resolved):** Model all three dimensions — per-user cap, global cap, validity window — as configurable fields on `RedemptionLimit`, each independently optional. This matches how real coupon systems work (a coupon can be "one per customer," "1000 total," "valid this week," or any combination) rather than forcing a single interpretation the BRD didn't actually specify.
2. **PricingQuote TTL:** BRD doesn't specify one. Assuming 15 minutes as a starting default (typical for e-commerce price-quote validity) — revisit once Database/API Design Agents need a concrete number for schema/cache design.
3. **Promotion precedence rule — confirmed:** "Best discount for the customer wins" when multiple campaigns target the same SKU. No stacking. `PromotionCampaign`'s selection logic must be deterministic: given all campaigns active for a SKU at quote time, `PricingQuote` picks the single largest discount.
4. **Deactivation mechanism (requirement-spec §2/§6 item 6, `POST /coupons/{couponCode}/deactivate` and `POST /promotions/{campaignId}/deactivate`) — resolved here, not previously modeled.** Neither `Coupon` nor `PromotionCampaign` gains a separate `Active`/`Deactivated` status field. Deactivation is modeled as **early-truncating the aggregate's own existing window end** — `RedemptionLimit.validityWindow`'s end for `Coupon`, `CampaignWindow`'s end for `PromotionCampaign` — to the deactivation moment, never later than whatever end was already set (a deactivation request against an already-naturally-expired window is a no-op, not an extension; database-design.md's `LEAST()`-based conditional update enforces this at the write layer). This is a deliberately reused mechanism rather than a new field, for two reasons: (a) both aggregates already have exactly the invariant a truncated window needs — "only valid within the window" — so no new read-path branch is needed anywhere `/coupons/validate`, `/coupons/redeem`, `/pricing/quote`, or `/promotions/active` already check the window; (b) it makes the "deactivation never retroactively invalidates a past redemption/quote" invariant (above) true by construction, since a window-end change can only affect *future* reads, never a redemption/quote row that already exists as its own separate, already-committed record. This also fixes exactly when `CouponDeactivated`/`PromotionDeactivated` fire: only on this explicit write, never on a window simply elapsing on its own (no polling/sweep job is introduced to detect natural expiry — nothing downstream needs telling "the window passed," since every read-path check already computes that live).

## Sign-off

- [x] Reviewed by: kakon-mehedi
- [x] Approved to proceed to API/Database/Event Design Agents
