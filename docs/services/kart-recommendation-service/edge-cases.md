---
doc_type: edge-cases
service: kart-recommendation-service
status: approved
generated_by: edge-case-analyzer-agent
source: docs/services/kart-recommendation-service/requirement-spec.md
---

# Edge Cases: kart-recommendation-service

## Edge Case: Cold-start user with no purchase or clickstream history

- **What happens:** `GET /recommendations/{userId}` is called for a user with zero `OrderDelivered` events and zero clickstream events on record — there is no signal to personalize from.
- **Why it happens:** the FR for personalization (requirement-spec §2, BRD §2.1 item 18) is built entirely from `OrderDelivered` and clickstream consumption; a brand-new or inactive user has produced neither.
- **Solutions available (3):** non-personalized fallback (globally popular/trending items) · empty result set with a distinct "insufficient data" response · seed from a lightweight proxy signal (e.g. current session's in-flight clickstream, or category affinity from User Service profile data)
- **Decision (3-5 bullets max):**
  - Chosen: non-personalized fallback (globally popular/trending items)
  - Why: keeps `GET /recommendations/{userId}` always returning content within the read-path latency NFR (P95 < 150ms, requirement-spec §3) instead of forcing every caller to special-case an empty/error response
  - Trade-off accepted: the fallback is not actually personalized, so the BRD's own definition of this service ("Personalization") isn't met until a user accumulates signal; the exact signal-volume threshold for "enough to personalize" is part of the algorithm design and is non-blocking, carried forward to the Architecture/DDD Agents alongside requirement-spec Open Question 2 (recommendation algorithm/model)

## Edge Case: Clickstream volume overwhelms ingestion

- **What happens:** clickstream events (views, clicks, searches) arrive at an order-of-magnitude higher rate than transactional events like `OrderDelivered`, and can burst past the consumer's steady-state throughput, building consumer lag or broker backpressure.
- **Why it happens:** requirement-spec §3 (Throughput row) notes clickstream volume scales with traffic, not conversions, and BRD §15 explicitly groups Recommendation with Analytics as needing "high-throughput partitioned consumption" — this is a firehose input, not a trickle, unlike the one-event-per-order `OrderDelivered` path.
- **Solutions available (3):** Kafka topic partitioned by `userId` with consumer-group autoscaling on partition lag (per BRD §15 + `kart-conventions.md` topic naming) · sampling/down-sampling clickstream at the producer before publish · buffering into async micro-batches instead of per-event processing
- **Decision (3-5 bullets max):**
  - Chosen: Kafka topic partitioned by `userId`, consumer group autoscaling on partition lag
  - Why: BRD §15 already designs Recommendation onto Kafka for exactly this reason (replay + high-throughput partitioned consumption); per-user partitioning also preserves ordered per-user signal history, which matters for personalization
  - Trade-off accepted: sampling/down-sampling would be cheaper to run but was not chosen — it loses precision in the behavioral signal, and the BRD states no loss-tolerance for this data (unlike its explicit staleness tolerance for Search, BRD §2.2)

## Edge Case: Stale recommendations after a product goes out of stock or is discontinued

- **What happens:** a served recommendation includes a product that is now out of stock or discontinued, because the recommendation read model was computed before the product's status changed.
- **Why it happens:** requirement-spec §5 shows Recommendation's consumed inputs are `OrderDelivered`, `ProductCreated` (seeding only, per ADR-0013 (`docs/adr/0013-recommendation-productcreated-consumption.md`)), and clickstream events — none of which is `ProductPriceChanged` or any product-delisted/discontinued event — and requirement-spec §3 gives Recommendation's consistency as Eventual with no stated staleness bound, so there is no defined mechanism to invalidate a recommendation once the underlying product becomes unsellable.
- **Solutions available (3):** consume `ProductPriceChanged`/catalog events defensively as an availability filter joined into the read model · filter recommendations against a live inventory/catalog check synchronously at request time before returning · accept staleness and rely on a periodic full-recompute batch job (no cadence given by the BRD)
- **Decision (3-5 bullets max):**
  - Chosen: filter recommendations against a live inventory/catalog check synchronously at request time
  - Why: guarantees the response never surfaces an unsellable product regardless of how stale the underlying recommendation signal is, without requiring Recommendation to take on a broader catalog-event consumption contract than the one already confirmed (`ProductCreated`, for seeding only — not an availability signal)
  - Trade-off accepted: adds a synchronous dependency to the read path, risking the P95 < 150ms / P99 < 400ms NFR (requirement-spec §3) if the availability check is slow — non-blocking, flagged for Architecture Agent validation of the actual call latency, not a gap in this decision itself

## Edge Case: Recommendation model/algorithm drift goes undetected

- **What happens:** the underlying "customers also bought" logic degrades over time (stale trends, systematic bias for a user segment, irrelevance) with no signal that anything has changed.
- **Why it happens:** requirement-spec §2 and Open Question 2 (non-blocking, carried to Architecture/DDD Agents) note the BRD names the feature but specifies no algorithm, model, or scoring method — with no defined baseline or target metric, there is nothing stated to measure live output against.
- **Solutions available (3):** offline evaluation harness comparing output against held-out purchase/clickstream data on a schedule · online A/B testing with click-through/conversion metrics fed back through Analytics (BRD §10: Analytics is fan-in for all events, ADR-0004) · no automated detection, manual periodic review
- **Decision (3-5 bullets max):**
  - Chosen: online monitoring via Analytics fan-in — click-through/conversion metrics on served recommendations, measured against Analytics' existing full event ingestion (ADR-0004), not an offline evaluation harness
  - Why: this is algorithm-agnostic (it measures user reaction to whatever gets recommended, regardless of which model/algorithm the Architecture/DDD Agents eventually choose per Open Question 2) and requires no new infrastructure — Analytics already ingests every platform event, so it is the natural place to compute these metrics rather than Recommendation building its own eval pipeline; an offline held-out-data harness cannot be designed yet since the BRD gives no target metric or quality bar and no algorithm has been chosen to evaluate
  - Trade-off accepted: detection is reactive (drift is observed after it has already affected users), not preventive — there is no pre-deployment offline check before a model/algorithm change ships; this is accepted because it can be added later, once the Architecture/DDD Agents pick a concrete algorithm and quality bar (Open Question 2), without changing anything decided here
  - Non-blocking follow-on: the choice of *which* click-through/conversion metric and what threshold constitutes "drift" is a product call that depends on the algorithm chosen — carried forward to the **Architecture/DDD Agents** alongside Open Question 2, not resolved here

## Edge Case: Newly catalogued products are unrecommendable until seeded from `ProductCreated`

- **What happens:** a product with zero purchase (`OrderDelivered`) and zero clickstream history — because it was just added to the catalog — cannot be personalized into any user's recommendations, and also cannot appear in the non-personalized fallback (globally popular/trending items, per the Cold-start User decision above), because that fallback is itself computed from historical purchase/clickstream aggregation the new product hasn't had time to accumulate.
- **Why it happens:** BRD §10's Event Catalog lists `ProductCreated`'s consumers as "Search, Recommendation, Analytics," but BRD §5.4's condensed row for Recommendation had named only `OrderDelivered` and clickstream events as inputs — omitting `ProductCreated` — the same §5.4/§10 inconsistency shape ADR-0005 resolved for `OrderDelivered`/`OrderCompleted`.
- **Solutions available (3):** consume `ProductCreated` and seed new products into the fallback/trending pool with a neutral default score until real purchase/clickstream signal accumulates · treat `ProductCreated` as out of scope and accept that new products stay invisible to Recommendation until they earn signal some other way (e.g. a Search-driven discovery path) · defer to the Event Design Agent to confirm scope
- **Decision (3-5 bullets max):**
  - Chosen: consume `ProductCreated` and seed new products into the fallback/trending pool with a neutral default score
  - Why: resolved by ADR-0013 (`docs/adr/0013-recommendation-productcreated-consumption.md`), which settles the underlying §5.4/§10 inconsistency in favor of §10's Event Catalog (the platform's authoritative event catalog) over §5.4's explicitly "condensed" summary — Recommendation does consume `ProductCreated`, and seeding the fallback pool is the only one of the three options that actually fixes the new-product-invisibility problem rather than accepting or merely deferring it
  - Trade-off accepted: a new product's fallback score is a placeholder (not evidence of real popularity), so it may be over- or under-exposed relative to its eventual true demand until enough `OrderDelivered`/clickstream signal accumulates to replace the neutral default — accepted because the alternative (indefinite invisibility) directly contradicts the BRD's stated fallback approach for cold-start visibility

## Edge Case: Duplicate or redelivered `OrderDelivered` events double-count purchase signal

- **What happens:** Order Service retries delivery of `OrderDelivered` (up to its confirmed 3x tier before landing in `order.dlq`), or a Recommendation consumer-group rebalance replays events from the last committed offset, and Recommendation processes the same `orderId` more than once — inflating that single purchase's weight in co-occurrence/collaborative-filtering signal for the user.
- **Why it happens:** requirement-spec §3 (Reliability row) now states `OrderDelivered` consumption is at-least-once with a confirmed 3x retry/`order.dlq` tier (BRD §10, added by ADR-0005) and requires idempotent consumers — a guarantee that could not previously be designed against, since before ADR-0005 the event had no publisher or delivery tier stated anywhere. At-least-once delivery means Recommendation must treat duplicate/redelivered `OrderDelivered` events as expected, not exceptional.
- **Solutions available (3):** dedupe on `orderId` before updating signal (idempotency key, per the platform's idempotent-consumer default) · make the signal update itself idempotent (e.g. a set-based/upsert operation keyed by `orderId` rather than an incrementing counter) · accept the double-count risk and rely on Eventual consistency tolerance (requirement-spec §3) rather than deduping
- **Decision (3-5 bullets max):**
  - Chosen: dedupe on `orderId` before updating signal (idempotency key)
  - Why: requirement-spec §3 states idempotent consumers as the platform default for this input specifically, now that it is confirmed at-least-once — this satisfies that NFR directly and keeps the fix local to Recommendation's own consumer, rather than pushing dedup responsibility onto Order or tolerating skewed signal
  - Trade-off accepted: requires Recommendation to persist a processed-`orderId` record (or equivalent upsert semantics) it would not otherwise need — a small storage/complexity cost accepted in exchange for purchase-signal accuracy over the alternative of silently skewed recommendations
