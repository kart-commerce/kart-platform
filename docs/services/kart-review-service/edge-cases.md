---
doc_type: edge-cases
service: kart-review-service
status: approved
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

## Edge Case: Duplicate review submission for the same delivered order

- **What happens:** A customer's `POST /reviews` submission for the same delivered order/SKU is accepted twice — e.g., a double-click, or a client retry after a timeout with no acknowledgment received — producing two persisted reviews and two `ReviewSubmitted` events from what was intended as a single action. This is a submission-side race, distinct from the Rating aggregate recompute race edge case above, which concerns redelivery of an *already-accepted* `ReviewSubmitted` event, not a second genuine write at the API layer.
- **Why it happens:** two compounding gaps in the requirement-spec. (1) requirement-spec §5 (API Surface) states no idempotency key or request-dedup mechanism for `POST /reviews` itself — the Reliability NFR's "idempotent consumers" (§3) is explicitly scoped to `ReviewSubmitted` publication and `OrderDelivered` consumption (event-level), not to the synchronous HTTP write path, so a repeated HTTP request is an undeduplicated distinct write, not a redelivery. (2) requirement-spec §4 (Domain Invariants) states no invariant limiting a customer to one review per delivered order/SKU — the BRD is silent on this — so even setting the retry scenario aside, two genuinely separate submissions for the same order/SKU by the same customer are not rejected by any stated rule.
- **Solutions available (3):** client- or server-derived idempotency key on `POST /reviews` (e.g., from `customerId`+`orderId`+`sku`), deduplicated against the write model before insert · unique constraint on `(customerId, orderId, sku)` in the PostgreSQL write model, rejecting a second insert with a conflict response · no dedup at submission time, relying on moderation/manual cleanup after the fact.
- **Decision (3-5 bullets max):**
  - Chosen (partial, engineering default): adopt idempotency-key dedup for literal request retries (same client action replayed) — this is a defensible default regardless of business policy, since it only collapses duplicate *requests*, not duplicate *intentional* reviews.
  - Unresolved — escalated: whether a customer may submit more than one distinct review for the same delivered order/SKU at all is a business call the BRD does not make (no one-review-per-order invariant is stated anywhere in §4); this determines whether the unique-constraint option is correct or too strict — e.g., the business may intend to allow a revised review, which overlaps with but is not resolved by Open Question 3 (edit/delete window is unspecified).
  - Why: a retry-dedup mechanism is standard regardless of policy, but the correct write-model uniqueness constraint depends on a limit the BRD never states.
  - Trade-off accepted: none accepted yet for the uniqueness question — recommend raising as a new Open Question alongside #3 in requirement-spec.md before the Architecture Agent finalizes the write-model schema.

## Edge Case: Moderation-rejection racing an already-updated rating average

- **What happens:** A review is provisionally counted into the rating aggregate — via the atomic `$inc` + weighted-average mechanism chosen in the Rating aggregate recompute race edge case above, applied at `ReviewSubmitted` time — before moderation has cleared it. Moderation subsequently rejects or takes down the review, but the aggregate has no defined path to reverse the contribution it already applied, leaving the displayed rating permanently skewed by a review that was never supposed to count.
- **Why it happens:** requirement-spec §2 (FR) publishes `ReviewSubmitted` "on successful submission" — i.e., on write success, not on moderation clearance — so under a post-publish (or no-gate) moderation model, the already-chosen aggregate-update mechanism (atomic `$inc`, not a full recompute — see the Rating aggregate recompute race edge case's Decision) fires before moderation has run. That mechanism accumulates a running weighted average, which is not reversible without either storing raw sum/count separately or a full recompute, and no moderation-outcome event (e.g., a rejection/takedown event) exists anywhere in the API surface (§5) to even trigger a reversal. This is directly downstream of two still-open items: Open Question 1 (moderation workflow entirely unspecified) and the pre-vs-post-publish exposure decision escalated in the Abusive content published before/without moderation edge case above.
- **Solutions available (3):** defer the aggregate update until moderation clears — i.e., adopt the pre-publish gate option from the Abusive content edge case — which removes this race by construction, at the cost of the latency/exposure trade-off already escalated there · store raw sum and count (not just the running average) so a moderation-rejection can atomically decrement `sum -= rating`, `count -= 1` — requires a new moderation-outcome event, which is not in the current BRD/API surface and would need to be explicitly proposed as an addition, per platform convention for new events · full recompute of the aggregate from the source-of-truth reviews table, filtered by moderation status, triggered on submission and on rejection — naturally reversible, but reintroduces the full-recompute cost the Rating aggregate recompute race edge case's decision explicitly rejected.
- **Decision (3-5 bullets max):**
  - Chosen: Unresolved — escalated to requirement-spec Open Question 1, and coupled to the pre/post-publish decision escalated in the Abusive content edge case above.
  - Why: if pre-publish exposure wins, this edge case dissolves entirely (the aggregate never sees an unmoderated review); if post-publish or no-gate wins, a reversible-aggregate mechanism and a new moderation-outcome event become necessary. Which applies can't be decided independently of that still-open moderation-workflow/exposure call — this is a business/product risk-tolerance call, not an engineering default.
  - Trade-off accepted: none accepted yet — deferred pending resolution of Open Question 1 and the Abusive-content edge case's pre/post-publish decision; whichever way those resolve determines whether reversible-aggregate storage must be added to the Architecture Agent's design, and whether a new moderation-outcome event must be proposed to the platform's event catalog.
