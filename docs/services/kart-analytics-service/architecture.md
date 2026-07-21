---
doc_type: architecture
service: kart-analytics-service
status: pending-approval
generated_by: architecture-agent
source: [docs/services/kart-analytics-service/requirement-spec.md, docs/services/kart-analytics-service/edge-cases.md, docs/services/kart-analytics-service/design-decisions.md]
---

# Architecture: kart-analytics-service

## Boundary Rationale

`kart-analytics-service` is a **Generic Subdomain** in DDD terms — unlike Order/Payment/Inventory (Core) or Offer (Core-adjacent, "what does this customer pay," per [kart-offer-service/architecture.md](../kart-offer-service/architecture.md)), Analytics owns no transactional business concept of its own. Its bounded context is exactly two things: (1) an ingestion pipeline that durably and idempotently lands the platform's full event fan-in into a raw event store, and (2) a set of read models (dashboards/funnels, requirement-spec §6 D4a) computed from that raw store and served through an internal-only query surface (resolved below). It asserts no write authority over any other service's state — it publishes nothing (requirement-spec §2, verified against BRD §10's Publisher column: Analytics never appears there) — and Domain Invariant #4 (requirement-spec §4) guarantees ingestion failures on Analytics' side can never block or slow any publisher's own path.

This gives Analytics the strongest isolation posture of any service placed through this pipeline so far: **zero synchronous coupling in either direction.** There is no public inbound endpoint (BRD §5.4: "ingestion only") and no synchronous outbound call to any other service, ever. Its only integration surfaces are (a) async consumption of the full published event catalog — settled by [ADR-0004](../../adr/0004-analytics-full-fanin-ingestion.md), "every future new event automatically has Analytics as a consumer by default" — and (b) the internal dashboards/funnels query surface. Analytics is explicitly **not** an Order Saga participant (BRD §12 lists Inventory, Payment, and Shipping only); its involvement with any other service's domain is always after-the-fact and read-only.

## Dependencies

Analytics consumes the **full fan-in of every published platform event** (resolved contradiction — see [ADR-0004](../../adr/0004-analytics-full-fanin-ingestion.md); event rows added later by [ADR-0007](../../adr/0007-event-catalog-completeness.md)/[ADR-0008](../../adr/0008-event-catalog-completeness-round-2.md) are included). The table below groups by publishing bounded context rather than restating all ~24 individual event rows — the authoritative, exhaustive list is `kart-requirements.md` §10 itself; restating it here would just drift out of sync with it, the same reasoning the requirement-spec already applied (§5).

| Direction | Peer Service | Mechanism (representative events) | Type | Notes |
|---|---|---|---|---|
| Inbound (consumed) | Order | `OrderCreated`, `OrderConfirmed`, `OrderCancelled`, `OrderCompensationTriggered`, `OrderDelivered` | Async | |
| Inbound (consumed) | Inventory | `InventoryReserved`, `InventoryReservationFailed`, `InventoryReleased`, `InventoryReplenished` | Async | `InventoryReleased`/`InventoryReplenished` added to the catalog by ADR-0007 |
| Inbound (consumed) | Payment | `PaymentCompleted`, `PaymentFailed`, `RefundIssued` | Async | Money-moving tier upstream (5x retry/`payment.dlq`, per BRD §10) governs re-delivery *to* Analytics; Analytics' own ingestion-write-failure handling is a separate, Analytics-side decision (D5, below) |
| Inbound (consumed) | Shipping | `ShipmentDispatched` | Async | |
| Inbound (consumed) | Delivery Tracking | `DeliveryStatusUpdated` | Async | |
| Inbound (consumed) | Product | `ProductCreated`, `ProductPriceChanged` | Async | Publisher corrected from "Pricing" to "Product" by ADR-0008; consistent with `kart-offer-service/architecture.md`'s own reading |
| Inbound (consumed) | Review | `ReviewSubmitted` | Async | |
| Inbound (consumed) | Category | `CategoryUpdated` | Async | Added to the catalog by ADR-0008, Analytics-only consumer |
| Inbound (consumed) | Offer | `CouponRedeemed`, `PriceQuoteIssued`, `PromotionActivated` | Async | Confirmed Analytics-only consumer for the latter two, per `kart-offer-service/architecture.md`'s own Dependencies table |
| Inbound (consumed) | User | `UserProfileUpdated` | Async | Added to the catalog by ADR-0008, Analytics-only consumer |
| Inbound (consumed) | Identity | `UserRegistered`, `SessionCreated`, `UserAccountUpdated` | Async | `UserAccountUpdated`'s missing Analytics row was corrected by ADR-0008 |
| Inbound (consumed) | Notification | `NotificationSent` | Async | Fire-and-forget audit tier (1x retry) |
| Inbound (consumed) | Cart | `CartCheckedOut` | Async | Funnel/conversion tracking — feeds the Order Conversion Funnel (D4a); added to the catalog by ADR-0007 |
| Inbound (consumed) | Wishlist | `WishlistPriceAlertTriggered` | Async | Added to the catalog by ADR-0007 |
| Inbound (consumed) | Admin | `AdminActionPerformed` | Async | Audit trail (D4a's Admin Audit/Compliance dashboard); added to the catalog by ADR-0007 |
| Outbound (published) | — none — | — | — | Analytics publishes no event to the bus (requirement-spec §2/§5, verified against every Publisher column in BRD §10) |
| Inbound (internal only, not via public API Gateway) | Internal BI/ops/dashboard consumers | Internal REST query API (`/internal/v1/...`) + direct BI-tool connection to the warehouse | Sync, internal-only | Resolved below (D4b) — no public Gateway route exists for Analytics (BRD §5.4) |

## Resolved: Dashboards/Funnels Query Surface (requirement-spec §1/§5, Decision D4b)

The requirement-spec explicitly deferred the concrete query technology to this stage. Decision: an **internal-only REST API** (`/internal/v1/...`), following the platform's existing default REST convention (`agent-reusables/docs/standards/api-standards.md` — no GraphQL precedent exists anywhere else on this platform, and introducing one just for Analytics would add a second API style for no stated benefit). Endpoints serve the pre-aggregated dashboard/funnel read models enumerated in requirement-spec §6 D4a (e.g. `GET /internal/v1/funnels/order-conversion`, `GET /internal/v1/dashboards/revenue`) — a thin CQRS query layer per `agent-reusables/docs/standards/ddd-cqrs-standards.md`'s "read model always rebuildable from the write model + event log" default, with Analytics' own raw event store standing in as that source of truth (consistent with design-decisions.md's Idempotency Mechanism decision).

This API is **not** routed through the public API Gateway — BRD §5.4 gives Analytics no public endpoint at all — it is reachable only from an internal network segment (admin console, internal service-to-service calls, BI-tool data-source connector). For exploratory, non-D4a-named analysis, an analyst-facing BI tool connects read-only, directly to the warehouse's aggregate schema, bypassing the REST layer entirely; the concrete BI product (e.g. a Metabase/Looker-class tool) is an infrastructure pick for a later stage, not architecturally load-bearing here.

## Non-Functional Targets Proposed by This Stage (requirement-spec §6 item 6 — carried forward, pending human sign-off)

The requirement-spec explicitly left latency numbers undefined (no public request/response API for the BRD's P95/P99 read-path NFR to bind to) and asked this stage to propose concrete figures. Proposed:

- **Ingestion lag** (event published on Kafka → durably landed in the raw warehouse layer): **P95 < 60s, P99 < 5 min.** Consistent with the micro-batched-write, autoscaled-consumer-group design already decided (design-decisions.md, Concurrency/Scaling decision). This is an internal freshness target, not a customer-facing SLA.
- **Dashboard/funnel query latency** (internal REST layer, D4a's pre-aggregated tables only): **P95 < 2s, P99 < 5s.** Ad-hoc BI-tool queries against the raw/aggregate warehouse schema are explicitly excluded from this budget — they are exploratory, best-effort, not an operational target.
- **Reconciliation finalization:** the nightly batch reconciliation (edge-cases.md, "Out-of-Order Event Arrival" decision) completes by **06:00 UTC** daily; a day's dashboard/funnel figures carry a "provisional" flag until that run completes, then flip to final. This surfaces the eventual-consistency window explicitly (per `ddd-cqrs-standards.md`'s "surface, don't hide" rule) rather than presenting a fake-precise number in the interim.
- These are this stage's proposed numbers only — not BRD-sourced, not yet load-tested. They require explicit human sign-off before being treated as load-bearing, the same non-blocking carry-forward pattern the requirement-spec itself used for `kart-search-service`'s and `kart-recommendation-service`'s own unresolved SLAs.

## Distributed-Monolith Risk

- **None at the synchronous call-graph level — the strongest isolation posture on the platform so far.** Zero synchronous inbound calls, zero synchronous outbound calls. Analytics can be fully down without blocking any other service's write or read path; conversely, every other service being down simply means nothing to ingest for that window, not an error state for Analytics.
- **Real coupling exists, but at the schema-contract level, not the call graph.** Full fan-in (ADR-0004) means all ~15 publishing services now have a build-time dependency on Analytics' own schema registry and `BACKWARD`-compatibility gate (requirement-spec §6 D2) — a CI-time check that couples every publisher team's release process to a rule Analytics defined for itself. This was already accepted as a deliberate trade-off in requirement-spec §6 item 2 and is not re-litigated here; it is flagged because it is real cross-team process coupling hiding behind an otherwise fully decoupled runtime call graph, and worth the DDD/Event Design Agents keeping visible.
- **Operational risk is self-contained, not propagating.** At full-fan-in burst volume (flash-sale scenario), a stalled warehouse write only backs up Analytics' own consumer group and `analytics.dlq` — Domain Invariant §4's offset-commit-after-write-or-DLQ rule prevents this from ever propagating backpressure to upstream brokers or publishers. The consequence lands entirely on Analytics' own dashboards going stale until the scheduled reprocessor drains `analytics.dlq` (design-decisions.md, Resilience Pattern decision) — a monitoring/alerting concern for later stages, not a distributed-monolith risk in the classic sense (no other service's call path is ever blocked).

## Sign-off

- [ ] Reviewed by:
- [ ] Approved to proceed to DDD Agent
