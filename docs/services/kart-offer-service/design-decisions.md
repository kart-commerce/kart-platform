---
doc_type: design-decisions
service: kart-offer-service
status: approved
generated_by: design-decision-agent
source: docs/services/kart-offer-service/requirement-spec.md, docs/services/kart-offer-service/edge-cases.md, docs/services/kart-offer-service/database-design.md, docs/services/kart-offer-service/api-contract.yaml, docs/adr/0019-admin-promotion-campaign-management-category.md
---

# Design Decisions: kart-offer-service

Cross-cutting technology/design-pattern choices this service's requirement-spec.md and edge-cases.md force. Service boundaries, aggregate/domain model, and schema/table design are out of scope here (Architecture/DDD/Database Design Agents). This stage was skipped when this service was originally built out — architecture.md, ddd-model.md, database-design.md, event-contract.md, and api-contract.yaml already exist and are approved. This doc backfills the cross-cutting technology palette those docs already assume, generalizing decisions edge-cases.md made locally into named patterns rather than re-deriving them, and confirms (does not re-litigate) anything those later docs already settled.

## Decision: Caching Consistency Strategy for Promotion/Active-Campaign Reads

- **Requirement driving this:** BRD §16's Caching table, write-through mandated specifically for "Promotion/active-campaign flags... since staleness there is unacceptable for pricing"; requirement-spec §3 Consistency row (as corrected); edge-cases.md's "Stale Redis cache vs. an actively-changing campaign" (which identified and resolved a direct contradiction between requirement-spec §3's original wording and BRD §16).
- **Options considered (3):** TTL-only cache-aside expiry · Event-driven invalidation (Offer self-consumes its own `PromotionActivated`/`PromotionDeactivated` to bust the affected Redis key) · Write-through cache (Redis and PostgreSQL updated synchronously in the same operation).
- **Decision:**
  - Chosen: Write-through — generalizes the fix already made in edge-cases.md into this service's caching-strategy default for this one field class.
  - Why: BRD §16 leaves no discretion for promotion/active-campaign flags specifically; matches kart-product-service/edge-cases.md's identical write-through call for the identical BRD §16 clause on pricing-sensitive fields — Offer should not diverge from that platform precedent for the same rule.
  - Trade-off accepted: added write-path latency on every write to `promotion_campaigns` (Redis and Postgres committed together) versus the lower-latency event-driven/TTL-only alternatives — accepted because BRD §16 treats this staleness as categorically unacceptable, not a latency/complexity trade left open to this service.

## Decision: Concurrency Control for the Coupon Aggregate (Redemption, Cap Enforcement, Validity Window, Admin Deactivation)

- **Requirement driving this:** Domain Invariant "a coupon must never be redeemed twice for the same order" (requirement-spec §4); edge-cases.md's four related races — "Double-redemption for the same order," "Redemption-cap race," "Validity window expires while checkout is in flight," and "Admin deactivation races an in-flight validate→redeem sequence."
- **Options considered (3):** Pessimistic per-`coupon_code` row lock (`SELECT ... FOR UPDATE`), one lock acquired in the same transaction as the cap check, the redemption insert, the validity-window re-check, and any competing deactivation write · Optimistic check-then-insert with retry-on-conflict · Full serializable transaction isolation.
- **Decision:**
  - Chosen: Pessimistic per-`coupon_code` row lock — a single concurrency-control mechanism reused across all four edge cases, not four separate ones; already resolved piecewise in edge-cases.md, generalized here as the Coupon aggregate's one stated concurrency pattern. The DB-level `UNIQUE (coupon_code, order_id)` constraint (database-design.md) is the complementary, storage-layer backstop for the same-order double-redemption case specifically, not a substitute for the lock.
  - Why: Coupon/Pricing/Promotion is an explicitly low-write-volume path (database-design.md: "writes only happen once per checkout"), so per-code lock contention is acceptable, and this mirrors the platform's existing oversell-prevention pattern requirement-spec §4 itself draws the analogy to.
  - Trade-off accepted: redemptions against the same code serialize — a single high-traffic flash-sale coupon becomes a throughput bottleneck under heavy concurrency; accepted given the stated write-volume profile, revisit only if that scenario materializes. This mechanism does not address two admin operators concurrently editing the *same* coupon/campaign's own fields (a different race than any edge-cases.md analyzed) — see Not Decided Here.

## Decision: Communication Style Per Interaction

- **Requirement driving this:** requirement-spec §5 API Surface (checkout-facing endpoints vs. admin-only write endpoints vs. published/consumed events); requirement-spec Q4 (Pricing↔Promotion integration contract).
- **Options considered (3):** Uniform synchronous REST for every interaction, including cross-service notifications to Analytics/Order · Uniform asynchronous messaging, including the checkout-path reads · Hybrid — synchronous REST for the checkout read path and the four admin-only write endpoints, asynchronous events for cross-service publication/consumption, and an in-process call for Pricing's own read of Promotion state.
- **Decision:**
  - Chosen: Hybrid — synchronous REST for `/coupons/validate`, `/pricing/quote`, `/promotions/active` (checkout read path) and for `POST /coupons`, `POST /coupons/{couponCode}/deactivate`, `POST /promotions`, `POST /promotions/{campaignId}/deactivate` (admin-only writes); asynchronous events for `CouponRedeemed`, `CouponRedemptionVoided`, `PriceQuoteIssued`, `PromotionActivated`, `PromotionDeactivated` (published) and `OrderCancelled`, `ProductPriceChanged` (consumed); in-process synchronous call for Pricing's own read of active `PromotionCampaign` state (same bounded context and repo, per ADR-0001) rather than a self-published/self-consumed event.
  - Why: the checkout read path's P95 < 150ms NFR (requirement-spec §3) forces a low-latency synchronous protocol; an event hop for Pricing↔Promotion would be unnecessary overhead for a same-transaction, same-service concern; Analytics/Order don't gate Offer's own response, so async fan-out there costs nothing against the latency budget that actually matters. This is the same shape already fixed in architecture.md's "Sync vs. Async Resolution" and Dependencies table — confirmed consistent here, not re-derived.
  - Trade-off accepted: none new — this decision codifies rather than changes the already-settled pattern, recorded here so the communication-style palette is explicit at this stage too, not only implicit in a later doc.

## Decision: Data Consistency Model for the Locally Materialized Product Price

- **Requirement driving this:** architecture.md's ruling-out of a synchronous fetch to Product at quote time (to hold the P95 < 150ms budget); edge-cases.md's "`ProductPriceChanged` arrives mid-quote-computation."
- **Options considered (3):** Rely on PostgreSQL row-level read-committed atomicity for the single-row read/write, no explicit lock · Stamp a `priceVersion` on the issued quote so a later-superseded quote is detectable · Synchronous fetch from Product at quote time (rejected — reintroduces the latency dependency architecture.md explicitly ruled out).
- **Decision:**
  - Chosen: Rely on PostgreSQL row-level atomicity for the read; treat the consumer-lag window between `ProductPriceChanged` consumption and a concurrent `/pricing/quote` read as correct-by-definition, not a defect — generalizes the fix already made in edge-cases.md.
  - Why: `PricingQuote`'s invariant (ddd-model.md) only requires the quote to reflect the product price "at the moment of quoting," and a quote is an immutable snapshot, never retroactively recomputed — whichever value a single-row atomic read observes satisfies the invariant by construction.
  - Trade-off accepted: a quote can be issued moments before a price change lands, leaving a soon-to-be-stale price live until the quote's 15-minute TTL expires (ddd-model.md Modeling Decision #2) — the pre-accepted cost of not synchronously fanning out to Product, not a new risk.

## Decision: PricingQuote Immutability & Expiry Mechanism

- **Requirement driving this:** ddd-model.md's `PricingQuote` invariants ("immutable once issued... never recomputed retroactively"; "an expired quote must be re-issued, not reused, at checkout"); edge-cases.md's "Expired `PricingQuote` reused at checkout."
- **Options considered (3):** Reject at consumption time — check `issuedAt + TTL` against current time when the quote is presented at checkout, return a specific "quote expired, re-quote required" error, no silent re-issue and no grace window · Silently re-issue a fresh quote server-side under the same `quoteId` · Accept it anyway within a small grace window past the nominal TTL.
- **Decision:**
  - Chosen: Reject at consumption time, explicit re-quote required — generalizes the fix already made in edge-cases.md.
  - Why: the only reading consistent with both stated invariants at once — silently re-issuing under the same `quoteId` would violate the "immutable once issued" invariant, and the "must be re-issued, not reused" wording leaves no discretion to honor an expired quote.
  - Trade-off accepted: a customer whose checkout crosses the 15-minute TTL boundary must re-request a quote and may see a different price/promotion than the one that expired — the intended effect of the TTL, not a defect; a UX-level grace window remains a possible future ddd-model.md revision, not assumed here.

## Decision: Retry/DLQ Tiering for Published Events

- **Requirement driving this:** requirement-spec §3 NFR Retry/DLQ row (`CouponRedeemed`: 2x retry, `coupon.dlq`, BRD §10); requirement-spec Open Question #2; event-contract.md's "Requirement-Spec Q2 Resolution."
- **Options considered (2):** Keep the BRD's 2x/no-paging tier for all of Coupon/Pricing/Promotion's published events · Promote to the `Payment*` 5x/paged-on-call tier.
- **Decision:**
  - Chosen: Keep the 2x/no-paging tier for `CouponRedeemed`, `CouponRedemptionVoided`, `PriceQuoteIssued`, `PromotionActivated`, and `PromotionDeactivated` — already settled in event-contract.md, confirmed consistent here as this stage's own retry-policy decision, not re-litigated.
  - Why: the double-charge risk the `Payment*` tier exists to guard against is owned by Order/Payment's own Saga idempotency (BRD §12), not by Coupon/Pricing/Promotion; a lost/retried event here degrades to a temporarily inaccurate Analytics count or a delayed Order-side record, the same risk class as `ReviewSubmitted` (also 2x) — not the money-critical class the elevated tier exists for.
  - Trade-off accepted: none new beyond what event-contract.md already accepted; recorded here so this doc's own retry-policy decision matches, per the reusable event-standards' "retry budget scales with criticality" rule, rather than leaving the connection implicit.

## Decision: Idempotency Mechanism for Admin-Invoked Coupon/Promotion Write Endpoints

- **Requirement driving this:** requirement-spec §2/§5/§6 item 6 (`POST /coupons`, `POST /coupons/{couponCode}/deactivate`, `POST /promotions`, `POST /promotions/{campaignId}/deactivate` — internal/admin-only, per [ADR-0010](../../adr/0010-admin-service-scope-and-integration.md)'s integration pattern); the reusable API standard's `Idempotency-Key` mandate for non-retry-safe writes; `api-contract.yaml`'s existing `/v1/coupons/redeem` endpoint, which already requires `Idempotency-Key` as a directly comparable precedent within this same service.
- **Options considered (2):** Require an `Idempotency-Key` header on all four admin-write endpoints, deduplicated the same way `/v1/coupons/redeem` already is · No idempotency requirement — rely solely on the `coupon_code`/`campaign_id` primary-key constraint to reject an exact retry as a raw conflict.
- **Decision:**
  - Chosen: Require `Idempotency-Key`, consistent with the pattern `api-contract.yaml` already applies to `/v1/coupons/redeem` within this service, and with kart-admin-service/design-decisions.md's own already-fixed commitment to forward such a key on every retry of its outbound calls to owning services (Offer included).
  - Why: a retried admin creation/deactivation call under transient network failure should surface as an idempotent no-op, not a raw primary-key-conflict error to the calling admin operator; keeps Offer's write-API idempotency story uniform across all of its write endpoints instead of ad hoc per-endpoint.
  - Trade-off accepted: this decision is grounded in cross-service consistency with Admin's own already-stated expectation, not a requirement Offer's own spec states outright for these four endpoints specifically. **Since resolved:** `api-contract.yaml` now specifies all four endpoints (plus two admin-read endpoints so a caller can obtain the `version` an `If-Match` precondition needs) with `Idempotency-Key` wired in exactly as described here — no longer a carried-forward gap.

## Not Decided Here

- **Serialization format for events/payloads** — neither requirement-spec.md nor edge-cases.md states a service-specific forcing requirement beyond the platform's existing event-schema-versioning default (`event-standards.md`); no divergence reason exists, so nothing to add here.
- **Circuit breaker / bulkhead resilience patterns on outbound calls** — architecture.md states plainly that Offer "has no synchronous outbound dependency on any other service": all three synchronous inbound calls originate from the client-facing gateway/checkout flow, and both event dependencies (Product, Order) are async and non-blocking. There is no outbound call to wrap a breaker around, unlike Order/Payment/Admin's outbound-heavy profiles — revisit only if Offer gains a genuine synchronous outbound dependency.
- **Optimistic concurrency (version/ETag) for two admin operators concurrently editing the same `Coupon`/`PromotionCampaign` record — since resolved.** Was flagged here as "a genuine open item for whichever doc next revisits Offer's admin-write endpoints." That revisit happened this pass: `database-design.md`'s "Admin Write-Path Mechanics" adds a `version` column to both `coupons` and `promotion_campaigns`, and `api-contract.yaml`'s deactivate endpoints require an `If-Match: <version>` header, satisfying `kart-admin-service/design-decisions.md`'s cross-service expectation directly.
- **`PriceQuoteIssued`/`PromotionActivated`/`PromotionDeactivated` confirmed consumer (requirement-spec Q5)** — already fully resolved (Analytics is the sole confirmed consumer; all three published for audit/analytics/future-extension use, no other confirmed consumer today) across requirement-spec.md §6.5, architecture.md, ddd-model.md, and event-contract.md. No design-pattern choice remains open here; the Communication Style and Retry/DLQ decisions above are already written consistent with that resolution, not contingent on it changing.
- **Aggregate boundaries, the three-aggregate model, and concrete schema/table shapes** — already decided (ddd-model.md, database-design.md); this stage does not re-decide them, only supplies the technology/pattern layer they already assume.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner
- [x] Technology/pattern choices approved
- [x] Approved to proceed to Architecture Agent (informational here — architecture.md for this service is already approved; this gate documents that this stage's own catalogue has been reviewed, not that Architecture is re-run)
