---
doc_type: tickets
service: kart-analytics-service
status: draft
generated_by: ticket-agent
source: [architecture.md, api-contract.yaml, database-design.md, event-contract.md, design-decisions.md, requirement-spec.md, edge-cases.md — no ddd-model.md exists for this service, see note below]
---

# Tickets: kart-analytics-service

Local draft. Not yet created as real GitHub Issues — that requires the target repo to exist (Project Scaffold Agent) and is a separate, explicit step.

**No `ddd-model.md` input for this service (documented precedent, not a gap):** `database-design.md`'s own header note (restated by `event-contract.md`) records that Analytics is a **Generic Subdomain** with no transactional aggregate root of its own beyond "the raw ingested event" and "the derived read model" — narrow enough that `architecture.md`, `database-design.md`, and `event-contract.md` were all designed directly from `requirement-spec.md`/`edge-cases.md`/`design-decisions.md` without a dedicated DDD-Agent pass, the same precedent already used by `kart-admin-service`. This decomposition follows that same reasoning rather than blocking on a doc this service was never going to produce.

**Approval-checkbox flag (carried forward, not blocking):** `architecture.md`, `design-decisions.md`, `database-design.md`, and `event-contract.md` all still carry an unchecked sign-off checkbox (frontmatter `status: pending-approval`) even though `requirement-spec.md` and `edge-cases.md` are now fully closed (`status: approved`, all former Open Questions resolved via ADR-0004 and D2/D3/D4a/D4b/D5/D6a) and every downstream doc is internally consistent with them — each of those four docs says so explicitly in its own header. `api-contract.yaml` is the one doc already `approved` (no prior published contract to break). This ticket list is decomposed directly from all four docs' already-decided content; no open question in any of them blocks right-sizing the work below. Re-confirm against those four once a human checks their sign-off boxes — no substantive rework is expected.

## Epic: kart-analytics-service v1

Ingestion-only, publish-nothing Generic Subdomain (`architecture.md` Boundary Rationale): a schema-registry-gated, idempotent full-platform-event-fan-in pipeline (ADR-0004) landing into a raw PostgreSQL event store, plus ten pre-aggregated MongoDB dashboard/funnel read models (requirement-spec.md §6 D4a) served through an internal-only query API (`api-contract.yaml`). No public API Gateway route, no synchronous outbound call, no published event.

| ID | Task | Vertical Slice (Application/Features/) | Depends On | Design Source |
|---|---|---|---|---|
| ANL-1 | Ingest a platform event into the raw store | `IngestEvent` | — | `event-contract.md` "Consumed Events — Full Fan-In (ADR-0004)" (all 34 rows, single generic handler keyed by `event_type`/schema, not per-event code); `database-design.md` `analytics_raw_events` (idempotent upsert on `event_id`); `design-decisions.md` "Serialization Format & Schema Governance" (Confluent-compatible registry, Avro, `BACKWARD` compatibility, tolerant-reader fallback) |
| ANL-2 | Handle ingestion write failure (retry + DLQ) | `HandleIngestionWriteFailure` | ANL-1 | `event-contract.md` "Analytics' Own Consumer-Side Retry/DLQ — Post-Ingestion Write-Failure Handling (D5)"; `database-design.md` `analytics_dlq_events`; `design-decisions.md` "Resilience Pattern" (3x exponential backoff, then `analytics.dlq`, offset committed only after write-or-DLQ-handoff) |
| ANL-3 | Reprocess DLQ'd events | `ReprocessDlqEvents` | ANL-2 | `database-design.md` `analytics_dlq_events` + `idx_analytics_dlq_events_pending`; requirement-spec.md §6 D5 ("scheduled reprocessor... same replay tooling as the BRD's own 30-day reprocessing scenario," BRD §14) |
| ANL-4 | Redact PII on `UserDataErased` | `RedactUserPii` | ANL-1 | `database-design.md` "PII Redaction on `UserDataErased`" (redact-in-place, not hard-delete/tag-only), `analytics_pii_redactions`, `idx_analytics_raw_events_pii_pending`; ADR-0016 item 6 |
| ANL-5 | Nightly reconciliation job framework | `RunNightlyReconciliation` | ANL-1 | `database-design.md` `analytics_reconciliation_runs` (UNIQUE `run_date`); edge-cases.md "Out-of-Order Event Arrival" decision (event-time watermarks + nightly batch recompute); architecture.md "Non-Functional Targets" (06:00 UTC completion target, `DashboardEnvelope.isProvisional`/`reconciledThrough`) |
| ANL-6 | Order conversion funnel | `GetOrderConversionFunnel` | ANL-1, ANL-5 | `api-contract.yaml` `GET /internal/v1/funnels/order-conversion`; `database-design.md` `order_conversion_funnel`; requirement-spec.md §6 D4a (`CartCheckedOut`→`OrderCreated`→`OrderConfirmed`→`PaymentCompleted`→`OrderDelivered`) |
| ANL-7 | Revenue dashboard | `GetRevenueDashboard` | ANL-1, ANL-5 | `api-contract.yaml` `GET /internal/v1/dashboards/revenue`; `database-design.md` `revenue_dashboard` |
| ANL-8 | Fulfillment performance dashboard | `GetFulfillmentPerformanceDashboard` | ANL-1, ANL-5 | `api-contract.yaml` `GET /internal/v1/dashboards/fulfillment-performance`; `database-design.md` `fulfillment_performance_dashboard` |
| ANL-9 | Inventory movement dashboard | `GetInventoryMovementDashboard` | ANL-1, ANL-5 | `api-contract.yaml` `GET /internal/v1/dashboards/inventory-movement`; `database-design.md` `inventory_movement_dashboard` |
| ANL-10 | Catalog/pricing dashboard | `GetCatalogPricingDashboard` | ANL-1, ANL-5 | `api-contract.yaml` `GET /internal/v1/dashboards/catalog-pricing`; `database-design.md` `catalog_pricing_dashboard` |
| ANL-11 | Promotions effectiveness dashboard | `GetPromotionsEffectivenessDashboard` | ANL-1, ANL-5 | `api-contract.yaml` `GET /internal/v1/dashboards/promotions-effectiveness`; `database-design.md` `promotions_effectiveness_dashboard` |
| ANL-12 | User growth dashboard | `GetUserGrowthDashboard` | ANL-1, ANL-5 | `api-contract.yaml` `GET /internal/v1/dashboards/user-growth`; `database-design.md` `user_growth_dashboard` |
| ANL-13 | Reviews & ratings dashboard | `GetReviewsRatingsDashboard` | ANL-1, ANL-5 | `api-contract.yaml` `GET /internal/v1/dashboards/reviews-ratings`; `database-design.md` `reviews_ratings_dashboard` |
| ANL-14 | Admin audit dashboard | `GetAdminAuditDashboard` | ANL-1, ANL-5 | `api-contract.yaml` `GET /internal/v1/dashboards/admin-audit`; `database-design.md` `admin_audit_log` |
| ANL-15 | Notification delivery dashboard | `GetNotificationDeliveryDashboard` | ANL-1, ANL-5 | `api-contract.yaml` `GET /internal/v1/dashboards/notification-delivery`; `database-design.md` `notification_delivery_dashboard` |

## Notes for Sprint Planner Agent

- ANL-1 is the single foundation task (schema-registry client, tolerant reader, idempotent upsert into `analytics_raw_events`) — every other task depends on it directly or transitively. Start it first, alone.
- ANL-2, ANL-4, and ANL-5 depend only on ANL-1 and can run in parallel once it lands.
- ANL-3 depends on ANL-2 (needs `analytics_dlq_events` populated before there is anything to drain).
- ANL-6 through ANL-15 (the ten dashboard/funnel query slices) each depend only on ANL-1 and ANL-5 (the raw store plus the shared reconciliation-run bookkeeping that backs every response's `isProvisional`/`reconciledThrough` fields) — all ten are independent of each other and of ANL-2/ANL-3/ANL-4, so they can be parallelized across as many sprints/engineers as capacity allows once ANL-1 and ANL-5 are done.
- No circular dependencies in this graph; longest chain is ANL-1 → ANL-2 → ANL-3 (3 deep) and ANL-1 → ANL-5 → any of ANL-6..15 (3 deep).
- ANL-4 (PII redaction) is compliance-critical (ADR-0016) — recommend sequencing it early even though nothing else structurally depends on it.
