---
doc_type: design-decisions
service: kart-wishlist-service
status: pending-approval
generated_by: design-decision-agent
source: docs/services/kart-wishlist-service/requirement-spec.md, docs/services/kart-wishlist-service/edge-cases.md
---

# Design Decisions: kart-wishlist-service

Cross-cutting technology/design-pattern choices this service's approved `requirement-spec.md` and `edge-cases.md` force. Service boundaries, aggregates/domain model, and schema/table design are out of scope here (Architecture, DDD, and Database Design Agents respectively) — including the still-open write-side-datastore question (requirement-spec §6 item 4), which every decision below is written to stay orthogonal to rather than silently presuppose an answer for. Decisions already settled at the requirement/edge-case stage (the 5%/24h alert-throttling rule, the 15/60-min batching window, the dedup+Outbox mechanism, the reconciliation-job approach) are referenced, not re-derived, except where they generalize into a technology/pattern choice not yet made explicit.

## Decision: Idempotent Alert Publication — Dedup Table + Transactional Outbox

- **Requirement driving this:** requirement-spec §4 (alert publication must be idempotent under RabbitMQ at-least-once delivery) and §3 Reliability NFR; edge-cases.md "Duplicate Alert Delivery from At-Least-Once Redelivery" (already resolved).
- **Options considered (3):** dedup table keyed on `(userId, sku, priceObserved)` combined with the Outbox pattern on publish (edge-cases.md's chosen fix) · consumer-side event-ID dedup on the inbound `ProductPriceChanged` message ID only · Outbox alone with no separate dedup table.
- **Decision (3-5 bullets max):**
  - Chosen: dedup table keyed on `(userId, sku, priceObserved)` plus the Transactional Outbox pattern for publishing `WishlistPriceAlertTriggered` — generalized here as Wishlist's standing idempotent-publish mechanism for this event, not a one-off fix.
  - Why: matches the platform's existing Outbox-Poller-RabbitMQ pipeline used elsewhere on this platform (event-standards.md's Outbox default) rather than a bespoke mechanism, and directly satisfies the §4 idempotency invariant; event-ID-only dedup was already rejected in edge-cases.md because it misses the case where the *same* price is re-announced via a *different* message ID (republish/backfill).
  - Trade-off accepted: a persisted dedup record per triggered price point, versus pure event-ID dedup's lower storage cost — accepted because it is the only option of the three that also survives a republish under a new message ID, not just a literal redelivery.

## Decision: State-Store Mechanism for the Per-User Alert Batching/Digest Window

- **Requirement driving this:** edge-cases.md "Alert Storm on Sitewide Price Drop" (chosen fix: per-user batching/digest, 15-minute rolling window, flush on 60-minute hard cap); requirement-spec §3 Reliability NFR (at-least-once delivery, no silently-lost alerts).
- **Options considered (3):** in-process/in-memory accumulator per consumer instance, flushed on a local timer · Redis-backed per-user pending-digest accumulator with a TTL matched to the 60-minute hard cap, flushed by a scheduled sweep · a durable pending-digest record in whichever store ends up being Wishlist's write side (still open, requirement-spec §6 item 4).
- **Decision (3-5 bullets max):**
  - Chosen: Redis-backed per-user accumulator, TTL set to the 60-minute hard cap, flushed by a scheduled sweep independent of the triggering consumer's own lifecycle.
  - Why: an in-memory-only accumulator would lose an entire window's pending triggers on a consumer crash/restart — contradicting the §3 Reliability NFR's "no silently-lost alert" expectation more directly than any latency cost saved; Redis gives durability across a single-instance crash without depending on the still-open write-side-datastore decision (requirement-spec §6 item 4), so this choice doesn't have to wait on, or presuppose the outcome of, that Architecture Agent question.
  - Trade-off accepted: Redis is not as durable as a fully-committed relational write (a Redis-level outage mid-window can still lose pending accumulator state for affected users) — accepted because the worst case is a missed or delayed digest for one batching cycle, not a money-moving correctness failure, and it is materially better than the in-memory alternative's guaranteed loss on every ordinary restart.

## Decision: Resilience Pattern for the Digest-Send-Time Price Re-Check

- **Requirement driving this:** edge-cases.md "Price Rebound During the Batching/Digest Window" (re-check the current price immediately before digest send; suppress if rebounded to/above baseline, correct the figures if partially rebounded); requirement-spec §4 (`WishlistPriceAlertTriggered` must reflect the actual current price, "not a stale cached price").
- **Options considered (3):** block the digest send until the re-check call succeeds, retrying indefinitely on failure · fail-open — if the re-check call itself times out or errors, send the digest anyway using the originally-captured price · fail-safe — bounded timeout + circuit breaker around the re-check call; on timeout or open-circuit, suppress that item from this digest cycle rather than send an unverified price.
- **Decision (3-5 bullets max):**
  - Chosen: fail-safe — bounded timeout and circuit breaker around the re-check call; on timeout/open-circuit, suppress the affected item from the current digest instead of sending it with an unverified price.
  - Why: the §4 accuracy invariant is exactly what edge-cases.md's re-check decision already extends to the delivery gap the batching window itself creates — sending a price the re-check couldn't actually confirm would undermine that same invariant, so fail-open is a direct contradiction of the requirement this mechanism exists to serve; blocking indefinitely risks the "Alert Storm" decision's own 60-minute hard-cap flush timing, especially during the sitewide-repricing scenario that decision was sized for in the first place.
  - Trade-off accepted: a transient failure of the re-check dependency causes a user to miss that one digest item for this cycle rather than receive a possibly-wrong price — consistent with this service's existing bias toward under-notifying over over-notifying (the same trade-off the "Wishlist Entry Added After the Price Drop" edge-case decision makes); the entry stays wishlisted, so a later qualifying evaluation under the 5%/24h rule can still surface it.

## Decision: Resilience & Fan-out Pattern for the Stale-Entry Reconciliation Job

- **Requirement driving this:** requirement-spec §6 item 7 (resolved with an interim default: periodic reconciliation job querying Product Service's `GET /products/{id}` for every wishlisted SKU); edge-cases.md "Stale Wishlist Entry for a Discontinued Product"; requirement-spec §3 Availability NFR (Wishlist is a 99.9% secondary-path service, not on the Order Saga's critical path — it must not become a load-driven instability source for a shared dependency like Product Service).
- **Options considered (3):** unbounded parallel calls, one per distinct wishlisted SKU, issued simultaneously for the whole reconciliation run · bounded-concurrency worker pool (bulkhead) with a per-call timeout and a circuit breaker guarding the run, sequential batches · fully sequential, single-threaded calls, one SKU at a time.
- **Decision (3-5 bullets max):**
  - Chosen: bounded-concurrency bulkhead — a capped worker pool with a per-call timeout, guarded by a circuit breaker over the whole run; on breaker-open or a run-wide failure-rate threshold, the current cycle aborts cleanly and simply retries at the job's next scheduled run rather than partially completing or blocking.
  - Why: requirement-spec §6 item 7 frames this job as buildable against API surface the BRD already defines but states no call pattern; an unbounded burst scales with total wishlisted-SKU count and risks degrading Product Service for its own, higher-tier callers, while a fully sequential design would make the reconciliation cadence itself unpredictably slow as the catalog/wishlist grows — bounded concurrency is the only option of the three that protects the shared dependency without an unbounded runtime. The BRD's own concrete `GET /products/{id}` shape (§5.4) is used as-is (synchronous REST, not gRPC or a bulk endpoint the BRD never defines).
  - Trade-off accepted: one reconciliation cycle takes longer than an unbounded burst would, and a cycle that trips the failure threshold is abandoned wholesale rather than salvaging partial progress — acceptable since requirement-spec §6 item 7 already frames staleness detection as bounded by "the reconciliation cadence... rather than being instant," a UX rough edge, not a correctness or money-moving concern, so waiting for the next cycle costs nothing structurally.

## Escalations

- **Not a decision made here, flagged for the human reviewer:** ADR-0016 (User GDPR Erasure Policy) names Wishlist among the services holding userId-linked PII that "picks up a new consumer responsibility the next time its own requirement-spec/edge-cases pass runs" for `UserDataErased`. This service's current, already-approved `requirement-spec.md` and `edge-cases.md` (this pass) do not mention `UserDataErased` or ADR-0016 at all, so there is no grounding in either input doc for this design-decision pass to define a consumption/idempotency mechanism for it — per this agent's own rule, that gap is skipped here rather than invented. Recommend a follow-up requirement-spec/edge-cases pass for `kart-wishlist-service` picks this up before (or in parallel with) the DDD Agent's aggregate design, so a wishlist entry's userId-linked-PII erasure handling isn't designed in ignorance of ADR-0016.
- All four decisions above are otherwise grounded directly in this service's approved `requirement-spec.md`/`edge-cases.md` and are single-service engineering defaults consistent with the project's shared standards (`event-standards.md`'s Outbox/DLQ defaults, `api-standards.md`'s REST/gRPC guidance, `ddd-cqrs-standards.md`'s rebuildable-read-model expectation) — no genuinely equivalent options requiring a business call were found among them.

## Sign-off

- [ ] Reviewed by a human
- [ ] Approved to proceed to Architecture Agent
