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
- Consume `OrderDelivered` to build or update purchase-based recommendation signal (BRD §5.4, §10). This event's publisher, payload, and delivery tier are now fully confirmed by **ADR-0005** (Unify Order Terminal Event): published by **Order Service**, payload `orderId, deliveredAt`, 3x retry, `order.dlq` (BRD §10). ADR-0005 treats the BRD's earlier `OrderCompleted` naming as an inconsistent early label for the same underlying concept (the order reaching its terminal successful, delivered state), not a second, separate event — `OrderCompleted` itself never had a publisher or a defined payload anywhere in the BRD, so there is no prior payload to diff against here; `orderId, deliveredAt` is genuinely new information this spec did not previously have, not a cosmetically renamed copy of an existing shape. Order publishes `OrderDelivered` upon consuming Delivery Tracking's `DeliveryStatusUpdated` and detecting its terminal "delivered" status — that upstream hop is Order's internal concern; Recommendation's actual dependency is on Order's `OrderDelivered` only, not on Delivery Tracking directly. What the FR itself asks for — a purchase-based recommendation signal — is unchanged; only the name, publisher, and payload of the input event are now settled. See Domain Invariants and API Surface below.
- Consume "clickstream events" to build behavioral recommendation signal (BRD §5.4). The BRD names this input but defines no event name, schema, payload, publisher, or topic anywhere (not in §10's Event Catalog, not attributed to any owning service). This gap is unaffected by ADR-0005 — it resolved the purchase-signal input only, not the behavioral-signal input. See Open Questions.
- Publishes no events (BRD §5.4 lists none for Recommendation) — this is a pure consumer + read-API service, not a participant in any Saga or downstream fan-out.
- BRD §15 (Kafka Migration) names Recommendation alongside Analytics as needing "replay and high-throughput partitioned consumption," implying its event intake is Kafka-based rather than RabbitMQ-based, consistent with `kart-conventions.md`'s Kafka topic naming (`kart.<service>.<entity>`). The BRD does not, however, name the actual topic(s) Recommendation consumes from.

## 3. Non-Functional Requirements

Pulled from the BRD's global NFR table (§3), scoped to this service. Recommendation is **not** named in §2.2's list of domain rules that force hard engineering decisions (unlike Search's explicit "within seconds, not milliseconds" consistency bound) — so, unlike `kart-search-service`, there is no BRD-forced consistency conversation for this service at all.

| Attribute | Target | Applies here because |
|---|---|---|
| Availability | 99.9% (secondary path) | BRD's 99.99% tier is scoped to "order path" (§3); Recommendation is not a Saga participant — §5.5's diagram shows it only as a Bus fan-out consumer, same tier as Search/Analytics/Delivery Tracking |
| Latency | P95 < 150ms, P99 < 400ms (read path) | `GET /recommendations/{userId}` is a pure read endpoint (§3 read-path row) |
| Consistency | Eventual (MongoDB read path) | BRD §5.4 stores recommendations in MongoDB, consistent with the platform's CQRS read-side pattern (§3) — but no staleness bound is stated for Recommendation the way §2.2 states one for Search; see Open Questions |
| Reliability | At-least-once delivery + idempotent consumers (platform default, §3) | Applies to `OrderDelivered` consumption — no longer a gap here, this input now has a full BRD §10 Event Catalog row (publisher Order, 3x retry, `order.dlq`, added by **ADR-0005**). Still an open gap for clickstream consumption, since that input has no Event Catalog entry at all; see Open Questions |
| Throughput | Not given numerically for Recommendation | §15 groups Recommendation with Analytics as needing "high-throughput partitioned consumption" — clickstream events fire on every user interaction (view, click, search), not just on order completion, so volume scales with traffic rather than conversions; the BRD gives no concrete RPS/volume figure for this input, unlike its platform-wide throughput target (§3: 100K RPS sustained, 1M RPS burst) |
| Retry/DLQ | `OrderDelivered` (consumed): 3x retry, `order.dlq` — Order's own publish-side tier for this event (BRD §10, added by **ADR-0005**), not a Recommendation-specific tier. Clickstream events: still not specified — no Event Catalog entry exists for this input at all, so there is no retry count or DLQ target to inherit — a genuine gap, not an inferred default; see Open Questions | `OrderDelivered` sits in the same tier as `OrderCreated`/`OrderConfirmed`/`OrderCancelled` — the standard 3x/`order.dlq` tier, not the money-critical `Payment*` 5x/paged tier |

## 4. Domain Invariants

The BRD states no explicit domain invariants for Recommendation (contrast with Inventory's oversell rule or Payment's double-charge rule at §2.2) — this section stays intentionally thin rather than inventing one.

- A recommendation response is served from a precomputed MongoDB read model, not computed live against the event stream at request time (inferred from the MongoDB read-store + CQRS pattern at §3/§6, and consistent with the read-path latency NFR above — a P95 < 150ms budget is incompatible with recomputing personalization signal synchronously per request). The BRD does not state this explicitly for Recommendation; it is inferred from the platform's stated CQRS convention.
- The purchase-signal input's provenance is now settled — `OrderDelivered`, published by Order Service, payload `orderId, deliveredAt`, per **ADR-0005** — but no invariant about *how* that signal is used is stated anywhere in the BRD (e.g., whether a delivered order for SKU X should suppress future recommendations of SKU X to the same user, or any other correctness rule). This is a naming/provenance resolution only, not a resolution of what Recommendation must guarantee about its output; see Open Questions.
- Beyond that, no further invariant is stated or safely inferable — the recommendation algorithm, its inputs' relative weighting, and any correctness rule (e.g., "never recommend a product the user already owns/purchased") are all unspecified. See Open Questions.

## 5. API Surface (from BRD, starting point only)

| Endpoint/Event | Direction | Notes |
|---|---|---|
| `GET /recommendations/{userId}` | Inbound API | BRD §5.4; no request/response shape (pagination, item count, filtering) specified |
| `OrderDelivered` | Consumed | Published by **Order Service** (BRD §10, added by **ADR-0005** — Unify Order Terminal Event): payload `orderId, deliveredAt`; 3x retry; `order.dlq`; also consumed by Review, Notification, Analytics (BRD §10). BRD §5.4's condensed row for Recommendation now names `OrderDelivered` directly and explicitly notes it supersedes the earlier `OrderCompleted` naming. The prior contradiction — §5.4 naming an event (`OrderCompleted`) that had no §10 publisher at all — is resolved: `OrderCompleted` was never a second, real event, it was an inconsistent early label for the same terminal-order concept that Order now publishes as `OrderDelivered` |
| clickstream events | Consumed | No event name(s), payload, publisher, or topic specified anywhere in the BRD — see Open Questions. Unaffected by ADR-0005, which resolved the purchase-signal input only |

No events are published by Recommendation (BRD §5.4 lists none). Final contract (response shape, item count, pagination, and the actual clickstream event schema) is the API/Event Design Agents' job, not this spec's.

## 6. Open Questions / Flagged Ambiguities

**Resolved since the prior draft.** The prior draft's Open Question #1 — `OrderCompleted` named in BRD §5.4 as an event Recommendation consumes, with no publisher anywhere in BRD §10's Event Catalog — is resolved by **ADR-0005** (Unify Order Terminal Event). Order Service publishes `OrderDelivered` directly (payload `orderId, deliveredAt`; 3x retry; `order.dlq`), triggered internally by Order's own consumption of Delivery Tracking's `DeliveryStatusUpdated` (terminal "delivered" status). Recommendation consumes `OrderDelivered` from Order, not any event named `OrderCompleted` — the BRD's original name is treated as an inconsistent early label for the same underlying concept, not a second, separate event that might still be missing. BRD §5.4's row for Recommendation and §10's Event Catalog row for `OrderDelivered` are now consistent with each other and with this spec (see §2, §3, §5 above). Removed from the list below rather than carried forward as open; remaining genuinely open items (renumbered):

1. **"Clickstream events" are entirely unspecified.** No event name, schema, payload fields, owning/publishing service, topic, or volume figure is given anywhere in the BRD. This is the single largest gap in this spec — every downstream stage (Event Design, Architecture, DDD) needs this defined before it can proceed meaningfully. Unaffected by ADR-0005, which resolved the purchase-signal input (`OrderDelivered`) only, not this behavioral-signal input. Carried to the **Event Design Agent**.
2. **Recommendation algorithm/model is unspecified.** BRD §2.1 item 18 names the feature ("Personalization, 'customers also bought'") with no mention of collaborative filtering, content-based filtering, a trained ML model, or a simple co-occurrence rule. This materially affects whether Recommendation is a conventional CRUD-shaped service or an ML serving/training pipeline. Carried to the **Architecture/DDD Agents** — this is as much a product decision as an engineering one.
3. **No staleness/consistency SLA is given.** Unlike Search, which BRD §2.2 explicitly forces a "within seconds, not milliseconds" bound for, Recommendation is not named in §2.2 at all — there is no stated tolerance for how stale a recommendation may be relative to the latest `OrderDelivered`/clickstream signal. Carried to the **Architecture Agent** to propose a bound, with human sign-off since it affects whether recomputation is batch or near-real-time.
4. **Retry/DLQ policy is now resolved for the purchase-signal input only, still fully open for clickstream.** `OrderDelivered` has a confirmed §10 Event Catalog row (3x retry, `order.dlq`, added by ADR-0005) — no longer a gap for that input. Clickstream events have no Event Catalog entry at all (see Q1 above), so there remains no retry count or DLQ target to inherit for that input specifically. Carried to the **Event Design Agent**, contingent on Q1 first defining what the clickstream event(s) actually are.
5. **Cold-start behavior is unaddressed.** The BRD does not say what `GET /recommendations/{userId}` should return for a user with zero `OrderDelivered` and zero clickstream history. Not resolvable from BRD text alone — see `edge-cases.md` for the candidate solutions and the decision taken.
6. **`ProductCreated` is listed in BRD §10 as a Recommendation-consumed event, but is not named anywhere else in the BRD for this service (newly found during this pass).** §10's Event Catalog row for `ProductCreated` lists its consumers as "Search, Recommendation, Analytics" — but BRD §5.4's condensed row for Recommendation (which explicitly lists `OrderDelivered` and clickstream events as its consumed inputs) does not mention `ProductCreated`, and no other BRD section attributes any purpose to Recommendation consuming catalog-creation events (e.g., to know which SKUs exist/are eligible for recommendation, independent of purchase or clickstream signal). This is a genuine §5.4/§10 inconsistency of the same shape ADR-0005 just resolved for `OrderDelivered`/`OrderCompleted` — an event named in one BRD source of truth but not the other — except here it is §10 naming an input that §5.4 omits, not the reverse. Not resolved in this pass; flagged for the same kind of ADR-level resolution ADR-0005 provided, or for confirmation that §5.4's row is simply incomplete rather than contradictory.

## Sign-off

- [ ] Blocking open questions resolved
- [ ] Reviewed by:
- [ ] Approved to proceed to Architecture Agent
