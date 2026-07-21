---
doc_type: edge-cases
service: kart-offer-service
status: pending-approval
generated_by: edge-case-analyzer-agent
source: docs/services/kart-offer-service/requirement-spec.md
---

# Edge Cases: kart-offer-service

## Edge Case: Coupon — Double-redemption for the same order under concurrent requests

- **What happens:** Two concurrent redemption requests for the same `coupon_code` + `order_id` (checkout double-click, client retry) both pass validation and attempt to insert a redemption, risking two `CouponRedeemed` events for one order.
- **Why it happens:** No serialization between the redemption read-check and the write; at-least-once delivery/retries mean the same logical redemption can be attempted more than once.
- **Solutions available (2):** DB-level unique constraint on `(coupon_code, order_id)` rejecting the second insert · Application-level idempotency key on the redeem request with a separate dedup cache.
- **Decision:**
  - Chosen: DB unique constraint on `(coupon_code, order_id)` — already present in database-design.md's `coupon_redemptions` table.
  - Why: Enforces the domain invariant ("a coupon must never be redeemed twice for the same order," requirement-spec §4 / ddd-model.md's `Coupon` invariants) at the storage layer, immune to app-level race timing.
  - Trade-off accepted: The losing concurrent request surfaces as a DB constraint violation, not a clean "already redeemed" response — the API layer must translate that conflict into an idempotent success (return the existing redemption) rather than a raw error.

## Edge Case: Coupon — Redemption-cap race under concurrent requests

- **What happens:** Two concurrent redemptions against the same coupon but different orders (same user in two sessions, or two different users on a globally-capped code) both read `total_redemptions < globalCap` (or per-user count < `perUserCap`) as true before either commits, and both insert — exceeding the cap.
- **Why it happens:** The `(coupon_code, order_id)` unique constraint only blocks the same-order case; cap enforcement (`RedemptionLimit.globalCap` / `perUserCap`, ddd-model.md) needs a count-check-then-insert that isn't atomic without explicit locking, and `/coupons/validate` sits on the checkout read path (P95 < 150ms, requirement-spec §3).
- **Solutions available (3):** `SELECT ... FOR UPDATE` on the `coupons` row scoped by `coupon_code`, wrapping cap-check + insert in one transaction · Optimistic check-then-insert with retry on conflict · Full serializable transaction isolation.
- **Decision:**
  - Chosen: `SELECT ... FOR UPDATE` on the `coupons` row per `coupon_code`, in the same transaction as the cap check and the `coupon_redemptions` insert.
  - Why: Coupon/Pricing/Promotion is an explicitly low-write-volume path (database-design.md: "far lower write volume than Order/Payment... writes only happen once per checkout"), so per-code lock contention is acceptable; mirrors the platform's existing oversell-prevention pattern that the requirement-spec itself draws the analogy to.
  - Trade-off accepted: Redemptions against the same code serialize — a single high-traffic flash-sale coupon becomes a throughput bottleneck under heavy concurrency; acceptable given the stated write-volume profile, revisit if that scenario materializes.

## Edge Case: Pricing — `ProductPriceChanged` arrives mid-quote-computation

- **What happens:** `ProductPriceChanged` is being applied to Offer's locally materialized price data at the same moment `/pricing/quote` reads that SKU's price, or the event simply hasn't been consumed yet when the quote is issued.
- **Why it happens:** architecture.md rules out a synchronous fetch to Product for `/pricing/quote` (to hold the P95 < 150ms budget) in favor of a locally cached/materialized price updated asynchronously by an at-least-once consumer — quote reads and price updates are not temporally ordered.
- **Solutions available (3):** Rely on Postgres row-level read-committed atomicity (single-row `UPDATE`/`SELECT`, no explicit lock) · Stamp a `priceVersion` on the issued quote so a later-superseded quote is detectable · Synchronous fetch from Product at quote time (rejected — reintroduces the latency dependency architecture.md explicitly ruled out).
- **Decision:**
  - Chosen: Rely on Postgres row-level atomicity for the read; treat the consumer-lag window as correct-by-definition, not a defect.
  - Why: `PricingQuote`'s invariant (ddd-model.md) only requires the quote to reflect the product price "at the moment of quoting," and a quote is an immutable snapshot, never retroactively recomputed — whichever price value the read observes (pre- or post-update) satisfies the invariant by construction, and a single-row read/write is already atomic.
  - Trade-off accepted: A quote can be issued moments before a price change lands, leaving a soon-to-be-stale price live until the quote's TTL expires (15 min, ddd-model.md Modeling Decision #2) — this is the pre-accepted cost of the no-sync-fanout architecture, not a new risk.

## Edge Case: Promotion — Stale Redis cache vs. an actively-changing campaign

- **What happens:** `/promotions/active` and `/pricing/quote`'s in-process promotion read (both ultimately served by Redis-cached reads over `promotion_campaigns`, per database-design.md) return a campaign that has already ended, or omit one that just started, for the span of the cache's staleness window.
- **Why it happens:** Redis is a cache-aside layer over PostgreSQL; a `PromotionActivated`/`PromotionDeactivated` write to `promotion_campaigns` does not itself invalidate the cache — only TTL expiry or an explicit invalidation does, and the two aren't coupled by default.
- **Solutions available (3):** TTL-only expiry · Event-driven invalidation (Offer consumes its own `PromotionActivated`/`PromotionDeactivated` to bust the affected cache key immediately) · Write-through cache (update Redis synchronously in the same transaction as the Postgres write).
- **Decision:**
  - Chosen: Event-driven invalidation on `PromotionActivated`/`PromotionDeactivated`, with a short TTL (seconds) as a backstop.
  - Why: requirement-spec §3's NFR table sets the bound explicitly — "Promotion staleness of seconds is tolerable" — event-driven invalidation handles the common case immediately, and the short TTL caps the worst case (a lost/delayed self-consumed event) at that same tolerance, without write-through's added write-path latency/complexity.
  - Trade-off accepted: A brief staleness window (bounded by the TTL) still exists between campaign start/end and cache reflection — acceptable per the stated NFR and consistent with the platform's at-least-once/idempotent-consumer posture.

## Edge Case: Promotion + Coupon — Discount stacking on the same quote

- **What happens:** A quote's order is simultaneously eligible for an active `PromotionCampaign` discount and a validated `Coupon` discount (or more than one applicable campaign) — risk of summing multiple discounts into an unintended total.
- **Why it happens:** `PricingQuote` is the single point where Coupon validation, Promotion lookup, and base price converge (ddd-model.md's Cross-Aggregate Interaction) — nothing structurally stops naively adding every applicable discount.
- **Solutions available (2):** Additive stacking (sum all applicable discounts) · Best-discount-wins, no stacking (single largest discount applied, others ignored).
- **Decision:**
  - Chosen: Best-discount-wins, no stacking — already resolved in ddd-model.md's Modeling Decision #3 ("given all campaigns active for a SKU at quote time, `PricingQuote` picks the single largest discount"), applied uniformly wherever a coupon discount and one or more promotion discounts could both apply to the same quote.
  - Why: A single deterministic winning discount avoids unbounded margin erosion from combining discount sources and keeps quote computation a pure "all applicable discounts in, one number out" function.
  - Trade-off accepted: Customers eligible for multiple discounts only ever receive the best one, never a combined saving — a constraint already accepted upstream, not re-argued here.
