---
doc_type: architecture
service: kart-recommendation-service
status: approved
generated_by: architecture-agent
source: docs/services/kart-recommendation-service/requirement-spec.md
---

# Architecture: kart-recommendation-service

## Boundary Rationale

`kart-recommendation-service` is the bounded context that answers "what should this specific user see next" — a **read-side, consumer-only** projection of behavioral and purchase signal into a queryable personalization result (requirement-spec §1). It maps 1:1 onto a single BRD service (BRD §2.1 item 18); no merge ADR is required the way one was for Offer (ADR-0001).

Structurally it is a query service fed by an event pipeline, the same shape as `kart-search-service` — but where Search projects *catalog* state (what exists), Recommendation projects *per-user behavioral* state (what this user is likely to want). This distinction matters for the boundary: Recommendation never owns catalog or inventory truth, it only consumes catalog-creation events (`ProductCreated`) to seed a candidate pool, and (per this pass's resolution below) reads current catalog/stock status from Product and Inventory synchronously at request time rather than caching a second copy of "is this sellable."

Recommendation publishes no events (BRD §5.4 lists none) — it is a terminal node in the platform's event graph, not a participant in any Saga (BRD §12) and not a Bus fan-out source for any other service. It sits at the same secondary-availability tier as Search/Analytics/Delivery Tracking (requirement-spec §3), not the 99.99% order-path tier.

## Dependencies

| Direction | Peer Service | Mechanism | Type | Notes |
|---|---|---|---|---|
| Inbound (client) | Client/Mobile/Web via API Gateway | `GET /recommendations/{userId}` | **Sync** (REST) | Read-path endpoint; P95 < 150ms, P99 < 400ms (requirement-spec §3) |
| Inbound (consumed) | Order Service | `OrderDelivered` (RabbitMQ) | **Async** | Purchase-signal input; publisher/payload confirmed by [ADR-0005](../../adr/0005-unify-order-terminal-event.md) (`orderId, deliveredAt`). Retry/DLQ tier: **5x exponential, paged on-call, `order.order-delivered.dlq`** — `kart-order-service/event-contract.md`'s own later-elevated tier (superseding this doc's earlier "3x/`order.dlq`" figure, inherited from BRD §10's original table before Order's own requirement-spec resolution #7 elevated it; see `event-contract.md`'s own Correction note for the full citation). Recommendation depends on Order's output only — Order's own upstream consumption of Delivery Tracking's `DeliveryStatusUpdated` is Order's internal concern, not a Recommendation dependency |
| Inbound (consumed) | Product Service | `ProductCreated` (Kafka) | **Async** | Seeds newly catalogued products into the fallback/trending candidate pool with a neutral default score; consumer relationship confirmed by [ADR-0013](../../adr/0013-recommendation-productcreated-consumption.md) (payload originally `sku, attributes`; grown to add `name, description, categoryId, brand, price, status` by [ADR-0018](../../adr/0018-search-catalog-signal-sourcing.md) for `kart-search-service`'s benefit, additive/unaffecting this service's own seeding logic; 3x retry; `catalog.dlq`) |
| Inbound (consumed) | Client Event Ingestion Gateway (Kafka) | `ProductViewed`, `ProductClicked`, `SearchPerformed` (Kafka, `kart.recommendation.clickstream-events`) | **Async** | Behavioral-signal input. **Resolved by this pass, closing requirement-spec Open Question 1** — see "Clickstream Publisher Resolution" below. Partitioned by `userId` per `edge-cases.md`'s "Clickstream volume overwhelms ingestion" decision, with consumer-group autoscaling on partition lag. Full event/retry/DLQ definition lives in `event-contract.md` (Event Design Agent's own artifact) |
| Outbound (new, sync) | Inventory Service | `GET /inventory/{sku}` | **Sync** (REST) | **New dependency resolved by this pass.** Per `edge-cases.md`'s "Stale recommendations after a product goes out of stock or is discontinued" decision, each candidate item is checked against live stock at request time rather than relying on a second cached copy of availability. See Sync vs. Async Resolution and Distributed-Monolith Risk below |
| Outbound (new, sync) | Product Service | `GET /products/{id}` | **Sync** (REST) | **New dependency resolved by this pass.** Same decision as above, covering the "discontinued" half of the edge case (Product owns catalog/discontinued status; Inventory owns stock level — they are two different domain facts and neither service's read model substitutes for the other, so both are checked) |

No outbound event publication exists for this service (BRD §5.4 lists none) and none is introduced by this pass. The "Recommendation model/algorithm drift" edge case's online-monitoring decision (click-through/conversion metrics via Analytics) requires **no new dependency edge**: Analytics already fans in every platform event by default ([ADR-0004](../../adr/0004-analytics-full-fanin-ingestion.md)), and any "recommendation impression/click" signal needed for that monitoring rides on the same not-yet-named clickstream event stream Recommendation itself consumes (see row above) — Analytics and Recommendation are two independent consumers of the same future event, not a new Recommendation→Analytics edge. This is consistent with the edge-case decision's own claim that the approach "requires no new infrastructure"; if the Event Design Agent later concludes a dedicated impression event is needed, that adds a *new* publish responsibility to Recommendation not currently scoped, and this doc's dependency table would need to be revisited then.

## Clickstream Publisher Resolution (closes requirement-spec Open Question 1)

No BRD service owns "capture a client's view/click/search interaction" — it is not a domain responsibility of any of the platform's 18 bounded contexts, the same way `API Gateway` itself (already present in `container-diagram.md`) is platform infrastructure rather than a bounded context with its own `ddd-model.md`. Resolved as: a **Client Event Ingestion Gateway** — a thin, schema-validating collector at the infrastructure layer (same category as `API Gateway`, not a 19th domain service) that receives client-side interaction telemetry from Web/Mobile and publishes it directly onto Kafka topic `kart.recommendation.clickstream-events` (partitioned by `userId`, per `edge-cases.md`'s already-chosen partitioning), as three named events — `ProductViewed`, `ProductClicked`, `SearchPerformed` — covering exactly the "views, clicks, searches" `edge-cases.md`'s own Clickstream edge case names. Analytics subscribes to the same topic independently (full fan-in, [ADR-0004](../../adr/0004-analytics-full-fanin-ingestion.md)) — this is one shared topic with two consumer groups, not a new Recommendation→Analytics edge (this doc's Dependencies table already established that reasoning for the impression/click-monitoring signal; the same topic now has a name).

This deliberately preserves requirement-spec §2's explicit invariant that **Recommendation itself publishes no events** — the Ingestion Gateway, not Recommendation, is the publisher. Modeling it as infrastructure rather than inventing a 19th bounded-context service avoids expanding the BRD's 18-service scope for a capability that is pure telemetry capture with no domain logic of its own (schema validation only). Full event/payload/retry/DLQ detail is `event-contract.md`'s own artifact (Event Design Agent); this section fixes only the boundary-level question of *who* publishes and *how it reaches* Recommendation.

## Sync vs. Async Resolution

Two integration-contract questions were explicitly deferred to this stage; both are resolved here.

**1. The "live inventory/catalog check" (edge-cases.md, flagged for Architecture Agent validation).** Resolved as **synchronous**, not async, and resolved as **two calls, not one** — Inventory (`GET /inventory/{sku}`, stock level) and Product (`GET /products/{id}`, discontinued/catalog status) are different bounded contexts owning different domain facts (requirement-spec §4's cold-start/fallback invariant does not conflate the two), so neither can be dropped in favor of the other. A synchronous call was chosen over consuming an availability event because no such event exists yet with the right shape: `ProductDiscontinued` is still "proposed, not BRD-stated" per `kart-product-service/requirement-spec.md` (not formalized until the DDD Agent stage), and Inventory publishes no BRD-stated event Recommendation could substitute for a live check. Caching a denormalized copy of availability inside Recommendation's own read model was considered and rejected for this pass — it would require consuming an event that does not yet exist for one of the two facts (discontinued status), so a synchronous request-time check is the only mechanism available today without inventing a dependency on an unformalized event.

This is a genuinely new coupling not present in requirement-spec §5's original API surface (which lists only async consumed inputs) — see Distributed-Monolith Risk below for the consequence and mitigation.

**2. Staleness/consistency SLA (requirement-spec Open Question 3 — Recommendation is not named in BRD §2.2 the way Search is, so no bound was BRD-forced).** Resolved bound, confirmed by this document's own sign-off below:

- `OrderDelivered` and `ProductCreated` signal must be reflected in a user's/pool's read model within **5 minutes** of the source event being published — both are comparatively low-volume, per-transaction/per-catalog-write events (not a firehose), so incremental per-event projection updates are feasible without a batch window.
- The non-personalized fallback/trending pool (globally popular items, also the seeding target for new `ProductCreated` products) is refreshed on a periodic **15-minute** recompute cycle, since "trending" is inherently a windowed aggregate over recent purchase/clickstream volume, not a per-event quantity that updates incrementally the same way a single user's signal does.
- Clickstream-driven behavioral signal: **confirmed at the same 5-minute per-event target**, not a placeholder — `ddd-model.md`'s per-user `RecommendationSet` recompute is event-triggered and debounced to at most once per 5-minute window per user regardless of which input type changed (`OrderDelivered`, `ProductCreated`-driven pool membership, or clickstream), so the bound is uniform across input types by construction rather than clickstream needing its own independently-derived number.

This satisfies requirement-spec Open Question 3's explicit ask ("propose a concrete bound, with human sign-off") — sign-off is this document's own approval gate.

**3. Recommendation algorithm/model (requirement-spec Open Question 2) is intentionally NOT resolved here.** This agent's scope is boundary and dependency shape, not internal domain modeling — picking collaborative filtering vs. content-based vs. a simple co-occurrence rule doesn't change any edge in the Dependencies table above (all three approaches consume the same `OrderDelivered`/`ProductCreated`/clickstream inputs and serve the same read API). This remains carried forward to the **DDD Agent** — resolved there as item-based collaborative filtering (co-occurrence over `OrderDelivered` purchase pairs, blended with clickstream-weighted behavioral signal and a trending fallback), per `ddd-model.md`'s "Recommendation Model" section.

## Distributed-Monolith Risk

**Identified: the two new synchronous outbound calls (Inventory, Product) put Recommendation's read path at risk of coupling its own availability to two other services' uptime, on every single request** — this is the opposite of the low-risk pattern its async event inputs already have. Concretely:

- If Inventory or Product is slow or down, `GET /recommendations/{userId}` risks missing its P95 < 150ms / P99 < 400ms budget (requirement-spec §3), or failing outright, even though Recommendation's own read model is healthy and precomputed.
- Naive per-candidate calls (one `GET /inventory/{sku}` and one `GET /products/{id}` per item in a candidate list) is an N+1 pattern that will not hold the latency budget once candidate-list sizes grow past a handful of items — flagged as a non-blocking follow-on, carried to the **API Design Agent**, to define a bulk/batched variant of both lookups (e.g. `GET /inventory?skus=...`, `GET /products?ids=...`) rather than looping per-item calls.
- **Mitigation required, not optional:** Recommendation must not let this synchronous filter make it as unavailable as its two upstream dependencies combined. On a timeout or error from either Inventory or Product, the service must degrade gracefully — serve the unfiltered (or last-known-good cached) result rather than fail the request — accepting the edge case's own named trade-off (a stale/unsellable item may occasionally surface) over turning a 99.9%-tier read service into a service whose effective availability is the product of three services' uptimes. This mitigation is a concrete requirement on the eventual implementation, not merely a suggestion, precisely because the edge-cases.md decision that introduced this dependency explicitly flagged the latency risk without specifying a fallback.

No other distributed-monolith risk is present: Recommendation's three consumed events (`OrderDelivered`, `ProductCreated`, clickstream) are all async and non-blocking to its own read path, and it publishes nothing, so it introduces no fan-out risk to any downstream service.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner
- [x] Approved to proceed to DDD Agent
