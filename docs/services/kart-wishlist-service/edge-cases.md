---
doc_type: edge-cases
service: kart-wishlist-service
status: pending-approval
generated_by: edge-case-analyzer-agent
source: docs/services/kart-wishlist-service/requirement-spec.md
---

# Edge Cases: kart-wishlist-service

## Edge Case: Alert Storm on Sitewide Price Drop

- **What happens:** A sitewide sale or catalog-wide repricing drops the price of thousands of SKUs at once; every affected SKU is wishlisted by many users, so the fan-out of `WishlistPriceAlertTriggered` (and downstream notification sends) spikes far above normal volume in a short window.
- **Why it happens:** `ProductPriceChanged` is consumed per-SKU (requirement-spec §2, Price-Drop Alerts) with no batching — one price event can map to N users × M wishlisted SKUs, and a sale touches many SKUs simultaneously, multiplying fan-out the same way flash-sale traffic multiplies fan-out for other event consumers on this platform.
- **Solutions available (3):** per-user alert batching/digest (collapse multiple triggers into one outbound notification within a time window) · rate-limit outbound `WishlistPriceAlertTriggered` publication with a queue-depth-driven consumer autoscale (same HPA-on-queue-depth pattern used elsewhere on this platform) · defer alert fan-out to an async digest job decoupled from the triggering event entirely.
- **Decision (3-5 bullets max):**
  - Chosen: per-user alert batching/digest within a short window, backed by consumer autoscale on queue depth as a second line of defense.
  - Why: keeps alert latency reasonable for the common case (few drops) while bounding worst-case fan-out without requiring a redesign of the notification path.
  - Trade-off accepted: a user who wishlisted many sale items gets one grouped notification instead of N individual ones — acceptable since the BRD does not specify per-alert delivery granularity (requirement-spec §6, Q4).
  - Unresolved: the actual batching window (seconds vs. minutes vs. once-daily digest) is a product decision, not an engineering default — escalate to the Architecture Agent alongside requirement-spec Q4 (Notification consumption unconfirmed).

## Edge Case: Duplicate Alert Delivery from At-Least-Once Redelivery

- **What happens:** The same `ProductPriceChanged` message is delivered more than once for the same price change, causing `WishlistPriceAlertTriggered` to fire — and the user to be notified — twice for one actual price drop.
- **Why it happens:** RabbitMQ's at-least-once delivery guarantee (requirement-spec §3, Reliability row) means a consumer crash or nack-then-redeliver after processing but before ack replays the same event; the requirement-spec's domain invariant on idempotent alert publication (§4) exists precisely because the BRD does not state whether a redelivered event for an already-alerted price should be suppressed (requirement-spec §6, Q3).
- **Solutions available (3):** idempotency/dedup table keyed on `(userId, sku, priceObserved)` checked before publishing · consumer-side event-ID deduplication (dedupe on the inbound `ProductPriceChanged` message ID, same pattern this platform uses for other idempotent consumers) · outbox pattern on the publish side so `WishlistPriceAlertTriggered` itself is only ever emitted once per committed state transition.
- **Decision (3-5 bullets max):**
  - Chosen: dedup table keyed on `(userId, sku, priceObserved)` combined with the outbox pattern for publishing `WishlistPriceAlertTriggered`.
  - Why: matches the platform's existing Outbox-Poller-RabbitMQ pipeline (already used elsewhere in kart-platform) rather than introducing a one-off dedup mechanism, and directly satisfies the domain invariant that alert publication must be idempotent.
  - Trade-off accepted: requires a persisted dedup record per (user, sku, price) rather than pure event-ID dedup, which costs storage but survives the case where the *same* price is re-announced via a *different* message ID (e.g., a republish/backfill).

## Edge Case: Stale Wishlist Entry for a Discontinued Product

- **What happens:** A wishlisted product is discontinued or removed from the catalog, but the wishlist entry persists indefinitely and can still be evaluated against (nonexistent) future `ProductPriceChanged` events, or shown to the user as if still purchasable.
- **Why it happens:** The requirement-spec (§6, Q8, carried forward) notes the BRD states no event for product deletion/discontinuation that Wishlist consumes — only `ProductPriceChanged` — so there is no signal that would let Wishlist mark or prune an entry when the underlying product goes away.
- **Solutions available (3):** consume a broader Product lifecycle event if one is defined upstream (depends on the Architecture Agent resolving requirement-spec Q8) · periodic reconciliation job that queries Product Service for wishlisted SKUs still active and flags/removes the rest · leave stale entries as-is and surface staleness only at read time via a synchronous existence check against Product Service on `/wishlist` reads.
- **Decision (3-5 bullets max):**
  - Chosen: unresolved — escalate.
  - Why: the two real options (consume a not-yet-defined lifecycle event vs. a reconciliation job) both depend on a decision the BRD doesn't make (whether Product publishes any discontinuation/removal event at all), which is exactly requirement-spec Q8, carried to the Architecture/DDD Agent stage.
  - Trade-off accepted: none picked — flagging per this agent's escalation rule for a decision this spec cannot ground without an upstream contract that doesn't yet exist.

## Edge Case: Noise Alerts from Undefined Price-Drop Threshold

- **What happens:** Trivial price movements (e.g., a $0.01 rounding adjustment or currency-conversion jitter) trigger `WishlistPriceAlertTriggered` the same as a meaningful sale price, producing alerts users learn to ignore.
- **Why it happens:** Requirement-spec §6, Q2 notes the BRD defines no minimum threshold (absolute or percentage) for what counts as a "drop" — every `ProductPriceChanged` that reflects any decrease is a candidate trigger under the FR as literally stated (requirement-spec §2, Price-Drop Alerts).
- **Solutions available (2):** enforce a minimum percentage/absolute delta before evaluating a price change as alert-worthy · enforce a minimum delta *and* a per-(user, sku) cooldown window so a slow multi-step drop doesn't re-trigger repeatedly.
- **Decision (3-5 bullets max):**
  - Chosen: unresolved — escalate.
  - Why: the threshold value itself is a product/business call (what % drop is "worth" alerting a user), not an engineering default this agent can pick.
  - Trade-off accepted: none picked — flagged under requirement-spec Q2 for human resolution before the Architecture Agent designs around a specific number.
