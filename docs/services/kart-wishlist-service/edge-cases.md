---
doc_type: edge-cases
service: kart-wishlist-service
status: approved
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

## Edge Case: Price Rebound During the Batching/Digest Window

- **What happens:** A price drop is detected and queued for per-user digest delivery under the batching window chosen as this file's own Alert Storm mitigation; before that window elapses and the notification actually sends, the price rebounds — either back to/above its pre-drop level, or drops further and then partially recovers — so the notification the user eventually receives cites an `oldPrice`/`newPrice` pair that is no longer true at delivery time.
- **Why it happens:** The domain invariant that `WishlistPriceAlertTriggered` must reflect the actual current price "at trigger time, not a stale cached price" (requirement-spec §4) only constrains the moment of trigger/publish; it says nothing about the gap between trigger and actual delivery to the user. That gap did not exist as a distinct race until this file's own "Alert Storm on Sitewide Price Drop" edge case introduced a per-user batching/digest window as the chosen mitigation — the batching window itself is what creates the race between a price that was true when captured and a price that may no longer be true by the time the digest is delivered. This is distinct from "Duplicate Alert Delivery from At-Least-Once Redelivery" above: that edge case is about the same event being redelivered and reprocessed; this one is about a single, correctly-processed alert going stale between trigger and delivery purely because of the batching delay.
- **Solutions available (3):** re-check the current price against the latest known price state immediately before digest send, and suppress the alert if the price has rebounded to/above the baseline it was triggered on · re-check at send time and, if rebounded, still send the digest but with corrected current-price content rather than the originally captured `oldPrice`/`newPrice` · do nothing — accept the batching window's inherent staleness risk as a known consequence of the Alert Storm decision, and deliver the digest with whatever price was true at trigger time regardless of what happens before delivery.
- **Decision (3-5 bullets max):**
  - Chosen: unresolved — escalate.
  - Why: whether a stale-by-delivery alert should be suppressed, corrected, or delivered as originally triggered is a product decision about what users expect from a "price-drop alert" (accuracy vs. simplicity vs. the added latency/complexity of a pre-send re-check) — not an engineering default this agent can pick, and the requirement-spec's trigger-time invariant (§4) does not extend to cover delivery-time accuracy.
  - Trade-off accepted: none picked — flagged for human resolution before the Architecture Agent designs the digest-send path, since the answer determines whether a price re-check needs to be part of that path at all, and how it should be implemented if so.

## Edge Case: Wishlist Entry Added After the Price Drop Already Happened

- **What happens:** A user adds a product to their wishlist after a `ProductPriceChanged` event for that product has already fired and already been processed for every user who had it wishlisted at that time. The newly-added entry did not exist when the event fired, so it is unclear whether this user should receive a retroactive alert for a drop that already happened, or whether their entry only starts reacting to price changes from the moment it is added, forward.
- **Why it happens:** The Price-Drop Alerts FR (requirement-spec §2) states only that Wishlist "consumes `ProductPriceChanged` to detect price movement on wishlisted products" — an event-driven, forward-looking consumption model with no stated temporal scope. Neither this FR nor any domain invariant in §4 defines what a wishlist entry's price baseline is at add-time, or whether Wishlist should look backward at prior `ProductPriceChanged` events for a product once a new entry starts watching it. This is a real product/UX question the BRD does not address at any level.
- **Solutions available (3):** no backfill — the entry's baseline is the price at add-time; only `ProductPriceChanged` events after that timestamp are evaluated for this user/SKU, matching the FR's literal forward-consumption model · retroactive backfill — at add-time, compare the current price against a reference price (e.g., the product's price immediately before its most recent drop) and immediately fire `WishlistPriceAlertTriggered` if the product is already discounted relative to that reference · read-time-only surfacing — show the product's current discount as UI state at the moment of add (e.g., an "already on sale" badge) without publishing a retroactive alert event at all.
- **Decision (3-5 bullets max):**
  - Chosen: unresolved — escalate.
  - Why: this is a genuine product/UX call about what users expect when they wishlist something already on sale — over-notifying (backfill) risks alert fatigue and inflates alert volume in a way the "Alert Storm" mitigation above wasn't sized for, while under-notifying (no backfill) risks a user missing a live discount the platform already knows about; the BRD and requirement-spec are silent on baseline-price semantics at add-time, so neither reading is a defensible engineering default.
  - Trade-off accepted: none picked — flagged for human resolution before the Architecture/DDD Agent stages model what a wishlist entry actually stores (e.g., whether a "price at add-time" needs to be a captured field at all).
