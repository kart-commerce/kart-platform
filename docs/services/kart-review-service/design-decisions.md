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

## Decision: Observability & Instrumentation

**Decision:** Serilog (structured logging) + OpenTelemetry SDK (distributed tracing + metrics), per the platform's reusable observability-standards.md and this repo's kart-conventions.md Observability section. Logs export via OTLP → Grafana Loki; traces via OTLP → Grafana Tempo; metrics scraped by Prometheus from `/metrics`; Grafana provides dashboards and alerting. Wired once via the shared `Kart.Shared.Observability` package, not reimplemented per service.

**Options considered:**
- Ad-hoc per-service logging/APM tool choice — rejected: fragments dashboards/alerting across 18 services and breaks single-trace-id correlation across the platform.
- Platform-standard Serilog + OpenTelemetry + Grafana LGTM stack — adopted: one mental model and one Grafana pane across every service.

**Why:** Review is not one of the four 100%-trace-coverage saga services, so it runs the reusable standard's default sampling (100% of error traces, a smaller percentage of successful ones) rather than a dedicated tier; `reviewId` is the correlation field carried on every log/span/exemplar, matching the id already threaded through `ReviewSubmitted`'s payload so a trace for a submission, moderation-queue hold, or aggregate update all pivot on the same key. One concrete signal worth a dashboard panel: the moderation-filter call's own span duration and the queued-vs-auto-published split rate, since that synchronous call sits inside the write-path latency budget (§3) and its own resilience pattern (fail-safe-to-queue on timeout, see the Decision above) is exactly the kind of degraded path the `Warning`-level log convention exists to surface.

## Decision: Global Exception Handling & Consistent Response Model

**Decision:** A single global exception-handling middleware (ASP.NET Core `IExceptionHandler`/`UseExceptionHandler`) is the only place this service catches and translates unhandled exceptions into an HTTP response — no `Handler`/controller/domain code wraps business logic in try/catch purely to log-and-rethrow or log-and-return an error. Every error response (validation failure or unhandled exception) is shaped as an RFC 7807 `ProblemDetails` envelope extended with the platform's standard fields (`traceId`, `errorCode`); every success response follows the same consistent envelope convention as every other Kart service. Both the middleware and the `ProblemDetails` factory are wired once via the shared `Kart.Shared.ErrorHandling` package, not reimplemented locally.

**Options considered:**
- Per-handler/controller try/catch translating exceptions to a response inline — rejected: duplicates translation logic per endpoint, risks inconsistent status-code/response-shape choices across handlers, and produces double-logging (or missed logging) when a local catch and the global handler both react to the same exception.
- Platform-standard global exception handler + `Kart.Shared.ErrorHandling`-wired `ProblemDetails` envelope — adopted: one place to change the error shape platform-wide, and a response contract every client (web, admin, partner API) can parse identically regardless of which of the 18 services it's calling.

**Why:** matches the same "one platform-wide implementation, not built locally by each service" pattern already applied to `Kart.Shared.Observability` and `Kart.Shared.Auditing` above — reimplementing exception translation per service is the identical per-service-drift failure mode those decisions already reject. Domain/business errors continue to use the Result/Either pattern (`agent-reusables/docs/standards/api-standards.md`) rather than exceptions; the global handler exists for the genuinely exceptional case (an unhandled infrastructure fault), and logs it exactly once — at `Error` level, tagged with `traceId`/`service` and this service's own primary correlation field named in its Observability & Instrumentation decision above — through the same Serilog/OTel pipeline, never a second, ad-hoc log line from a local catch block.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner
- [x] Approved to proceed to Architecture Agent
