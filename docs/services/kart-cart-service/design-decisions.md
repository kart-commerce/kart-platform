---
doc_type: design-decisions
service: kart-cart-service
status: approved
generated_by: design-decision-agent
source: docs/services/kart-cart-service/requirement-spec.md, docs/services/kart-cart-service/edge-cases.md, docs/adr/0016-user-gdpr-erasure-policy.md
---

# Design Decisions: kart-cart-service

Cross-cutting technology/design-pattern choices this service's approved `requirement-spec.md` and `edge-cases.md` force. Service boundaries, domain model, and schema are out of scope here (Architecture/DDD/Database Design Agents). Decisions already made at the requirement/edge-case stage (D1–D5) are referenced, not re-derived, except where they generalize into a pattern choice not yet made explicit.

## Decision: Caching Strategy for Cart State (PostgreSQL write + MongoDB read + Redis cache-aside) — Amended

- **Requirement driving this:** FR §2 "store cart state in Redis with a PostgreSQL snapshot" (BRD §5.4/§16); NFR §3 Consistency (amended — see requirement-spec.md); Domain Invariant §4 "an expired cart must eventually be reclaimed"; **project-owner directive to follow the platform's general PostgreSQL-write/MongoDB-read CQRS pattern (BRD §6.2/§7) with a sharded, denormalized read model.**
- **Options considered (3):** (a) original write-through Redis directly over PostgreSQL, no Mongo · (b) PostgreSQL write + sharded MongoDB denormalized read model (via Outbox-driven projection poller, `kart-user-service`/`kart-product-service` precedent) + Redis cache-aside in front of Mongo · (c) MongoDB as the sole store, no PostgreSQL.
- **Decision:**
  - Chosen: (b). PostgreSQL remains the sole write-side source of truth (unchanged: RLS, optimistic concurrency, Transactional Outbox). A sharded `cart_read_model` MongoDB collection is projected asynchronously from PostgreSQL via the same in-process Outbox-projection-poller mechanism already proven in this platform. Redis sits as a cache-aside layer in front of the Mongo read model (not write-through over Postgres) for the `GET /v1/cart` hot path, TTL-based, populated on miss and proactively refreshed by every mutating endpoint's own response.
  - Why: (a) no longer matches the platform-consistency goal the project owner set for this rebuild — every other read-heavy Kart service follows PostgreSQL-write/MongoDB-read CQRS, and Cart's throughput target (100K–1M RPS) benefits from a horizontally-shardable, independently-scalable read store the same way. (c) is rejected for the same reason the original D5 rejected Redis-as-primary: a single eventually-consistent store with no strongly-consistent write path would risk lost/conflicting writes under concurrent mutation, which optimistic concurrency on the PostgreSQL row (this doc's own next decision) is specifically designed to prevent.
  - Trade-off accepted: `GET /v1/cart` can now observe sub-second staleness from a separate session/device (the platform's standard, accepted CQRS trade-off, BRD §7) — mitigated for the common case by every mutating endpoint proactively refreshing the Redis key with its own fresh PostgreSQL result, so a same-session follow-up read is not stale in practice. A guest cart still has no recovery path once past 7 days idle, unchanged from the original decision.
  - Mirrors: `requirement-spec.md` §6 D1/D5 (amended); `database-design.md`'s "MongoDB Read Model (CQRS Query Side) — Amendment" and "Cache (Redis) — Cache-Aside" sections; `edge-cases.md` → "Cart lost on Redis eviction or restart" and "Abandoned-cart expiry races a returning user" (both still resolved by the unchanged PostgreSQL-authoritative write side and TTL mechanism).

## Decision: Concurrency Control for Cart Mutations and Merge

- **Requirement driving this:** Domain Invariant §4 — merge must not silently lose either cart's state (resolved sum+union, Decision D2) and a cart has a bounded maximum size (100 line items, Decision D4); NFR §3 Consistency = Strong.
- **Options considered (3):** optimistic concurrency via a version/row-version column on the cart aggregate, rejected writes surfaced as a conflict for the client to retry · pessimistic row-level lock held for the duration of the mutation transaction · distributed lock (e.g. Redlock) taken on the cart's key before any mutation or merge proceeds.
- **Decision:**
  - Chosen: optimistic concurrency control — a version column on the cart row, checked and incremented on every write (direct mutation or merge); a version mismatch is rejected and surfaced to the caller as a conflict to retry.
  - Why: write-through (this doc's caching decision) already commits to PostgreSQL synchronously on every mutation, so the version check is a free addition to a transaction that already exists; cart mutation volume is low (BRD §4.1: ~3.2 items/cart average), so lock contention is not a real risk, making the added latency/complexity of a pessimistic hold or an external distributed lock unjustified. This is what prevents two concurrent writers (e.g. a direct `/cart` mutation racing the login-time `/cart/merge`) from producing a lost update that would otherwise silently violate D2's non-lossy-merge invariant or D4's 100-item cap.
  - Trade-off accepted: a client that loses the optimistic race must retry the mutation (surfaced as a conflict response) rather than the write silently blocking until a lock frees up — acceptable given how rare genuine concurrent writes to the same cart are expected to be.

## Decision: Reliable Event Publication and Idempotent Event Consumption

- **Requirement driving this:** NFR §3 Reliability — "at-least-once delivery + idempotent consumers," explicitly applying to both `CartCheckedOut` publication and `InventoryReservationFailed` consumption (Decision D3).
- **Options considered (3, publish side):** Transactional Outbox (event row written in the same transaction as the state change, relayed by a separate publisher) · dual-write (publish directly to the broker in the same request path, no Outbox) · best-effort at-least-once via broker confirms only, no local durability record.
- **Decision:**
  - Chosen (publish): Transactional Outbox for `CartCheckedOut`. Chosen (consume): no separate dedup/inbox table for `InventoryReservationFailed` — Decision D3's handling (flag a line item unavailable, no-op post-checkout) is naturally idempotent by construction, since re-applying the same flag transition twice yields the same state.
  - Why: Outbox guarantees `CartCheckedOut` is never lost even if the broker is unreachable at the moment of the state change, without needing a distributed transaction across PostgreSQL and the broker (dual-write risks publishing for a state change that then fails to commit, or the reverse). On the consume side, a separate inbox/dedup table would add complexity with no benefit here — unlike a money-moving flow where a duplicate side effect is unacceptable, D3's flag-toggle is idempotent on its own.
  - Trade-off accepted: Outbox requires a relay process/poller and an extra table, adding a small publish-latency lag between commit and broker delivery, versus the operational simplicity of a direct dual-write — accepted because `CartCheckedOut`'s correctness (it feeds Analytics funnel tracking, per ADR-0007) is worth more than that small added lag or complexity.

## Decision: Resilience Pattern for Checkout-Time Stock/Price Validation

- **Requirement driving this:** `edge-cases.md` → "Stale cart references a deleted or out-of-stock product" (lazy validation at checkout, chosen over event-driven proactive pruning or client-side re-check); NFR §3 Latency (P95 < 150ms); Domain Invariant §4 (a cart line item is not a reservation — Inventory is the sole enforcer of the oversell invariant).
- **Options considered (3):** synchronous gRPC call to Product/Inventory, guarded by a timeout budget and a circuit breaker, failing open (checkout proceeds without the pre-check) on breaker-open or timeout · synchronous REST call, same guard · unguarded direct call to Product/Inventory, checkout blocks/fails if either is slow or down.
- **Decision:**
  - Chosen: gRPC, wrapped in a timeout scoped inside Cart's own latency budget and a circuit breaker; on breaker-open or timeout, checkout proceeds without the pre-check rather than blocking.
  - Why: the reusable API standards reserve gRPC specifically for "internal, high-throughput synchronous calls... e.g. an inventory reserve check" — this lazy-validation call is exactly that shape. Failing open (not blocking checkout) matches the domain invariant that Cart's check is a UX improvement (surface unavailability earlier), not a gate — Inventory is the sole enforcer of the oversell invariant, so a Product/Inventory slowdown or outage must not become a Cart/checkout outage, especially given Cart and Product/Inventory do not share the same availability tier (Decision D6: Cart is 99.9% secondary tier).
  - Trade-off accepted: during a downstream outage or an open breaker, a user can proceed to checkout with a cart line item that is actually unavailable — already an accepted consequence of choosing lazy (checkout-time-only) validation in `edge-cases.md`; this decision only extends that same acceptance to also cover a downstream-unavailability window, rather than turning it into a hard checkout failure.

## Decision: Erasure Mechanism for `UserDataErased` — Synchronous Multi-Store Hard Delete, Not Tombstone

- **Requirement driving this:** requirement-spec §2's GDPR Erasure Consumption FR and §6 D10 (both added this pass, closing the gap ADR-0016 was updated to name Cart for); `edge-cases.md`'s "Residual Cart State After a `UserDataErased` Event" decision.
- **Options considered (3):** delete only the PostgreSQL `Cart` row(s), leaving the Redis entry to expire on its own sliding TTL (up to 30 days, Decision D1) · delete the PostgreSQL row(s) and synchronously evict the Redis cache entry in one handler · tombstone the `Cart` row's contents in place (mirroring User Service's own pattern for retained-but-anonymized order/audit history, ADR-0016 item 3) rather than deleting it.
- **Decision (3-5 bullets max):**
  - Chosen: option 2 — synchronous hard delete of every `Cart` row (Active or CheckedOut) owned by the erased `userId` from PostgreSQL, plus a synchronous Redis cache-entry eviction, in one consumer handler.
  - Why: ADR-0016 item 3's tombstone-vs-delete split turns on whether the data is BRD-required retained history — Order's/Payment's own records are, a shopping cart (checked-out or not) is not, so there is nothing to anonymize in place and tombstoning would only leave a purposeless sentinel row. Leaving the Redis entry to its own TTL (option 1) reintroduces exactly the "erased user's cart still readable for up to 30 days" gap `edge-cases.md`'s decision already rejected, given ADR-0016 item 7's framing of a delayed erasure as a compliance failure.
  - Trade-off accepted: the handler touches two stores instead of one, and must override the normal-case retention of a `CheckedOut` cart (ddd-model.md invariant 4) for this one trigger — accepted because a compliance-critical event is exactly the case where synchronous, complete erasure is worth the extra handler complexity, and this reuses the same delete-the-row mechanism the expiry-purge path (Decision D1) already implements, just triggered by a distinct external event instead of TTL expiry.
  - Idempotency: mirrors the platform's standard idempotent-consumer pattern (`event-standards.md`) already relied on for this service's own `InventoryReservationFailed` handling — a redelivered `UserDataErased` for an already-erased `userId` finds nothing to delete and is a no-op.

## Decision: Observability & Instrumentation

**Decision:** Serilog (structured logging) + OpenTelemetry SDK (distributed tracing + metrics), per the platform's reusable observability-standards.md and this repo's kart-conventions.md Observability section. Logs export via OTLP → Grafana Loki; traces via OTLP → Grafana Tempo; metrics scraped by Prometheus from `/metrics`; Grafana provides dashboards and alerting. Wired once via the shared `Kart.Shared.Observability` package, not reimplemented per service.

**Options considered:**
- Ad-hoc per-service logging/APM tool choice — rejected: fragments dashboards/alerting across 18 services and breaks single-trace-id correlation across the platform.
- Platform-standard Serilog + OpenTelemetry + Grafana LGTM stack — adopted: one mental model and one Grafana pane across every service.

**Why:** Cart's primary correlation field is `cartId`, and it runs the standard (not 100%) sampling tier — it is a pre-Saga, customer-facing edge service (Decision D6), not one of the four order-path services sampled at 100%. The funnel metric worth calling out is `CartCheckedOut` publish latency and volume, since it directly feeds the Analytics conversion-funnel dashboard this event exists for — a trace spanning the write-through PostgreSQL commit through the Outbox relay to `CartCheckedOut` publication gives one end-to-end view of that funnel step's own health.

## Escalations

None. All five decisions above are grounded directly in this service's approved `requirement-spec.md`/`edge-cases.md` (the erasure decision additionally grounded in ADR-0016, updated this pass to name Cart directly) and are single-service engineering defaults consistent with the project's shared standards (`docs/standards/api-standards.md`'s gRPC guidance, `docs/standards/ddd-cqrs-standards.md`'s Outbox/replay expectation, `docs/standards/event-standards.md`'s at-least-once/DLQ defaults) — no genuinely equivalent options requiring a business call were found.

## Decision: Global Exception Handling & Consistent Response Model

**Decision:** A single global exception-handling middleware (ASP.NET Core `IExceptionHandler`/`UseExceptionHandler`) is the only place this service catches and translates unhandled exceptions into an HTTP response — no `Handler`/controller/domain code wraps business logic in try/catch purely to log-and-rethrow or log-and-return an error. Every error response (validation failure or unhandled exception) is shaped as an RFC 7807 `ProblemDetails` envelope extended with the platform's standard fields (`traceId`, `errorCode`); every success response follows the same consistent envelope convention as every other Kart service. Both the middleware and the `ProblemDetails` factory are wired once via the shared `Kart.Shared.ErrorHandling` package, not reimplemented locally.

**Options considered:**
- Per-handler/controller try/catch translating exceptions to a response inline — rejected: duplicates translation logic per endpoint, risks inconsistent status-code/response-shape choices across handlers, and produces double-logging (or missed logging) when a local catch and the global handler both react to the same exception.
- Platform-standard global exception handler + `Kart.Shared.ErrorHandling`-wired `ProblemDetails` envelope — adopted: one place to change the error shape platform-wide, and a response contract every client (web, admin, partner API) can parse identically regardless of which of the 18 services it's calling.

**Why:** matches the same "one platform-wide implementation, not built locally by each service" pattern already applied to `Kart.Shared.Observability` and `Kart.Shared.Auditing` above — reimplementing exception translation per service is the identical per-service-drift failure mode those decisions already reject. Domain/business errors continue to use the Result/Either pattern (`agent-reusables/docs/standards/api-standards.md`) rather than exceptions; the global handler exists for the genuinely exceptional case (an unhandled infrastructure fault), and logs it exactly once — at `Error` level, tagged with `traceId`/`service` and this service's own primary correlation field named in its Observability & Instrumentation decision above — through the same Serilog/OTel pipeline, never a second, ad-hoc log line from a local catch block.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner
- [x] Approved to proceed to Architecture Agent
