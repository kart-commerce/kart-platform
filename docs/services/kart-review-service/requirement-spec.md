---
doc_type: requirement-spec
service: kart-review-service
status: pending-approval
generated_by: requirement-agent
source: docs/requirements/kart-requirements.md
---

# Requirement Spec: kart-review-service

## 1. Scope

Covers a single BRD service, **Review Service** (BRD §2.1, item 14): "Ratings, reviews, moderation." No merge with another BRD service is indicated, and no ADR exists proposing one — unlike Offer (see [kart-offer-service](../kart-offer-service/requirement-spec.md)), this is a standalone bounded context.

The BRD's treatment of Review is minimal: one row in the module table (§2.1), one row in the condensed service table (§5.4), and one row in the Event Catalog (§10). It is not one of the domains called out in §2.2 ("Domain Rules That Force Hard Engineering Decisions"), is not mentioned in §24 (Security), and has no dedicated deep-dive section (unlike Order/Inventory/Payment in §5.1–5.3). This spec does not fill those gaps with invented detail — see Open Questions.

## 2. Functional Requirements

- Accept review submissions via `POST /reviews`, storing them in PostgreSQL as the write model, projected to a MongoDB read model (BRD §5.4: "PostgreSQL → MongoDB read"). The BRD does not specify whether `/reviews` also serves reads (e.g., `GET /reviews?sku=...`), or whether reads are served by a different endpoint/service — see Open Questions.
- Publish `ReviewSubmitted` on successful submission, carrying `orderId`, `sku`, `rating` (BRD §10). Note the payload does not include a review identifier, the submitting user, or the review's free-text content — see Open Questions.
- Consume `OrderDelivered` (BRD §5.4). The BRD states this as a consumed event but does not describe what Review does with it (e.g., gate eligibility to submit, or merely trigger a "leave a review" prompt) — see Open Questions.
- Ratings and reviews are Review's stated primary responsibility (BRD §2.1, item 14), but the Event Catalog (§10) lists **Product** — not Review — as the consumer that performs "rating recalc" from `ReviewSubmitted`, and §6.2's example `product_read_model` embeds the resulting `ratingSummary` on the Product read side, not a Review-owned collection. Whether Review computes and owns the canonical rating aggregate (with Product only mirroring a denormalized copy) or Product is the true owner of aggregate computation is not resolved by the BRD — see Open Questions.
- Moderation is named as a primary responsibility (BRD §2.1, item 14: "Ratings, reviews, **moderation**") but the BRD provides no further detail anywhere — no endpoint, no event, no ruleset, no automated-vs-human distinction. This spec does not invent a moderation workflow; it is carried to Open Questions as a blocking gap.

## 3. Non-Functional Requirements

Pulled from the BRD's global NFR table (§3); the BRD does not give Review a service-specific override (unlike, e.g., Order's 99.99% critical-path callout):

| Attribute | Target | Applies here because |
|---|---|---|
| Availability | 99.9% (secondary path — Review is not named in the Order Saga's critical path per §5.5, and BRD §3 reserves 99.99% for the order path only) | BRD does not call out Review specifically |
| Latency | P95 < 150ms, P99 < 400ms (read path); P95 < 300ms (write path, includes Outbox insert) | `/reviews` submission is a write; any read surface for displayed reviews/ratings would be a read-path consumer |
| Consistency | Eventual (MongoDB read projection), Strong (PostgreSQL write) | Matches the platform-wide CQRS boundary (BRD §7); the BRD states no Review-specific consistency requirement beyond this default |
| Reliability | At-least-once delivery + idempotent consumers | Applies to `ReviewSubmitted` publication and `OrderDelivered` consumption (BRD §3 Reliability row) |
| Retry/DLQ | `ReviewSubmitted`: 2x retry, `review.dlq` (BRD §10) | Same tier as `CouponRedeemed`/`ProductPriceChanged` — **not** the `Payment*` 5x/paged tier |

The BRD's Security table (§24) lists only platform-wide AuthN/AuthZ/encryption/rate-limiting controls; it assigns no content-safety or moderation-specific control to Review despite naming moderation as a responsibility (§2.1) — see Open Questions.

## 4. Domain Invariants

- `ReviewSubmitted` publication and `OrderDelivered` consumption must be idempotent under RabbitMQ's at-least-once delivery (BRD §3, Reliability row) — a redelivered event must not produce a duplicate review or double-count a rating.
- A displayed rating aggregate (`ratingSummary.avg`/`count`, per BRD §6.2's example) must reflect the set of submitted reviews for a SKU — inferred from the read-model example, though which service is accountable for keeping it correct is unresolved (see Functional Requirements and Open Questions).
- The BRD does not state that a review must correspond to a genuine, delivered order for that customer (a "verified purchase" invariant) — this is inferred only from the fact that `OrderDelivered` is a consumed input, not asserted as a rule anywhere in the BRD. Not treated as a confirmed invariant here — see Open Questions.

## 5. API Surface (from BRD, starting point only)

| Endpoint/Event | Direction | Notes |
|---|---|---|
| `/reviews` | Inbound API | BRD §5.4; HTTP method(s) and whether it covers both submission and retrieval not specified |
| `ReviewSubmitted` | Published | Consumed by Product (rating recalc), Analytics (BRD §10) |
| `OrderDelivered` | Consumed | Not listed as a published event by any service in the BRD's Event Catalog (§10) — see Open Questions |

Final contract is the API Design Agent's job, not this spec's.

## 6. Open Questions / Flagged Ambiguities

1. **Moderation workflow is entirely unspecified (blocking).** BRD §2.1 names "moderation" as one of Review's three primary responsibilities, but no other section defines it: no endpoint, no event, no automated-vs-human-review distinction, no escalation path, and no control in the Security table (§24). This cannot be inferred without inventing requirements the BRD does not state.
2. **Verified-purchase gating is unclear (blocking).** BRD §5.4 states Review consumes `OrderDelivered`, but does not say what that consumption does: (a) a hard invariant — only a customer with a matching delivered order for that SKU may submit a review, enforced before accepting `POST /reviews`; or (b) merely a trigger for a "please leave a review" prompt (e.g., via Notification), with submission otherwise open. These have materially different domain-invariant and API-validation implications.
3. **`OrderDelivered` publisher is missing from the Event Catalog (§10).** Only `OrderCreated`, `OrderConfirmed`, and `OrderCancelled` are listed there as Order's published events. Either Order publishes an event omitted from the catalog, or the real source is Delivery Tracking's `DeliveryStatusUpdated` (status = delivered) and `OrderDelivered` is the BRD's informal name for that same signal. The BRD does not disambiguate — structurally similar to the `ProductPriceChanged` publisher contradiction resolved in the Offer spec (see [ADR-0001](../../adr/0001-offer-service-merge.md) sibling doc, [kart-offer-service/requirement-spec.md](../kart-offer-service/requirement-spec.md) §6, Q1).
4. **Edit/delete window for a submitted review is not specified.** The BRD says nothing about whether a customer may amend or retract a review after submission, or for how long. Affects both the API surface and downstream consumers (Product's rating recalc, Analytics) that would need to handle revision/retraction, not just initial submission.
5. **Rating aggregate ownership split is unresolved.** BRD §2.1 assigns "ratings" to Review as a primary responsibility, but §10's Event Catalog names **Product** as the consumer performing "rating recalc," and §6.2's example embeds the resulting `ratingSummary` in `product_read_model` (a Product/Search-owned collection), not any Review-owned collection. Whether Review needs its own rating-aggregate storage/invariant at all, or is purely a review-content service that emits raw ratings for Product to aggregate, is not resolved.
6. **`ReviewSubmitted` payload omits reviewId, userId, and review text (§10: only `orderId`, `sku`, `rating`).** Unclear whether this is intentional — a recalc-only payload, with review content served separately via the `/reviews` read path — or a gap, since a consumer like Analytics would plausibly want the free-text content itself, not just the numeric rating.

## Sign-off

- [ ] Blocking open questions resolved (Q1, Q2, Q3)
- [ ] Reviewed by:
- [ ] Approved to proceed to Architecture Agent
