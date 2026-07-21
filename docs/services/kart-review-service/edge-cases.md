---
doc_type: edge-cases
service: kart-review-service
status: pending-approval
generated_by: edge-case-analyzer-agent
source: docs/services/kart-review-service/requirement-spec.md
---

# Edge Cases: kart-review-service

## Edge Case: Fake/unverified review submission via `OrderDelivered` gating ambiguity

- **What happens:** A review is accepted for an order/SKU the submitting customer never actually purchased or received, or a review is accepted before the corresponding delivery signal has actually been processed.
- **Why it happens:** requirement-spec Open Question 2 — the BRD does not say whether consuming `OrderDelivered` is a hard eligibility gate on `POST /reviews` or merely triggers a "leave a review" prompt; combined with at-least-once, non-guaranteed-ordering delivery (requirement-spec §3, Reliability row), a gate implemented as "has an `OrderDelivered` event been seen for this order/sku" can race ahead of or behind the actual submission request.
- **Solutions available (3):** synchronous check against a materialized delivered-orders table before accepting the submission (hard gate) · optimistic accept + async verification with retroactive flag/takedown if no matching delivery is found · no purchase gating at all, relying solely on moderation (Open Question 1) to catch abuse after the fact.
- **Decision (3-5 bullets max):**
  - Chosen: Unresolved — escalated to requirement-spec Open Question 2.
  - Why: hard-gate vs. optimistic-accept vs. no-gate is a product/business risk-tolerance call (review authenticity vs. submission friction), not an engineering default.
  - Trade-off accepted: none accepted yet — deferred pending human decision on Open Question 2 before the Architecture Agent designs the submission flow.

## Edge Case: Moderation queue backlog delaying or blocking legitimate reviews

- **What happens:** If moderation is human-review-queue based, a backlog delays legitimate reviews from ever becoming visible; if automated, a false positive holds or rejects a legitimate review with no stated override path.
- **Why it happens:** requirement-spec §2 (Functional Requirements) and Open Question 1 — "moderation" is named as a primary responsibility (BRD §2.1) with zero workflow detail: no automated-vs-human split, no SLA, no escalation path is stated anywhere in the BRD.
- **Solutions available (3):** fully automated content-safety filter (fast, cheap misses on nuanced abuse) · fully human-review queue (accurate, slow, doesn't scale to BRD's stated throughput targets) · hybrid — automated pre-screen with borderline cases routed to a human queue.
- **Decision (3-5 bullets max):**
  - Chosen: Unresolved — escalated to requirement-spec Open Question 1.
  - Why: the acceptable false-positive/false-negative rate and any human-review staffing commitment is a business call, not something inferable from the BRD.
  - Trade-off accepted: none accepted yet — this and the pre/post-publish visibility question below must be resolved together before the Architecture Agent designs the moderation pipeline.

## Edge Case: Rating aggregate recompute race under concurrent submissions

- **What happens:** Two `ReviewSubmitted` events for the same SKU are processed concurrently (or one is redelivered) by the aggregate-recalc consumer, producing an `avg`/`count` that double-counts a review or drops one — a lost-update on the read-model aggregate.
- **Why it happens:** requirement-spec §4 (Domain Invariants) states the rating aggregate must reflect submitted reviews, but `ReviewSubmitted` is delivered at-least-once (requirement-spec §3, Reliability row) with no ordering guarantee per SKU across concurrent messages, and no idempotency key stated in the event payload (requirement-spec §2, §5: payload is only `orderId`, `sku`, `rating`).
- **Solutions available (3):** atomic increment on the read model (`$inc` on count, weighted running-average update) instead of read-modify-write · full recompute of the aggregate from the source-of-truth reviews table on every event, rather than incremental math · per-SKU partitioning/serialization so events for the same SKU are processed in order, one at a time.
- **Decision (3-5 bullets max):**
  - Chosen: Atomic incremental update (`$inc` + weighted average) at the consumer, deduplicated by event/message ID.
  - Why: avoids a full-table/full-history recompute cost on every single review submission, consistent with the platform's existing denormalized-read-model pattern (requirement-spec §5, BRD §6.2), while the dedup key absorbs at-least-once redelivery.
  - Trade-off accepted: requires the consumer to track processed event IDs (extra state) to prevent double-counting on redelivery — a full-recompute approach wouldn't need this, at the cost of recomputing from scratch every time.

## Edge Case: Abusive content published before or without moderation catching it

- **What happens:** Profane, harassing, or otherwise policy-violating review text becomes visible in the read model (and is fanned out via `ReviewSubmitted` to Product/Analytics) before, or without, being caught by moderation.
- **Why it happens:** requirement-spec §3 notes the BRD's Security table (§24) assigns no content-safety control to Review despite naming moderation a responsibility (BRD §2.1), and Open Question 1 leaves the moderation ruleset and automated-vs-human split entirely undefined — so there is no stated point in the flow where content is actually checked before exposure.
- **Solutions available (3):** pre-publish gate — hold the review out of the read model and out of `ReviewSubmitted` until moderation clears it · post-publish gate — expose immediately, retract/hide after a moderation flag · synchronous third-party content-moderation API call (e.g., toxicity/profanity classifier) as a blocking pre-check on `POST /reviews`.
- **Decision (3-5 bullets max):**
  - Chosen: Unresolved — escalated to requirement-spec Open Question 1.
  - Why: pre- vs. post-publish exposure is a risk/latency trade-off (window of exposure to abusive content vs. added submission latency) that depends on a moderation SLA the BRD never states.
  - Trade-off accepted: none accepted yet — this must be decided alongside the moderation-workflow question before the Architecture Agent designs the submission/publish path.
