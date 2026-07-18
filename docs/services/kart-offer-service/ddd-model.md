---
doc_type: ddd-model
service: kart-offer-service
status: approved
generated_by: ddd-agent
source: docs/services/kart-offer-service/architecture.md
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

**Domain events:**
- `CouponRedeemed` (published — existing, BRD §10)
- `CouponRedemptionVoided` (published — **new**, not in the BRD's event catalog; needed to fulfill the requirement spec's "consume `OrderCancelled` to reverse/void a coupon redemption." Published so Analytics' funnel numbers stay accurate after an order cancellation reverses a redemption. Proposed addition to the ubiquitous language and event catalog — flagged for review, not blocking.)

## Aggregate: PricingQuote

**Entity:** `PricingQuote` — identified by `QuoteId`, immutable once issued (a snapshot, never mutated after creation).

**Value objects:** `Money` (amount + currency).

**Invariants:**
- A quote reflects the product price and any active promotion at the moment of quoting — never recomputed retroactively.
- A quote expires after a TTL (see Modeling Decision #2) — an expired quote must be re-issued, not reused, at checkout.

**Domain events:**
- `PriceQuoteIssued` (published — existing, BRD §5.4; consumer still unconfirmed per requirement-spec Q5)

## Aggregate: PromotionCampaign

**Entity:** `PromotionCampaign` — identified by campaign id.

**Value objects:** `DiscountRule`, `CampaignWindow`.

**Invariants:**
- A campaign only applies within its `CampaignWindow`.
- Precedence when multiple campaigns apply to the same SKU is defined (see Modeling Decision #3) — the aggregate must resolve this deterministically, not leave it to caller order.

**Domain events:**
- `PromotionActivated` (published — existing, BRD §5.4; consumer still unconfirmed per requirement-spec Q5)
- `PromotionDeactivated` (published — **new**, symmetric counterpart; needed so external consumers like Notification aren't left inferring campaign end from silence)

## Cross-Aggregate Interaction

`PricingQuote` computation reads `PromotionCampaign` (for active discounts) and the locally materialized product price (from `ProductPriceChanged`, per architecture.md's caching note) **in-process, synchronously, within the same bounded context** — not via an event, per architecture.md's resolution of requirement-spec Q4. This is a read, not a transaction: issuing a `PricingQuote` never writes to `PromotionCampaign` or vice versa, so the transaction-boundary test still holds.

## Modeling Decisions & Assumptions (resolved here, not escalated — engineering defaults, revisable)

1. **Coupon redemption limit semantics (requirement-spec Q3, resolved):** Model all three dimensions — per-user cap, global cap, validity window — as configurable fields on `RedemptionLimit`, each independently optional. This matches how real coupon systems work (a coupon can be "one per customer," "1000 total," "valid this week," or any combination) rather than forcing a single interpretation the BRD didn't actually specify.
2. **PricingQuote TTL:** BRD doesn't specify one. Assuming 15 minutes as a starting default (typical for e-commerce price-quote validity) — revisit once Database/API Design Agents need a concrete number for schema/cache design.
3. **Promotion precedence rule — confirmed:** "Best discount for the customer wins" when multiple campaigns target the same SKU. No stacking. `PromotionCampaign`'s selection logic must be deterministic: given all campaigns active for a SKU at quote time, `PricingQuote` picks the single largest discount.

## Sign-off

- [x] Reviewed by: kakon-mehedi
- [x] Approved to proceed to API/Database/Event Design Agents
