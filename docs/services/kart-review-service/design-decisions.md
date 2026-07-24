---
doc_type: design-decisions
service: kart-review-service
status: approved
generated_by: design-decision-agent
source: docs/services/kart-review-service/requirement-spec.md, docs/services/kart-review-service/edge-cases.md
---

# Design Decisions: kart-review-service

## Decision: Resilience Pattern for the Synchronous Automated Moderation Filter Call

- **Requirement driving this:** requirement-spec §2/§3 (moderation workflow's automated filter runs synchronously inside the `POST /reviews` write path, inside the P95 < 300ms write budget) and §6 Q1; edge-cases.md "Moderation queue backlog" and "Abusive content" edge cases (hybrid pre-screen design).
- **Options considered (3):** no timeout/circuit breaker — block until the filter responds · timeout + circuit breaker, **fail-open** to auto-publish on filter timeout/unavailability · timeout + circuit breaker, **fail-safe to the human queue** on filter timeout/unavailability.
- **Decision (3-5 bullets max):**
  - Chosen: bounded timeout inside the write-path budget, backed by a circuit breaker; on timeout or open-circuit, the submission is routed to the human moderation queue (fail-safe), never auto-published.
  - Why: BRD §2.1 names moderation a primary Review responsibility — fail-open would auto-publish unscreened content during exactly the failure window when screening matters most, silently defeating the hybrid design the "Abusive content" and "Moderation backlog" edge cases already settled on.
  - Trade-off accepted: a classifier outage temporarily turns 100% of submissions into queued items instead of only the flagged minority, reintroducing backlog risk for the outage's duration only — bounded and self-recovering once the classifier returns, unlike a fail-open outage which has no recovery path for content that already published.

## Decision: Idempotency Mechanism for `POST /reviews`

- **Requirement driving this:** edge-cases.md "Duplicate review submission for the same delivered order"; requirement-spec §4 Domain Invariant (unique constraint on `(order_id, sku)`).
- **Options considered (3):** client-supplied `Idempotency-Key` header checked against a dedup store before insert, response replayed on a repeat key (the shape api-standards.md mandates for money-moving `POST`s) · server-derived deterministic key computed from `(customerId, orderId, sku)`, no client header required · rely solely on the database's unique constraint, translating the resulting conflict into a 409.
- **Decision (3-5 bullets max):**
  - Chosen: both the `Idempotency-Key` header/dedup-store pattern **and** the `(order_id, sku)` unique constraint — not either alone.
  - Why: api-standards.md only mandates `Idempotency-Key` for money-moving writes, but `POST /reviews` is a non-retry-safe write with the same double-click/client-retry failure mode, so the existing mechanism generalizes cleanly rather than inventing a new one; the unique constraint is the independent second layer that still catches a duplicate arriving without a matching key (e.g., a different client instance), which a key-only design would miss.
  - Trade-off accepted: two separate dedup checks on one endpoint instead of one, but each catches a distinct failure class (literal client retry vs. schema-level race) — a customer wanting to change their opinion goes through the edit path (`PATCH /reviews/{id}`), not a second insert, so neither mechanism is ever fighting the edit-window invariant.

## Decision: Cross-Service Verified-Purchase Check via Event-Carried State Transfer, Not a Synchronous Call

- **Requirement driving this:** requirement-spec §4 Domain Invariant (verified-purchase gate) and §6 Q2; edge-cases.md "Fake/unverified review submission via `OrderDelivered` gating."
- **Options considered (3):** synchronous REST/gRPC call to Order Service at submission time to check live delivery status · local materialized store fed by consumed `OrderDelivered` events, checked synchronously against Review's own data (event-carried state transfer) · optimistic accept + async verification with retroactive takedown.
- **Decision (3-5 bullets max):**
  - Chosen: event-carried state transfer — Review consumes `OrderDelivered` (published by Order Service per ADR-0005) into its own materialized `(customerId, orderId, sku)` record, and `POST /reviews` checks synchronously against that local record only.
  - Why: keeps the hard eligibility gate (already decided, requirement-spec §6 Q2) inside Review's own write-path latency budget (§3) without adding a runtime dependency on Order Service's availability, consistent with the platform's standing event-driven-integration default over chatty synchronous service-to-service calls.
  - Trade-off accepted: eligibility data can lag actual delivery by however long `OrderDelivered` takes to arrive and be projected — the accepted consequence already named in requirement-spec §6 Q2, surfaced as a "no matching delivered order found yet, try again shortly" rejection rather than a silent failure or a synchronous call to Order Service that could itself time out.

## Decision: Concurrency-Control Pattern for Denormalized Aggregate Updates (Rating Aggregate)

- **Requirement driving this:** requirement-spec §4 Domain Invariant (rating aggregate ownership, ADR-0014); edge-cases.md "Rating aggregate recompute race under concurrent submissions."
- **Options considered (3):** pessimistic per-SKU row lock held during the aggregate update · atomic incremental update (`$inc` on count, weighted running-average update) deduplicated by the event's `reviewId` · full recompute of the aggregate from the source-of-truth reviews table on every event.
- **Decision (3-5 bullets max):**
  - Chosen: atomic incremental update, deduplicated by `reviewId`, adopted as Review's standing pattern for updating its own canonical aggregate (and reusable for any future MongoDB read-model projection Review maintains), not a one-off fix scoped only to this field.
  - Why: avoids per-SKU lock contention that would serialize otherwise-independent concurrent submissions across different customers/orders, and avoids full-recompute cost growing with total review history on every single new review; the `reviewId` dedup key is what makes this safe under at-least-once redelivery without either of the other options' cost.
  - Trade-off accepted: requires persisting a processed-`reviewId` set (or equivalent dedup record) as extra state per aggregate consumer, versus a full-recompute approach's no-extra-state simplicity — accepted because recompute cost would otherwise scale unbounded with review volume.

## Decision: Event-Emission Timing Pattern — Defer-Until-Outcome, Not Publish-and-Compensate

- **Requirement driving this:** requirement-spec §4 Domain Invariant (moderation gate: content must not appear in the read model or fire `ReviewSubmitted` until cleared or moderator-accepted); edge-cases.md "Moderation-rejection racing an already-updated rating average."
- **Options considered (3):** publish-and-compensate — update the read model/aggregate and fire `ReviewSubmitted` at insert time regardless of moderation outcome, then emit a compensating reversal event if a moderator later rejects · defer-until-outcome — never touch the read model, the aggregate, or `ReviewSubmitted` until a review is actually publicly visible (immediate for auto-cleared content, on moderator-accept for flagged content) · two-phase reserve/commit — provisionally reserve an aggregate slot, commit or release it on moderation outcome.
- **Decision (3-5 bullets max):**
  - Chosen: defer-until-outcome, generalized from the fix already adopted for the "moderation-rejection racing" edge case into Review's standing rule for any side-effect (read-model write, aggregate update, or event publication) gated by moderation status.
  - Why: eliminates an entire class of reversal/compensation logic and the new moderation-outcome event that publish-and-compensate or reserve/commit would require, at no added cost beyond what the moderation-workflow decision (design-decision above, requirement-spec §6 Q1) already accepted — since only the flagged minority is ever delayed, deferring costs nothing for the majority of submissions.
  - Trade-off accepted: none beyond what the moderation-workflow decision already accepts (queue latency for flagged content only) — stated here as a generalization to future side-effects, not a new cost.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner
- [x] Approved to proceed to Architecture Agent
