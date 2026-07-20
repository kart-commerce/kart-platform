---
doc_type: requirement-spec
service: kart-recommendation-service
status: approved
generated_by: requirement-agent
source: docs/requirements/kart-requirements.md
---

# Requirement Spec: kart-recommendation-service

## 1. Scope

Covers a single BRD service: **Recommendation Service** (BRD §2.1 item 18, "Personalization, 'customers also bought'"). No merge with another BRD service applies here — unlike Offer, Recommendation maps 1:1 onto one bounded context, so no ADR is required to justify scope.

Recommendation is a **read-side, consumer-only** service: it publishes no events of its own (BRD §5.4 lists no "Events Published" for Recommendation) and exposes a single read API. Its job is turning purchase and behavioral signal into a queryable personalization result — structurally similar to Search (BRD §17) in that both are pure query services fed by an event pipeline, but Search projects catalog state while Recommendation projects per-user behavioral state.

The BRD's treatment of this service is minimal: one line in §2.1, one condensed row in §5.4, and a passing mention in §15's Kafka migration rationale. No dedicated narrative section (comparable to §17 for Search) exists for Recommendation. This spec does not invent detail the BRD doesn't state — the gaps are named in full in Open Questions rather than filled in.

## 2. Functional Requirements

- Serve personalized recommendations for a given user (`GET /recommendations/{userId}`, BRD §5.4).
- Provide "customers also bought"-style personalization (BRD §2.1 item 18) — the BRD names the feature but not the algorithm/model behind it; see Open Questions.
- Consume `OrderCompleted` to build or update purchase-based recommendation signal (BRD §5.4). This event does not appear anywhere in the BRD's own Event Catalog (§10): Order Service's published events per §10 are `OrderCreated`, `OrderConfirmed`, and `OrderCancelled` only — no `OrderCompleted` publisher is named in the BRD at all. See Open Questions.
- Consume "clickstream events" to build behavioral recommendation signal (BRD §5.4). The BRD names this input but defines no event name, schema, payload, publisher, or topic anywhere (not in §10's Event Catalog, not attributed to any owning service). See Open Questions.
- Publishes no events (BRD §5.4 lists none for Recommendation) — this is a pure consumer + read-API service, not a participant in any Saga or downstream fan-out.
- BRD §15 (Kafka Migration) names Recommendation alongside Analytics as needing "replay and high-throughput partitioned consumption," implying its event intake is Kafka-based rather than RabbitMQ-based, consistent with `kart-conventions.md`'s Kafka topic naming (`kart.<service>.<entity>`). The BRD does not, however, name the actual topic(s) Recommendation consumes from.

## 3. Non-Functional Requirements

Pulled from the BRD's global NFR table (§3), scoped to this service. Recommendation is **not** named in §2.2's list of domain rules that force hard engineering decisions (unlike Search's explicit "within seconds, not milliseconds" consistency bound) — so, unlike `kart-search-service`, there is no BRD-forced consistency conversation for this service at all.

| Attribute | Target | Applies here because |
|---|---|---|
| Availability | 99.9% (secondary path) | BRD's 99.99% tier is scoped to "order path" (§3); Recommendation is not a Saga participant — §5.5's diagram shows it only as a Bus fan-out consumer, same tier as Search/Analytics/Delivery Tracking |
| Latency | P95 < 150ms, P99 < 400ms (read path) | `GET /recommendations/{userId}` is a pure read endpoint (§3 read-path row) |
| Consistency | Eventual (MongoDB read path) | BRD §5.4 stores recommendations in MongoDB, consistent with the platform's CQRS read-side pattern (§3) — but no staleness bound is stated for Recommendation the way §2.2 states one for Search; see Open Questions |
| Reliability | At-least-once delivery + idempotent consumers (platform default, §3) | Would apply to `OrderCompleted`/clickstream consumption if this service follows the platform default — but the BRD never states this explicitly for Recommendation the way it does for Coupon/Pricing (§10), since neither input event is in the Event Catalog at all |
| Throughput | Not given numerically for Recommendation | §15 groups Recommendation with Analytics as needing "high-throughput partitioned consumption" — clickstream events fire on every user interaction (view, click, search), not just on order completion, so volume scales with traffic rather than conversions; the BRD gives no concrete RPS/volume figure for this input, unlike its platform-wide throughput target (§3: 100K RPS sustained, 1M RPS burst) |
| Retry/DLQ | Not specified | Neither `OrderCompleted` nor "clickstream events" appear as rows in BRD §10's Event Catalog, so there is no stated retry count or DLQ target for either input — a gap, not an inferred default; see Open Questions |

## 4. Domain Invariants

The BRD states no explicit domain invariants for Recommendation (contrast with Inventory's oversell rule or Payment's double-charge rule at §2.2) — this section stays intentionally thin rather than inventing one.

- A recommendation response is served from a precomputed MongoDB read model, not computed live against the event stream at request time (inferred from the MongoDB read-store + CQRS pattern at §3/§6, and consistent with the read-path latency NFR above — a P95 < 150ms budget is incompatible with recomputing personalization signal synchronously per request). The BRD does not state this explicitly for Recommendation; it is inferred from the platform's stated CQRS convention.
- Beyond that inference, no further invariant is stated or safely inferable — the recommendation algorithm, its inputs' relative weighting, and any correctness rule (e.g., "never recommend a product the user already owns/purchased") are all unspecified. See Open Questions.

## 5. API Surface (from BRD, starting point only)

| Endpoint/Event | Direction | Notes |
|---|---|---|
| `GET /recommendations/{userId}` | Inbound API | BRD §5.4; no request/response shape (pagination, item count, filtering) specified |
| `OrderCompleted` | Consumed | No publisher named anywhere in the BRD — Order Service publishes `OrderCreated`, `OrderConfirmed`, `OrderCancelled` per §10, not `OrderCompleted`. Contradiction between §5.4 (names the event) and §10 (doesn't list it) — see Open Questions |
| clickstream events | Consumed | No event name(s), payload, publisher, or topic specified anywhere in the BRD — see Open Questions |

No events are published by Recommendation (BRD §5.4 lists none). Final contract (response shape, item count, pagination, and the actual clickstream event schema) is the API/Event Design Agents' job, not this spec's.

## 6. Open Questions / Flagged Ambiguities

1. **`OrderCompleted` has no publisher in the BRD.** BRD §5.4 lists it as an event Recommendation consumes, but BRD §10's Event Catalog — the BRD's own source of truth for events — does not include an `OrderCompleted` event at all; Order Service's catalog entries are `OrderCreated`, `OrderConfirmed`, `OrderCancelled`. This may be an alias for an existing terminal event (e.g. `OrderConfirmed`, or the `OrderDelivered` event Review already consumes per §5.4), or a genuinely missing catalog entry. Do not guess which — carried to the **Event Design Agent** stage to resolve, since it determines whether Recommendation's core purchase-based signal exists at all.
2. **"Clickstream events" are entirely unspecified.** No event name, schema, payload fields, owning/publishing service, topic, or volume figure is given anywhere in the BRD. This is the single largest gap in this spec — every downstream stage (Event Design, Architecture, DDD) needs this defined before it can proceed meaningfully. Carried to the **Event Design Agent**.
3. **Recommendation algorithm/model is unspecified.** BRD §2.1 item 18 names the feature ("Personalization, 'customers also bought'") with no mention of collaborative filtering, content-based filtering, a trained ML model, or a simple co-occurrence rule. This materially affects whether Recommendation is a conventional CRUD-shaped service or an ML serving/training pipeline. Carried to the **Architecture/DDD Agents** — this is as much a product decision as an engineering one.
4. **No staleness/consistency SLA is given.** Unlike Search, which BRD §2.2 explicitly forces a "within seconds, not milliseconds" bound for, Recommendation is not named in §2.2 at all — there is no stated tolerance for how stale a recommendation may be relative to the latest `OrderCompleted`/clickstream signal. Carried to the **Architecture Agent** to propose a bound, with human sign-off since it affects whether recomputation is batch or near-real-time.
5. **No retry/DLQ policy exists for either consumed input.** Because neither `OrderCompleted` nor clickstream events appear in BRD §10's Event Catalog, there is no retry count or DLQ target to inherit (contrast with Coupon/Pricing/Promotion, which all have explicit §10 rows). Carried to the **Event Design Agent**, contingent on Q1/Q2 first defining what these events actually are.
6. **Cold-start behavior is unaddressed.** The BRD does not say what `GET /recommendations/{userId}` should return for a user with zero `OrderCompleted` and zero clickstream history. Not resolvable from BRD text alone — see `edge-cases.md` for the candidate solutions and the decision taken.

## Sign-off

- [ ] Blocking open questions resolved
- [ ] Reviewed by:
- [ ] Approved to proceed to Architecture Agent
