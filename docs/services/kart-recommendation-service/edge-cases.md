---
doc_type: edge-cases
service: kart-recommendation-service
status: pending-approval
generated_by: edge-case-analyzer-agent
source: docs/services/kart-recommendation-service/requirement-spec.md
---

# Edge Cases: kart-recommendation-service

## Edge Case: Cold-start user with no purchase or clickstream history

- **What happens:** `GET /recommendations/{userId}` is called for a user with zero `OrderCompleted` events and zero clickstream events on record — there is no signal to personalize from.
- **Why it happens:** the FR for personalization (requirement-spec §2, BRD §2.1 item 18) is built entirely from `OrderCompleted` and clickstream consumption; a brand-new or inactive user has produced neither.
- **Solutions available (3):** non-personalized fallback (globally popular/trending items) · empty result set with a distinct "insufficient data" response · seed from a lightweight proxy signal (e.g. current session's in-flight clickstream, or category affinity from User Service profile data)
- **Decision (3-5 bullets max):**
  - Chosen: non-personalized fallback (globally popular/trending items)
  - Why: keeps `GET /recommendations/{userId}` always returning content within the read-path latency NFR (P95 < 150ms, requirement-spec §3) instead of forcing every caller to special-case an empty/error response
  - Trade-off accepted: the fallback is not actually personalized, so the BRD's own definition of this service ("Personalization") isn't met until a user accumulates signal; the signal-volume threshold for "enough to personalize" is unresolved (requirement-spec Open Question 6)

## Edge Case: Clickstream volume overwhelms ingestion

- **What happens:** clickstream events (views, clicks, searches) arrive at an order-of-magnitude higher rate than transactional events like `OrderCompleted`, and can burst past the consumer's steady-state throughput, building consumer lag or broker backpressure.
- **Why it happens:** requirement-spec §3 (Throughput row) notes clickstream volume scales with traffic, not conversions, and BRD §15 explicitly groups Recommendation with Analytics as needing "high-throughput partitioned consumption" — this is a firehose input, not a trickle, unlike the one-event-per-order `OrderCompleted` path.
- **Solutions available (3):** Kafka topic partitioned by `userId` with consumer-group autoscaling on partition lag (per BRD §15 + `kart-conventions.md` topic naming) · sampling/down-sampling clickstream at the producer before publish · buffering into async micro-batches instead of per-event processing
- **Decision (3-5 bullets max):**
  - Chosen: Kafka topic partitioned by `userId`, consumer group autoscaling on partition lag
  - Why: BRD §15 already designs Recommendation onto Kafka for exactly this reason (replay + high-throughput partitioned consumption); per-user partitioning also preserves ordered per-user signal history, which matters for personalization
  - Trade-off accepted: sampling/down-sampling would be cheaper to run but was not chosen — it loses precision in the behavioral signal, and the BRD states no loss-tolerance for this data (unlike its explicit staleness tolerance for Search, BRD §2.2)

## Edge Case: Stale recommendations after a product goes out of stock or is discontinued

- **What happens:** a served recommendation includes a product that is now out of stock or discontinued, because the recommendation read model was computed before the product's status changed.
- **Why it happens:** requirement-spec §5 shows Recommendation consumes only `OrderCompleted` and clickstream events — no `ProductPriceChanged` or any product-delisted/discontinued event — and requirement-spec §3 gives Recommendation's consistency as Eventual with no stated staleness bound, so there is no defined mechanism to invalidate a recommendation once the underlying product becomes unsellable.
- **Solutions available (3):** consume `ProductPriceChanged`/catalog events defensively as an availability filter joined into the read model · filter recommendations against a live inventory/catalog check synchronously at request time before returning · accept staleness and rely on a periodic full-recompute batch job (no cadence given by the BRD)
- **Decision (3-5 bullets max):**
  - Chosen: filter recommendations against a live inventory/catalog check synchronously at request time
  - Why: guarantees the response never surfaces an unsellable product regardless of how stale the underlying recommendation signal is, without requiring Recommendation to take on a catalog-event consumption contract it currently has no BRD basis for
  - Trade-off accepted: adds a synchronous dependency to the read path, risking the P95 < 150ms / P99 < 400ms NFR (requirement-spec §3) if the availability check is slow — flagged for Architecture Agent validation, not fully resolved here

## Edge Case: Recommendation model/algorithm drift goes undetected

- **What happens:** the underlying "customers also bought" logic degrades over time (stale trends, systematic bias for a user segment, irrelevance) with no signal that anything has changed.
- **Why it happens:** requirement-spec §2 and Open Question 3 note the BRD names the feature but specifies no algorithm, model, or scoring method — with no defined baseline or target metric, there is nothing stated to measure live output against.
- **Solutions available (3):** offline evaluation harness comparing output against held-out purchase/clickstream data on a schedule · online A/B testing with click-through/conversion metrics fed back through Analytics (BRD §10: Analytics is fan-in for all events) · no automated detection, manual periodic review
- **Decision (3-5 bullets max):**
  - Chosen: unresolved — escalate
  - Why: this is a business/product call (what metric defines "good" recommendations, what quality bar justifies an eval harness vs. Analytics-based A/B testing) as much as an engineering one, and the BRD gives no algorithm, target metric, or quality bar to design any of the three options against
  - Trade-off accepted: none picked; deferred to a human decision alongside Open Question 3 (recommendation algorithm choice)

## Edge Case: `OrderCompleted` has no publisher, so purchase signal never arrives

- **What happens:** Recommendation is specified to consume `OrderCompleted` (requirement-spec §2/§5) to build purchase-based signal, but no service publishes an event by that name anywhere in the BRD's Event Catalog. If never reconciled, Recommendation permanently receives zero purchase signal, silently — not a transient failure, a structural one.
- **Why it happens:** BRD §5.4 (per-service condensed table) and BRD §10 (the Event Catalog, the BRD's own source of truth for events) disagree — Order Service's §10 entries are `OrderCreated`, `OrderConfirmed`, `OrderCancelled` only, none named `OrderCompleted`.
- **Solutions available (3):** confirm `OrderCompleted` is an alias for an existing terminal event (`OrderConfirmed`, or the `OrderDelivered` event Review already consumes per §5.4) and subscribe to that instead · add `OrderCompleted` as a genuinely new Event Catalog entry, published by Order Service at the appropriate lifecycle point · treat purchase-based signal as out of scope until resolved, relying on clickstream-only recommendations in the interim
- **Decision (3-5 bullets max):**
  - Chosen: unresolved — escalate to Event Design Agent / human sign-off
  - Why: this is not an engineering trade-off but a factual gap in the BRD (a named event with no publisher); picking an architecture pattern here would just paper over which event is actually correct
  - Trade-off accepted: none — flagged as blocking-adjacent, since it determines whether Recommendation's core personalization input (purchase history) exists at all (requirement-spec Open Question 1)
