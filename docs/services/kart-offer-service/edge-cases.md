---
doc_type: edge-cases
service: kart-offer-service
status: approved
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

## Edge Case: Coupon — Validity window expires while checkout is in flight

- **What happens:** `/coupons/validate` accepts a coupon because the check runs inside `RedemptionLimit.validityWindow`, but the actual redemption write (triggered when the checkout/order transaction that uses it finally commits) happens after `validityWindow` has ended — the coupon was valid when checkout began, expired before checkout finished.
- **Why it happens:** ddd-model.md's `Coupon` aggregate states the invariant as a redemption-time check, not a quote/lock-in guarantee: "Redemption is only valid within `RedemptionLimit.validityWindow`" — validation and redemption are two separate calls separated by however long checkout takes (client think-time, payment processing, Saga latency), and nothing snapshots eligibility between them the way `PricingQuote` snapshots price.
- **Solutions available (3):** Re-check `validityWindow` inside the same locked transaction as the redemption insert (the existing `SELECT ... FOR UPDATE` transaction from the redemption-cap race above already holds the row; extend its check), rejecting with a specific "coupon expired" error if the window has closed · Snapshot eligibility at `/coupons/validate` time and honor it through redemption regardless of window closure in between · Silently drop the coupon and let the order proceed at full price without surfacing an error.
- **Decision:**
  - Chosen: Re-check `validityWindow` inside the same locked transaction as the redemption insert; reject with a specific "coupon expired" error (not a generic failure) if the window has closed by the time the redemption write executes.
  - Why: ddd-model.md's invariant is worded as a redemption-time constraint ("Redemption is only valid within `RedemptionLimit.validityWindow`"), not a validate-time-lock-in guarantee — unlike `PricingQuote`, no aggregate or value object gives `Coupon` a snapshot-and-honor semantic, so enforcing strictly at the moment of the write is the only reading the stated invariant supports; this also reuses the transaction the redemption-cap race edge case (above) already opens, at no extra locking cost.
  - Trade-off accepted: A customer who saw a valid discount at checkout start can lose it if checkout crosses the validity-window boundary before the redemption write commits — this is accepted as the direct, literal consequence of the invariant as stated, not a gap; if product later wants quote-style lock-in for coupons, that requires a new modeling decision upstream (ddd-model.md), not a silent fix here.

## Edge Case: Pricing — `ProductPriceChanged` arrives mid-quote-computation

- **What happens:** `ProductPriceChanged` is being applied to Offer's locally materialized price data at the same moment `/pricing/quote` reads that SKU's price, or the event simply hasn't been consumed yet when the quote is issued.
- **Why it happens:** architecture.md rules out a synchronous fetch to Product for `/pricing/quote` (to hold the P95 < 150ms budget) in favor of a locally cached/materialized price updated asynchronously by an at-least-once consumer — quote reads and price updates are not temporally ordered.
- **Solutions available (3):** Rely on Postgres row-level read-committed atomicity (single-row `UPDATE`/`SELECT`, no explicit lock) · Stamp a `priceVersion` on the issued quote so a later-superseded quote is detectable · Synchronous fetch from Product at quote time (rejected — reintroduces the latency dependency architecture.md explicitly ruled out).
- **Decision:**
  - Chosen: Rely on Postgres row-level atomicity for the read; treat the consumer-lag window as correct-by-definition, not a defect.
  - Why: `PricingQuote`'s invariant (ddd-model.md) only requires the quote to reflect the product price "at the moment of quoting," and a quote is an immutable snapshot, never retroactively recomputed — whichever price value the read observes (pre- or post-update) satisfies the invariant by construction, and a single-row read/write is already atomic.
  - Trade-off accepted: A quote can be issued moments before a price change lands, leaving a soon-to-be-stale price live until the quote's TTL expires (15 min, ddd-model.md Modeling Decision #2) — this is the pre-accepted cost of the no-sync-fanout architecture, not a new risk.

## Edge Case: Pricing — Expired `PricingQuote` reused at checkout

- **What happens:** A `PricingQuote` issued by `/pricing/quote` is presented at checkout (cart left idle, slow client, long Saga step) after its 15-minute TTL (ddd-model.md Modeling Decision #2) has elapsed, and checkout attempts to consume/finalize against it as if it were still current.
- **Why it happens:** ddd-model.md's `PricingQuote` invariant states this outcome explicitly as a hard rule: "A quote expires after a TTL... an expired quote must be re-issued, not reused, at checkout." A quote is an immutable snapshot with no push-based invalidation to the client holding it — nothing stops a client from submitting an expired `quoteId` at the moment of commit.
- **Solutions available (3):** Reject at consumption time — check `issuedAt + TTL` against current time when the quote is presented at checkout, return a specific "quote expired, re-quote required" error · Silently re-issue a fresh quote server-side under the same `quoteId` and proceed with the new totals · Accept it anyway within a small grace window past the nominal TTL.
- **Decision:**
  - Chosen: Reject at consumption time and require the client to call `/pricing/quote` again for a fresh snapshot; no silent re-issue and no grace window.
  - Why: ddd-model.md's invariant leaves no discretion — "must be re-issued, not reused" is stated as a hard rule, not an open question — and silently re-issuing behind the same `quoteId` would violate the aggregate's other stated invariant that a quote is "immutable once issued... never recomputed retroactively" (ddd-model.md, Aggregate: `PricingQuote`); rejecting and forcing an explicit re-quote is the only option consistent with both invariants at once.
  - Trade-off accepted: A customer whose checkout crosses the 15-minute TTL boundary must re-request a quote and may see a different price/promotion than the one that expired — this friction is the intended effect of the TTL (preventing stale-price honoring), not a defect; a UX-level grace window could be proposed later without contradicting the invariant, but that is a new modeling decision for ddd-model.md, not a default assumed here.

## Edge Case: Promotion — Stale Redis cache vs. an actively-changing campaign

- **What happens:** `/promotions/active` and `/pricing/quote`'s in-process promotion read (both ultimately served by Redis-cached reads over `promotion_campaigns`, per database-design.md) return a campaign that has already ended, or omit one that just started, for the span of the cache's staleness window.
- **Why it happens:** A `PromotionActivated`/`PromotionDeactivated` write to `promotion_campaigns` does not itself guarantee the Redis-cached read reflects it immediately, unless the cache write is made part of the same operation as the DB write.
- **Solutions available (3):** TTL-only expiry · Event-driven invalidation (Offer consumes its own `PromotionActivated`/`PromotionDeactivated` to bust the affected cache key immediately) · Write-through cache (update Redis synchronously in the same transaction as the Postgres write).
- **Decision:**
  - Contradiction identified: Two upstream, approved documents disagree on this exact field class. requirement-spec §3's NFR table states, for the Consistency attribute: "Eventual for Promotion (Redis cache)... Promotion staleness of seconds is tolerable" — implying a cache-aside-family pattern (TTL and/or event-driven invalidation) is sufficient. BRD §16's Caching table states, unconditionally: "Write-Through | Promotion/active-campaign flags | Write updates Redis and DB synchronously since staleness there is unacceptable for pricing" — ruling out cache-aside-family patterns for this exact field class. These cannot both govern.
  - Chosen: Write-through cache — update Redis synchronously in the same transaction/operation as the PostgreSQL write to `promotion_campaigns`, superseding the previously-chosen event-driven-invalidation-plus-TTL approach.
  - Why: BRD §16 governs over requirement-spec §3's row. §16 is the specific, deliberate rule for exactly this field class — the BRD itself confirms it's intentional, not incidental, by posing "Why cache-aside for products but write-through for promotions?" as a named interview question (BRD §16 area) — whereas requirement-spec §3's Consistency row reads as inherited from the BRD's generic global Consistency guidance without cross-referencing §16's specific carve-out for pricing-sensitive flags. This is a defensible engineering default, not a business/product judgment call: §16 leaves no discretion about whether staleness is tolerable here, so there is no revenue/policy trade-off to escalate. This also matches the platform's existing precedent: kart-product-service/edge-cases.md's "Read-model staleness after a price change" edge case made the identical write-through call under the identical BRD §16 clause for the identical class of field (pricing-sensitive), and Offer should not diverge from that precedent for the same BRD rule.
  - Trade-off accepted: Added write-path latency on every write to `promotion_campaigns` (Redis and Postgres now committed together, instead of a fire-and-forget async invalidation) versus the lower-latency event-driven approach previously chosen; accepted because BRD §16 treats promotion/pricing staleness as categorically unacceptable, not as a latency/complexity trade left open for this service to optimize. requirement-spec.md §3's Consistency row has since been corrected to state write-through/strong consistency for this field class instead of the bound §16 forbids — no longer a live contradiction.

## Edge Case: Coupon — Admin deactivation races an in-flight validate→redeem sequence

- **What happens:** `POST /coupons/{couponCode}/deactivate` (requirement-spec §2 Coupon, admin-invoked) commits at the same moment a customer's checkout is between a passing `/coupons/validate` call and the redemption write actually committing — risking a redemption completing against a code that is, from that instant, supposed to be dead.
- **Why it happens:** Deactivation and redemption both mutate/read the same `coupons` row but are two independent write paths with no coordination between them by default, the same shape of race as the redemption-cap race above, just with a new writer (Admin) instead of a second concurrent redeemer.
- **Solutions available (2):** Have deactivation acquire the same per-`coupon_code` row lock (`SELECT ... FOR UPDATE`) the redemption-cap-race edge case above already uses, so it serializes against any in-flight redemption transaction · Treat deactivation as advisory-only, checked solely at `/coupons/validate` time, letting any redemption already past validation complete regardless of a deactivation landing mid-flight.
- **Decision:**
  - Chosen: Deactivation takes the same `SELECT ... FOR UPDATE` lock on the `coupons` row, in the same transaction as the deactivation write, before the redemption-cap-race edge case's transaction can proceed on that row.
  - Why: Reuses the exact locking primitive already established for the redemption-cap race and the validity-window edge cases above at no new mechanism cost, and gives the strongest, simplest guarantee: once deactivation commits, no redemption that hasn't already passed its own lock acquisition can succeed against that code.
  - Trade-off accepted: A redemption that had already acquired the lock and was mid-transaction at the moment deactivation was requested completes anyway (deactivation blocks until that transaction finishes, then applies) — a narrow last-instant race is accepted rather than added complexity (e.g. a cancel-in-progress-transactions mechanism), consistent with this domain's already-stated low-write-volume profile (database-design.md).

## Edge Case: Promotion + Coupon — Discount stacking on the same quote

- **What happens:** A quote's order is simultaneously eligible for an active `PromotionCampaign` discount and a validated `Coupon` discount (or more than one applicable campaign) — risk of summing multiple discounts into an unintended total.
- **Why it happens:** `PricingQuote` is the single point where Coupon validation, Promotion lookup, and base price converge (ddd-model.md's Cross-Aggregate Interaction) — nothing structurally stops naively adding every applicable discount.
- **Solutions available (2):** Additive stacking (sum all applicable discounts) · Best-discount-wins, no stacking (single largest discount applied, others ignored).
- **Decision:**
  - Chosen: Best-discount-wins, no stacking — already resolved in ddd-model.md's Modeling Decision #3 ("given all campaigns active for a SKU at quote time, `PricingQuote` picks the single largest discount"), applied uniformly wherever a coupon discount and one or more promotion discounts could both apply to the same quote.
  - Why: A single deterministic winning discount avoids unbounded margin erosion from combining discount sources and keeps quote computation a pure "all applicable discounts in, one number out" function.
  - Trade-off accepted: Customers eligible for multiple discounts only ever receive the best one, never a combined saving — a constraint already accepted upstream, not re-argued here.
