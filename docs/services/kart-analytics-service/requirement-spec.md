---
doc_type: requirement-spec
service: kart-analytics-service
status: approved
generated_by: requirement-agent
source: docs/requirements/kart-requirements.md
---

# Requirement Spec: kart-analytics-service

## 1. Scope

Covers a single BRD service: **Analytics Service** (BRD §2.1 item 19, "Event ingestion, dashboards, funnels"). No merge — unlike Offer, there is no existing ADR bundling Analytics with another bounded context, and nothing in the BRD suggests one.

Analytics is unusual among the platform's services in that the BRD gives it no public write API and, per §5.4, no request-driven read API either ("(ingestion only)") — its entire external surface is consuming events and (implicitly) serving dashboards/funnels from the resulting warehouse. The BRD does not describe how dashboards/funnels are actually served (API, BI tool, internal query layer) — see Open Questions.

## 2. Functional Requirements

- Ingest domain events published across the platform's event bus into a data warehouse via Kafka topics (BRD §5.4: "Kafka topics → warehouse").
- Consume events fan-in from (per §5.4's condensed row) "all events" — but the Event Catalog (§10) only explicitly lists Analytics as a consumer for a subset: `OrderCreated`, `PaymentCompleted`, `DeliveryStatusUpdated`, `ReviewSubmitted`, `CouponRedeemed`, `NotificationSent`. This is a contradiction between the two BRD sections — see Open Questions; do not assume either reading silently.
- Produce dashboards and funnels (BRD §2.1 item 19) from ingested event data. The BRD names this responsibility but does not enumerate which dashboards or which funnels — see Open Questions.
- Support reprocessing (replay) of historical events from the durable event log — the BRD's own justification for putting Analytics on Kafka is a concrete replay scenario: "Analytics needs to reprocess 30 days of `OrderCreated` after a bug fix" (BRD §14).
- Be the first consumer migrated in the RabbitMQ→Kafka strangler migration, ahead of Recommendation, "since it's the one hitting RabbitMQ's replay limitation" (BRD §15).
- Publish nothing back to the bus — the BRD lists no event published by Analytics anywhere in §5.4 or the §10 Event Catalog. Analytics is consumer-only.

## 3. Non-Functional Requirements

Pulled from the BRD's global NFR table (§3), scoped to this service:

| Attribute | Target | Applies here because |
|---|---|---|
| Reliability | At-least-once delivery + idempotent consumers; no data loss on Order/Payment events | Analytics is a listed consumer of `OrderCreated` and `PaymentCompleted` (§10), both covered by the global "no data loss on Order/Payment events" NFR |
| Consistency | Eventual | Analytics is purely a read/reporting sink fed by an async event bus — never a strongly-consistent write path |
| Throughput | Must absorb the aggregate fan-in of every publishing service, not just one event stream | §14 names Analytics explicitly as the service whose fan-in ("10+ consumer groups per event") pushes RabbitMQ past its throughput ceiling, and §15 confirms Analytics needs "high-throughput partitioned consumption" |
| Maintainability | Versioned events | Global NFR row states events must be versioned platform-wide; directly reinforced for Analytics specifically by §2.2's "forces a durable event bus and schema versioning discipline" |
| Availability | Not specified for this service | The BRD's 99.99%/99.9% split is stated only for "order path" vs. "secondary" and does not name Analytics either way — see Open Questions |
| Latency | Not specified for this service | The BRD's P95/P99 latency budgets are framed around request/response read and write paths; Analytics has no public API (§5.4: "ingestion only"), so it's unclear whether/how this NFR applies to dashboard queries — see Open Questions |

## 4. Domain Invariants

- Every ingested event must carry (or be resolvable to) a schema version, and the ingestion pipeline must tolerate multiple schema versions of the same event type in flight at once — the direct consequence of BRD §2.2's "Analytics ingests every domain event → forces a durable event bus and schema versioning discipline." The BRD asserts the discipline is required but does not define the versioning scheme itself (see Open Questions).
- The event log Analytics reads from must be durable and replayable (not consume-and-discard) — inferred from §14's stated RabbitMQ limitation ("no native replay... queues are consumed and gone") being the explicit reason Analytics moved to Kafka.
- Reprocessing historical events (replay) must not corrupt or double-count already-computed dashboard/funnel aggregates — inferred from the combination of the §14 replay scenario and the global "at-least-once delivery + idempotent consumers" NFR (§3), which applies to Analytics as a consumer like any other.
- Analytics must not be able to affect any other service's state or trigger side effects — it publishes no events (§10/§5.4 list none), so ingestion failures on Analytics' side must never block or slow the publishers whose events it fans in from.

## 5. API Surface (from BRD, starting point only)

| Endpoint/Event | Direction | Notes |
|---|---|---|
| (none) | Inbound API | BRD §5.4 states "(ingestion only)" — no public endpoint listed |
| `OrderCreated` | Consumed | Published by Order (BRD §10) |
| `PaymentCompleted` | Consumed | Published by Payment (BRD §10) |
| `DeliveryStatusUpdated` | Consumed | Published by Delivery Tracking (BRD §10) |
| `ReviewSubmitted` | Consumed | Published by Review (BRD §10) |
| `CouponRedeemed` | Consumed | Published by Coupon (BRD §10) |
| `NotificationSent` | Consumed | Published by Notification (BRD §10) |
| all other domain events | Consumed (disputed) | §5.4's condensed row claims "all events (fan-in)"; §10's Event Catalog does not list Analytics against `OrderConfirmed`, `OrderCancelled`, `InventoryReserved`, `InventoryReservationFailed`, `PaymentFailed`, `ShipmentDispatched`, `ProductCreated`, or `ProductPriceChanged` — see Open Questions |
| Dashboards / funnels query surface | Outbound (implied) | Not specified anywhere in the BRD — no endpoint, BI tool, or query API named |

Final contract is the API Design Agent's job, not this spec's.

## 6. Open Questions / Flagged Ambiguities

1. **"All events" vs. the Event Catalog — contradiction.** BRD §5.4 states Analytics consumes "all events (fan-in)," but the §10 Event Catalog only lists Analytics as a consumer for 6 of the 13 cataloged events. Reading A: §5.4 is authoritative and Analytics fans in every event, with §10 simply omitting Analytics from its consumer lists for brevity. Reading B: §10 is authoritative (it's the more granular, per-event source) and §5.4's "all events" is loose summary language, meaning Analytics genuinely only ingests the 6 named events today. This materially changes ingestion scope and cannot be silently resolved here.
2. **Schema versioning/evolution policy is asserted but undefined.** §2.2 states Analytics "forces... schema versioning discipline," but the BRD never specifies the scheme: envelope version field, schema registry, compatibility rules (backward/forward), or how a downstream breaking change from a publisher would be caught before it reaches Analytics. Left for the Event Design/Architecture Agent stages.
3. **Warehouse retention window for raw events is unstated.** §14 cites reprocessing "30 days of `OrderCreated`" as an anecdote explaining why RabbitMQ doesn't work, not as a stated retention requirement. There is no BRD-defined retention policy (30 days, 90 days, indefinite) for either the Kafka topics or the warehouse itself.
4. **Specific dashboards/funnels are not enumerated.** §2.1 names the responsibility ("dashboards, funnels") but no BRD section lists which business metrics, funnel stages, or dashboards are actually required — this blocks any concrete data-model or query-layer design downstream.
5. **Analytics' own consumer-side failure handling is undefined.** The §10 Event Catalog defines retry/DLQ policy per *publisher* (e.g., `payment.dlq`, `coupon.dlq`), but nothing addresses what happens when Analytics itself fails to write an ingested event to the warehouse — no analytics-side DLQ or retry policy is named.
6. **Availability/latency SLA tier is unstated.** The BRD's NFR table splits availability into "order path" (99.99%) and "secondary" (99.9%) without naming Analytics in either bucket, and its latency budgets are framed around request/response paths that don't obviously apply to an ingestion-only, no-public-API service. Carried to the Architecture Agent to assign a tier.

## Sign-off

- [ ] Blocking open questions resolved
- [ ] Reviewed by:
- [ ] Approved to proceed to Architecture Agent
