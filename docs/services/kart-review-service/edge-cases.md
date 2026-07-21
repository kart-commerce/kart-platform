---
doc_type: edge-cases
service: kart-review-service
status: approved
generated_by: edge-case-analyzer-agent
source: docs/services/kart-review-service/requirement-spec.md
---

# Edge Cases: kart-review-service

## Edge Case: Fake/unverified review submission via `OrderDelivered` gating

- **What happens:** A review is accepted for an order/SKU the submitting customer never actually purchased or received, or a review is accepted before the corresponding delivery signal has actually been processed.
- **Why it happens:** at-least-once, non-guaranteed-ordering delivery of `OrderDelivered` (requirement-spec §3, Reliability row) means a gate implemented as "has an `OrderDelivered` event been seen for this order/sku" can race ahead of or behind the actual submission request.
- **Solutions available (3):** synchronous check against a materialized delivered-orders table before accepting the submission (hard gate) · optimistic accept + async verification with retroactive flag/takedown if no matching delivery is found · no purchase gating at all, relying solely on moderation to catch abuse after the fact.
- **Decision (3-5 bullets max):**
  - Chosen: Hard gate — synchronous check against Review's own materialized record of consumed `OrderDelivered` events for `(customerId, orderId, sku)` before accepting `POST /reviews`; reject with a "no matching delivered order found" response if absent (requirement-spec §4, §6 Q2).
  - Why: review authenticity is a direct trust signal for the platform (BRD §2.1 names moderation a Review responsibility, implying content trust matters here), and a hard gate is the only option of the three that prevents a fake review from ever being accepted, rather than cleaning one up after the fact.
  - Trade-off accepted: a customer cannot submit a review until Review has actually processed the relevant `OrderDelivered` event, which is asynchronous relative to the customer's page visit — surfaced as a clear rejection-and-retry response rather than a silent failure, not solved by weakening the gate.

## Edge Case: Moderation queue backlog delaying or blocking legitimate reviews

- **What happens:** If moderation is human-review-queue based for every submission, a backlog delays legitimate reviews from ever becoming visible; if fully automated, a false positive holds or rejects a legitimate review with no override path.
- **Why it happens:** naive single-stage moderation designs apply the same (slow or error-prone) path to every submission regardless of risk.
- **Solutions available (3):** fully automated content-safety filter (fast, cheap misses on nuanced abuse) · fully human-review queue (accurate, slow, doesn't scale to BRD's stated throughput targets) · hybrid — automated pre-screen with borderline/flagged cases routed to a human queue.
- **Decision (3-5 bullets max):**
  - Chosen: Hybrid — automated profanity/spam/toxicity filter runs on every submission; content that clears auto-publishes immediately with no human step; only flagged content enters the human moderation queue (requirement-spec §2, §6 Q1).
  - Why: this bounds the backlog to the flagged minority instead of every submission, so the queue only ever grows with genuinely risky content, not overall submission volume — and gives the moderator an explicit accept/reject action (`PATCH /reviews/{id}/moderate`) as the override path a fully-automated design would lack.
  - Trade-off accepted: false positives from the automated filter still incur queue latency before becoming visible (no way to fully eliminate this without either fully-manual review, which doesn't scale, or fully-automated, which drops the override path) — deemed acceptable since it only affects the flagged minority.

## Edge Case: Rating aggregate recompute race under concurrent submissions

- **What happens:** Two `ReviewSubmitted` events for the same SKU are processed concurrently (or one is redelivered) by the aggregate-recalc consumer, producing an `avg`/`count` that double-counts a review or drops one — a lost-update on the read-model aggregate.
- **Why it happens:** requirement-spec §4 (Domain Invariants) states the rating aggregate must reflect submitted reviews, but `ReviewSubmitted` is delivered at-least-once (requirement-spec §3, Reliability row) with no ordering guarantee per SKU across concurrent messages.
- **Solutions available (3):** atomic increment on the read model (`$inc` on count, weighted running-average update) instead of read-modify-write · full recompute of the aggregate from the source-of-truth reviews table on every event, rather than incremental math · per-SKU partitioning/serialization so events for the same SKU are processed in order, one at a time.
- **Decision (3-5 bullets max):**
  - Chosen: Atomic incremental update (`$inc` + weighted average), deduplicated by the event's `reviewId` (requirement-spec §6 Q5 — payload now carries `reviewId`) at both Review's own canonical aggregate and Product's denormalized copy (see ADR-0014 (`docs/adr/0014-review-rating-aggregate-ownership.md`) — each maintains its own independent projection of the same event stream).
  - Why: avoids a full-table/full-history recompute cost on every single review submission, consistent with the platform's existing denormalized-read-model pattern (requirement-spec §5, BRD §6.2), while the `reviewId` dedup key absorbs at-least-once redelivery.
  - Trade-off accepted: requires each consumer to track processed `reviewId`s (extra state) to prevent double-counting on redelivery — a full-recompute approach wouldn't need this, at the cost of recomputing from scratch every time.

## Edge Case: Abusive content published before or without moderation catching it

- **What happens:** Profane, harassing, or otherwise policy-violating review text becomes visible in the read model (and is fanned out via `ReviewSubmitted` to Product/Analytics) before, or without, being caught by moderation.
- **Why it happens:** without a pre-publish gate, there is no point in the flow where content is actually checked before exposure.
- **Solutions available (3):** pre-publish gate — hold the review out of the read model and out of `ReviewSubmitted` until moderation clears it · post-publish gate — expose immediately, retract/hide after a moderation flag · synchronous third-party content-moderation API call (e.g., toxicity/profanity classifier) as a blocking pre-check on `POST /reviews`.
- **Decision (3-5 bullets max):**
  - Chosen: hybrid of options 1 and 3 — a synchronous automated classifier runs as a blocking pre-check on every `POST /reviews` (option 3); content it flags is held pre-publish (option 1, applied only to the flagged subset) until a human moderator decides; content it clears publishes immediately (requirement-spec §2, §6 Q1).
  - Why: this bounds the window of exposure to abusive content to zero for anything the automated filter catches, without imposing full pre-publish latency on the entire submission volume (the pure option-1 cost) or leaving a synchronous-only filter as the sole check (the pure option-3 risk of nuanced abuse it misses, now caught downstream by the human queue instead of shipping straight to the read model).
  - Trade-off accepted: content that legitimately violates policy but which the automated filter fails to flag can still reach the read model before any human ever reviews it — no purely automated pre-check achieves 100% recall; accepted as the standard limitation of any automated content-safety filter, mitigated by BRD's general moderation responsibility still allowing post-hoc takedown via the same `PATCH /reviews/{id}/moderate` action.

## Edge Case: Duplicate review submission for the same delivered order

- **What happens:** A customer's `POST /reviews` submission for the same delivered order/SKU is accepted twice — e.g., a double-click, or a client retry after a timeout with no acknowledgment received — producing two persisted reviews and two `ReviewSubmitted` events from what was intended as a single action. This is a submission-side race, distinct from the Rating aggregate recompute race edge case above, which concerns redelivery of an *already-accepted* `ReviewSubmitted` event, not a second genuine write at the API layer.
- **Why it happens:** a repeated HTTP request at the API layer is an undeduplicated distinct write, not an event redelivery, so the Reliability NFR's "idempotent consumers" clause (event-level) does not by itself protect the synchronous write path.
- **Solutions available (3):** client- or server-derived idempotency key on `POST /reviews` (e.g., from `customerId`+`orderId`+`sku`), deduplicated against the write model before insert · unique constraint on `(customerId, orderId, sku)` in the PostgreSQL write model, rejecting a second insert with a conflict response · no dedup at submission time, relying on moderation/manual cleanup after the fact.
- **Decision (3-5 bullets max):**
  - Chosen: both of the first two — an idempotency key on `POST /reviews` to collapse literal request retries, **and** the unique constraint on `(order_id, sku)` now adopted as a Domain Invariant (requirement-spec §4, §6 Q6) to enforce the one-review-per-order/SKU business rule. A customer wanting to change their opinion uses the edit path (`PATCH /reviews/{id}`, requirement-spec §4 edit window) instead of a second insert.
  - Why: the idempotency key handles the retry case cleanly regardless of business policy; the uniqueness constraint is now correct (not too strict) because the edit-window decision (requirement-spec §6 Q3) gives customers an explicit revision path, so "one review per order/SKU" and "customers can change their mind" are no longer in tension.
  - Trade-off accepted: none of substance — this was previously blocked only by the now-resolved question of whether revisions should be allowed at all; with that answered, both dedup mechanisms compose cleanly.

## Edge Case: Moderation-rejection racing an already-updated rating average

- **What happens:** A review could be provisionally counted into the rating aggregate before moderation has cleared it, then rejected — leaving the aggregate skewed by a review that was never supposed to count.
- **Why it happens:** this race exists only if the aggregate is updated at write-insert time regardless of moderation outcome, i.e. under a post-publish or no-gate moderation model.
- **Solutions available (3):** defer the aggregate update until moderation clears — i.e., adopt the pre-publish gate for flagged content · store raw sum and count so a moderation-rejection can atomically decrement `sum -= rating`, `count -= 1`, requiring a new moderation-outcome event · full recompute of the aggregate from the source-of-truth reviews table, filtered by moderation status, on every submission and rejection.
- **Decision (3-5 bullets max):**
  - Chosen: dissolved by construction — the chosen moderation model (Abusive-content edge case above, requirement-spec §2, §6 Q1) only ever fires `ReviewSubmitted` (and therefore only ever updates the aggregate) for content that is either auto-cleared or explicitly moderator-accepted. Flagged content that is later rejected was never published and never counted in the first place, so there is nothing to reverse.
  - Why: this is the same "defer the aggregate update until moderation clears" option already listed above, but scoped only to the flagged minority (per the hybrid moderation decision) rather than applied to every submission — getting the reversibility benefit without paying the full pre-publish-for-everyone latency cost.
  - Trade-off accepted: none — no reversible-aggregate storage or new moderation-outcome event is needed under this design, since the race this edge case describes cannot occur given the chosen publish-timing rule.
