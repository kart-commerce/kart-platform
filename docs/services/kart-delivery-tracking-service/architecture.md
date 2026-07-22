---
doc_type: architecture
service: kart-delivery-tracking-service
status: approved
generated_by: architecture-agent
source: docs/services/kart-delivery-tracking-service/requirement-spec.md, docs/services/kart-delivery-tracking-service/edge-cases.md, docs/services/kart-delivery-tracking-service/design-decisions.md
---

# Architecture: kart-delivery-tracking-service

## Boundary Rationale

`kart-delivery-tracking-service` is the bounded context that answers "where is this shipment right now, and when will it arrive" (BRD §2.1 item 17). Like Search and Product, it maps 1:1 onto a single BRD service with no merge, so no ADR is required to justify its boundary (requirement-spec §1).

It is a **secondary-path, non-critical** service: BRD §5.5's diagram places it only as a Bus fan-out consumer, not a participant in the Order Saga (§12) alongside Inventory/Payment/Shipping (requirement-spec §3, Availability row — 99.9%, not the order path's 99.99%). It is Phase 2 ("Fulfillment & Discovery") in the platform's phased rollout (`PLATFORM_BLUEPRINT.md` §2.4/§2.5), and — per `docs/services/README.md`'s recommended build order — it has **zero synchronous Kart-peer dependencies**, which is why it is sequenced early (#4) despite being "downstream" conceptually: Order later depends on it (async), but it depends on no other Kart service to start serving traffic (its own tracking store is simply empty until `ShipmentDispatched` starts arriving).

Two boundary traits make this service structurally different from every other bounded context placed so far:

1. **No PostgreSQL write side.** requirement-spec §2/§5.4 names MongoDB as this service's only store — there is no client-initiated write command against a domain aggregate the usual way. The entire tracking record is a materialized view assembled from two external triggers: consuming `ShipmentDispatched` (creates the addressable `trackingId` record) and carrier webhooks/polling (updates it). `GET /tracking/{id}` is this service's only client-facing surface, and it is a pure read. This is a deliberate, already-approved exception to the platform's general CQRS default ("write model is always PostgreSQL," `agent-reusables/docs/standards/ddd-cqrs-standards.md`) — flagged explicitly here so the DDD Agent designs the aggregate as an event/webhook-fed read-side projection with no fictitious write-side counterpart, rather than forcing a PostgreSQL write model that doesn't exist for this service.
2. **Its busiest integration surface is external, not a Kart peer.** Unlike every other service in the graph so far, this service's single largest source of inbound traffic is third-party carrier webhooks/APIs (requirement-spec §5's `POST /internal/webhooks/carriers/{carrierId}`), not another bounded context. This is a real architectural dependency (it drives the service's resilience posture, integration surface count, and ops load) even though it never appears as a Kart-service node in `service-boundaries.md`/`container-diagram.md`.

## Dependencies

| Direction | Peer | Mechanism | Type | Notes |
|---|---|---|---|---|
| Inbound (client, via API Gateway) | Client / Mobile / Web | `GET /tracking/{id}` | **Sync** (REST) | Read-path only, P95<150ms/P99<400ms (requirement-spec §3). Returns `202 Accepted`/`PENDING` rather than `404` for the pre-materialization race window (requirement-spec §5/§6, edge-cases.md — already resolved, not reopened here). |
| Inbound (consumed) | Shipping | `ShipmentDispatched` | **Async** | Aggregate-creation trigger for the tracking record (requirement-spec §2, Domain Invariants — resolved relationship, confirmed not re-litigated here). No bootstrap dependency: if Shipping is down, Tracking simply has nothing new to materialize; it does not block Tracking's own availability. |
| Inbound (external — not a Kart service) | Per-carrier webhook senders (N carriers) | `POST /internal/webhooks/carriers/{carrierId}` | **Async** (third-party HTTP push, outside the internal RabbitMQ bus) | This service's own API-surface addition, resolved at requirement-spec stage (§5, was Open Question #1). HMAC-SHA256-verified, then durably enqueued onto internal RabbitMQ before the webhook handler acks (design-decisions.md's ingestion-buffering decision) — an external system boundary, not a peer-service edge. |
| Outbound (external — not a Kart service) | Per-carrier tracking APIs (N carriers) | Scheduled polling, 6h staleness threshold | **Sync** (REST, outbound) | Backstop for webhook silence (edge-cases.md, "Carrier Webhook Failure or Silence"). Per-carrier circuit breaker + bulkhead isolation already chosen (design-decisions.md) so one unreliable carrier's polling can't starve the scheduler capacity needed for every other carrier. See Capacity Note below. |
| Outbound (published) | Order (terminal `"delivered"` status only), Notification, Analytics | `DeliveryStatusUpdated` (`trackingId, status`) | **Async** | See "Consumer-Set Correction" below — the current, authoritative consumer set (BRD §10, [ADR-0005](../../adr/0005-unify-order-terminal-event.md)) includes Order, not just Notification/Analytics. `status` is always the canonical internal enum, never a raw carrier code, never `PENDING`/`UNKNOWN` (edge-cases.md). |

### Consumer-Set Correction (Order added to `DeliveryStatusUpdated`)

`DeliveryStatusUpdated`'s consumer set includes Order (terminal `"delivered"` status value only, triggering Order's own `OrderDelivered` publish) per [ADR-0005](../../adr/0005-unify-order-terminal-event.md) — `kart-requirements.md` §10's Event Catalog and `kart-order-service/requirement-spec.md` already reflect this. This service's own `requirement-spec.md` (§2, §5) previously listed "Notification and Analytics" only, predating that ADR; it has since been corrected to match this table during the requirement-spec/edge-cases closure pass, so the two documents are no longer in tension on this point. Nothing about this changes this service's own publish contract or payload — Order simply filters client-side to the terminal status, same as it already does per its own docs.

## Consistency / Staleness SLA (resolves requirement-spec §6 item 5)

requirement-spec §6 item 5 explicitly left the numeric consistency/staleness SLA open and carried it forward to this stage ("the same way a final numeric latency target is normally [the Architecture Agent's] job"). Resolved here as a single-service engineering default, grounded in BRD §7's general "eventual-consistency windows are typically sub-second" baseline plus the concrete ingestion pipeline design-decisions.md already fixed:

- **Target: P95 < 2s, P99 < 5s** from carrier-webhook receipt (post-HMAC-verification ack) to the corresponding status being durably persisted in MongoDB and reflected by `GET /tracking/{id}`.
- This budget is set slightly above BRD §7's "sub-second" baseline, not below it, because it must honestly cover one real queue hop that design-decisions.md's ingestion-buffering pattern introduces (webhook handler → RabbitMQ → async processing consumer → dedup/ordinal-check/mapping → Mongo write) — inventing a sub-second number here would silently ignore that hop's own latency cost.
- There is no cache layer in front of `GET /tracking/{id}` (design-decisions.md's caching decision) — once a status is persisted, reads are immediately consistent with it; this SLA is entirely about ingestion-pipeline latency, not read-side cache lag.
- This does not apply to the polling-fallback path, whose staleness bound is the already-fixed 6-hour trigger threshold (edge-cases.md) — a structurally different, much looser bound for a structurally different failure mode (webhook silence, not normal-path processing latency).

## Distributed-Monolith Risk

**None identified among Kart peer services.** This service has zero synchronous outbound calls to any other Kart service. Its one inbound event dependency (`ShipmentDispatched`) is async and non-blocking in both directions — Tracking's own availability doesn't depend on Shipping being up, and Shipping's own critical path doesn't wait on Tracking consuming anything. Order's new dependency on this service ([ADR-0005](../../adr/0005-unify-order-terminal-event.md), consuming `DeliveryStatusUpdated` to detect terminal delivery) is likewise one-directional and async — it does not pull Tracking into the Order Saga, and Order's own docs already frame that consumption as a non-blocking bus fan-out read, not a synchronous call.

**The real architectural risk here is external-integration surface, not inter-service coupling.** This service now owns two independent per-carrier client surfaces — the inbound webhook receiver and the outbound polling fallback — against however many carriers the platform integrates with, both already flagged by design-decisions.md as added scope the BRD doesn't size. This is a genuine capacity-planning concern for whoever builds this service, but it is explicitly *not* a distributed-monolith pattern (no Kart service becomes unable to function without another Kart service being up as a result of it).

### Capacity Note — Per-Carrier Polling Client

design-decisions.md already chose the resilience pattern for this surface (per-carrier circuit breaker + bounded per-call timeout, bulkhead-isolated so one carrier's open circuit can't consume scheduler capacity needed for another carrier's polling) and explicitly flagged the concrete tuning thresholds (failure count to open, half-open probe interval) as having "no real per-carrier reliability data yet to tune them against." This stage affirms that pattern is the correct resilience boundary and does not re-litigate it or invent tuning numbers ahead of real per-carrier data — the number of carriers to budget concurrent polling workers for is itself a product/ops decision (how many carriers the platform actually integrates with), not something this spec or this stage can size without that input.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner
- [x] Approved to proceed to DDD Agent
