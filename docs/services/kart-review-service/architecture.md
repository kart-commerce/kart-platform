---
doc_type: architecture
service: kart-review-service
status: pending-approval
generated_by: architecture-agent
source: docs/services/kart-review-service/requirement-spec.md, docs/services/kart-review-service/edge-cases.md, docs/services/kart-review-service/design-decisions.md
---

# Architecture: kart-review-service

## Boundary Rationale

`kart-review-service` is the bounded context that answers "is this review genuine, is it fit to publish, and what does this product's rating actually look like right now" — it owns review authorship (submission, edit, retraction), the two-stage moderation workflow, and the canonical rating aggregate as one cohesive domain (BRD §2.1, item 14: "Ratings, reviews, moderation"). No merge with another BRD service is indicated and no ADR proposes one — unlike [kart-offer-service](../kart-offer-service/architecture.md), this is a standalone context (requirement-spec §1).

Two cross-cutting resolutions fix this boundary's edges precisely, rather than leaving them implicit:

- **[ADR-0014](../../adr/0014-review-rating-aggregate-ownership.md)** settles that Review is the sole canonical system-of-record for the rating aggregate (`avg`/`count`). Product's own `ratingSummary` copy is an independent, denormalized projection of the same `ReviewSubmitted` stream — Product never calls Review synchronously to read "the real number," and Review never blocks on Product's copy. This is two projections of one event stream, not a client-server relationship.
- **[ADR-0005](../../adr/0005-unify-order-terminal-event.md)** establishes `OrderDelivered` as the one event, published by Order Service, that Review consumes as its verified-purchase eligibility gate.

Review is a **write-path-latency-sensitive, moderation-gated** service: it is called synchronously by the client for submission/edit/retract, and by a Support/Admin console for the moderator action, but it is **not** a participant in the Order Saga (BRD §12) — the saga only touches Inventory, Payment, and Shipping. Review's relationship to Order is purely event-driven and after-the-fact (it reacts to `OrderDelivered` once the saga has already completed successfully).

This matters for availability posture: Review can be briefly degraded or unavailable without blocking the order-confirmation critical path, and — by design (see Dependencies below) — a temporary Order Service outage does not block review submission either, because Review checks eligibility against its own locally materialized copy of delivery state, not a live call to Order.

## Dependencies

| Direction | Peer | Mechanism | Type | Notes |
|---|---|---|---|---|
| Inbound (client) | Client/Storefront via API Gateway | `POST /reviews`, `GET /reviews?sku=...`, `PATCH /reviews/{id}`, `DELETE /reviews/{id}` | **Sync** (REST) | Submission/read/edit/retract surface (requirement-spec §5). Write path budget: P95 < 300ms; read path: P95 < 150ms/P99 < 400ms. |
| Inbound (client, back-office) | Support/Admin console via API Gateway | `PATCH /reviews/{id}/moderate` | **Sync** (REST) | Moderator accept/reject on a queued flagged review; RBAC-gated to Support Agent/Admin role (BRD §24.1, requirement-spec §3) |
| Inbound (consumed) | Order Service | `OrderDelivered` event | **Async** | Published by Order per ADR-0005 (`orderId, deliveredAt`; 3x retry, `order.dlq` — Order's own tier). Review projects this into its own materialized `(customerId, orderId, sku)` delivered-order record (event-carried state transfer — see design-decisions.md's "Cross-Service Verified-Purchase Check" decision). `POST /reviews`'s hard eligibility gate (requirement-spec §4 Domain Invariant) checks **only** against this local copy — never a live call back to Order. |
| Outbound (published) | Product | `ReviewSubmitted` event | **Async** | 2x retry, `review.dlq` (BRD §10). Payload: `orderId, sku, rating, reviewId, userId` (requirement-spec §6 Q5 — expanded from the BRD's original 3 fields). Consumed for Product's denormalized `ratingSummary` recalc per ADR-0014 — not a second canonical aggregate. |
| Outbound (published) | Analytics | `ReviewSubmitted` event | **Async** | Same event/tier as above; Analytics is a full fan-in consumer of every platform event per ADR-0004, not a Review-specific integration. |
| Outbound (published) | `kart-search-service` | `ReviewSubmitted` event | **Async** | Same event/tier as above; confirmed by [ADR-0018](../../adr/0018-search-catalog-signal-sourcing.md) — Search maintains its own denormalized ranking-signal projection, the identical "second independent reader of this stream" pattern ADR-0014 already established for Product's `ratingSummary`. Search's own consumer-side DLQ (`search.review-submitted.dlq`) is that service's own call, per `kart-search-service/event-contract.md`. |
| Outbound (published) | Product, Analytics, `kart-search-service` | `ReviewUpdated` event (**new**, requirement-spec §6 Q3) | **Async** | Fired on an author edit within the 30-day edit window, so consumers can adjust an aggregate incrementally instead of re-deriving it from a fresh create. Payload: `orderId, sku, oldRating, newRating`. Formal retry count/DLQ name is **not** decided here — carried to the Event Design Agent stage per requirement-spec §6 Q3/"Non-blocking, carried forward," the same way `kart-product-service`'s own `ProductUpdated` registration was carried forward. `kart-search-service` added as a third consumer by [ADR-0018](../../adr/0018-search-catalog-signal-sourcing.md). |
| Outbound (external, non-platform) | Automated content-safety classifier (profanity/spam/toxicity filter) | Synchronous blocking pre-check call inside `POST /reviews` and `PATCH /reviews/{id}` | **Sync** | See "Distributed-Monolith Risk" below — this is the one true external synchronous dependency in Review's write path, and it is deliberately **not** modeled as a platform bounded-context peer service (no BRD section names a Moderation Service; requirement-spec §6 Q1 confirms the workflow is "Review-internal, not cross-cutting"). Treated as cross-cutting infrastructure, called out here for operational risk, not added as a graph edge in `service-boundaries.md`. |

Note what is deliberately **absent** from this table: there is no synchronous outbound call to Order Service anywhere in the verified-purchase gate. This is the resolution of requirement-spec §6 Q2's carried concern (Review "takes on a synchronous dependency on having already processed the relevant `OrderDelivered` event") — the dependency is on **data freshness** (has the event arrived and been projected yet), not on **Order's runtime availability**. A slow or down Order Service does not directly fail a `POST /reviews` call; a not-yet-arrived `OrderDelivered` event does, surfaced as the explicit "no matching delivered order found yet, try again shortly" rejection rather than a timeout against a live peer.

## Resolved Integration-Contract Question: Moderation-Filter Latency Budget

Requirement-spec §3 carried forward, as a non-blocking Architecture Agent concern, "whether the synchronous automated-filter call fits inside the existing 300ms write-path budget." Resolved here as an architecture-stage default, pending the load-testing validation the requirement-spec itself deferred:

- The classifier call is allocated a **sub-budget of ≤120ms** within the overall P95 < 300ms write-path target, leaving headroom for the verified-purchase check against the local materialized store, the domain write (PostgreSQL insert/update), and the Outbox insert.
- The call carries a **hard timeout at that ceiling**, backed by a circuit breaker (design-decisions.md, "Resilience Pattern for the Synchronous Automated Moderation Filter Call"). On timeout or an open circuit, the submission is routed to the human moderation queue — **fail-safe, never fail-open** — so a slow/unavailable classifier degrades to "more items queued for a human" rather than "unscreened content auto-published."
- This sub-budget is a starting allocation for the Database Design/Event Design stages and load-testing to validate or revise, not a number derived from measured production latency (none exists yet for a pre-scaffold service).

## Distributed-Monolith Risk

**One risk identified, already mitigated by design, not left open:** the automated content-safety classifier is a genuine synchronous, blocking dependency inside `POST /reviews`/`PATCH /reviews/{id}` — if it were naively fail-open on timeout, an outage would silently defeat Review's entire moderation responsibility (BRD §2.1) at exactly the moment screening matters most. This is addressed by the fail-safe-to-queue circuit breaker decision above: a classifier outage degrades the system to "100% of submissions queued for human review" (bounded, self-recovering) rather than "100% of submissions auto-published unscreened" (unbounded exposure, no recovery path for content already published) — see design-decisions.md for the full trade-off analysis. No further architectural change is recommended; this is a monitoring/alerting concern (classifier error rate, circuit-breaker state) for the operational stage, not a design gap.

**No other synchronous inter-service (within-platform) dependency exists.** The verified-purchase gate is deliberately implemented as event-carried state transfer specifically to avoid coupling Review's write-path availability to Order Service's runtime availability (design-decisions.md). Review can be deployed, scaled, and does not go down if Order, Product, or Analytics are degraded — its only true availability coupling is to the external classifier, and that coupling fails safe rather than open.

**Flag for the Event Design Agent stage:** `ReviewUpdated` is a new event with no registered retry/DLQ tier yet (requirement-spec §6 Q3). Until it is registered, treat it provisionally as the same tier as `ReviewSubmitted` (2x retry, `review.dlq`) — both are catalog/review-class events, not `Payment*`-class — but this is a placeholder for that stage to confirm, not a final answer.

## Sign-off

- [ ] Reviewed by:
- [ ] Approved to proceed to DDD Agent
