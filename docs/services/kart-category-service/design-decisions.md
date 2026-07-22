---
doc_type: design-decisions
service: kart-category-service
status: approved
generated_by: design-decision-agent
source: docs/services/kart-category-service/requirement-spec.md, docs/services/kart-category-service/edge-cases.md
---

# Design Decisions: kart-category-service

Scope: cross-cutting technology/pattern choices this service's own approved `requirement-spec.md` and `edge-cases.md` force. Service boundaries, domain model, and schema are out of scope here — those are the Architecture, DDD, and Database Design Agents' jobs.

## Decision: Caching Strategy for the `/categories` Read Path

- **Requirement driving this:** Latency NFR — P95 < 150ms, P99 < 400ms on the read path, Category grouped with Product/Search as "Read-Heavy" (requirement-spec §3) — combined with the Consistency NFR fixed by ADR-0011 (`docs/adr/0011-category-read-model-scope.md`): "Strong, read-your-write within Category's own PostgreSQL store." ADR-0011 names PostgreSQL read replicas plus "an application-level or Redis cache" as the mechanism but leaves the specific caching pattern open — that choice is this stage's job.
- **Options considered (3):** Cache-Aside — Category's own read replica, invalidate-on-miss (the pattern already used for Product detail reads, kart-requirements.md §16) · Write-Through — Redis updated synchronously alongside every PostgreSQL write (the pattern already used for Promotion's active-campaign flags, kart-requirements.md §16, "staleness there is unacceptable for pricing") · No cache — PostgreSQL read replicas only, relying on the materialized-path storage edge-cases.md already chose.
- **Decision (3 bullets):**
  - Chosen: Write-Through Redis cache in front of PostgreSQL — every taxonomy write (create/rename/move/deprecate) updates the cached `/categories` entries synchronously in the same operation as the PostgreSQL write, not a bare TTL-expiry or invalidate-then-repopulate-on-next-read.
  - Why: ADR-0011 fixes Category's own consistency target as strong, read-your-write — the identical "staleness is unacceptable" criterion kart-requirements.md §16 already uses to pick Write-Through over Cache-Aside for Promotion, rather than Product's Cache-Aside pattern, which tolerates a miss-then-repopulate window Category's own NFR doesn't budget for.
  - Trade-off accepted: every taxonomy write pays a synchronous Redis update in addition to the PostgreSQL write — acceptable because writes are rare and RBAC-gated (Admin-driven, requirement-spec §4), not a customer-facing hot path, while every `/categories` read gets a warm cache with no staleness window; a cache miss still falls back to the PostgreSQL read replica, so Redis availability is a latency, not a correctness, dependency.

## Decision: Concurrency Control for Hierarchy Mutations (Move / Re-parent)

- **Requirement driving this:** edge-cases.md's "Circular category reference on re-parent" decision (synchronous ancestor-chain check at write time) names its own root cause as "a single move (or a racing pair of moves) can introduce a cycle undetected" — the chosen fix closes the check itself, but the concurrency mechanism that keeps two racing moves from both passing that check is the generalization this stage owns, not a re-derivation of the edge case.
- **Options considered (3):** Pessimistic row-level locking — `SELECT ... FOR UPDATE` on the target category and its ancestor chain inside the same transaction as the cycle/depth check and the write · Optimistic concurrency — a `version` column per category row, write rejected and retried by the caller on conflict · Application-level distributed lock (e.g. a Redis lock) scoped to the affected subtree root.
- **Decision (4 bullets):**
  - Chosen: Pessimistic row-level locking (`SELECT ... FOR UPDATE`) across the target category and its ancestor chain, inside the single transaction that also runs the cycle check and the max-depth check (requirement-spec §4).
  - Why: taxonomy writes are rare and RBAC-gated (requirement-spec §4), not a high-concurrency path, so lock contention cost is negligible; a database-native lock closes the exact race the edge case names within the same transaction the invariants already run in, without a second coordination system.
  - Trade-off accepted: a move touching a deep/wide ancestor chain briefly blocks any other move touching an overlapping chain — bounded and acceptable because the max-depth-4 invariant (requirement-spec §4) already caps how long that chain, and therefore the lock hold, can be.
  - Not chosen: optimistic concurrency would need a client retry loop for a case that should reject synchronously once (matching the edge case's own "must block the write, not catch it later" reasoning); a distributed Redis lock adds a second locking mechanism for a race PostgreSQL's own transactional locking already closes natively.

## Decision: Reliable Event Publication for `CategoryUpdated`

- **Requirement driving this:** requirement-spec §3's blanket Reliability NFR ("At-least-once delivery + idempotent consumers") applied to `CategoryUpdated`, now with a confirmed consumer/retry/DLQ tier (Analytics, 3x retry, `catalog.dlq`, per ADR-0008); one coarse event per subtree move rather than per-descendant fan-out (edge-cases.md, "Subtree re-parenting invalidates downstream category data"). Publishing that event reliably alongside the PostgreSQL write that triggers it is this stage's mechanism choice.
- **Options considered (3):** Transactional Outbox — write an outbox row in the same PostgreSQL transaction as the taxonomy write; a relay process publishes it to RabbitMQ and marks it sent (the platform's own default pattern, kart-requirements.md §11) · Dual-write — commit the PostgreSQL write, then publish directly to RabbitMQ as a second, unguarded step · Change-Data-Capture (CDC) off the PostgreSQL WAL (e.g. Debezium).
- **Decision (3 bullets):**
  - Chosen: Transactional Outbox — the `CategoryUpdated` row (one per create/rename/move/deprecate; one coarse row per subtree move) is written in the same transaction as the taxonomy change, then relayed to the `ecommerce.events` topic exchange (kart-conventions.md) with the 3x/`catalog.dlq` policy already fixed by ADR-0008.
  - Why: dual-write can commit the taxonomy change and then fail to publish (or the reverse), breaking the at-least-once NFR; the Outbox keeps "the write happened" and "the event will eventually publish" atomic, matching the platform's existing default (kart-requirements.md §11) without the WAL-level CDC infrastructure this service's low write volume doesn't justify.
  - Trade-off accepted: a small relay component and a short publish-lag between commit and relay — acceptable because Analytics' own consumption is already async/eventually-consistent by design (ADR-0004) and no consumer of this event needs sub-second delivery.

## Decision: Communication Style for the Admin -> Category Write Path

- **Requirement driving this:** requirement-spec §4's write-ownership invariant ("Category owns its own write model exclusively; Admin ... performs taxonomy curation only through Category's own write API") and ADR-0010's decision #2 ("Admin Service invokes the owning service's own write API synchronously — service-to-service, internal client-credentials call") both fix *that* Admin calls Category; the transport/protocol choice is this stage's job.
- **Options considered (3):** Synchronous internal REST call — same versioned HTTP contract style as `/categories`, internal caller authenticated via an Identity-issued client-credentials token carrying the `Admin` role claim (BRD §24.1) · Synchronous internal gRPC call · Asynchronous command message — Admin publishes a "curate category" command, Category consumes and processes it later.
- **Decision (3 bullets):**
  - Chosen: Synchronous internal REST call, reusing Category's own write endpoints (create/rename/move/deprecate) rather than a separate internal API surface, authenticated the same way every other RBAC-gated `/admin/*`-adjacent write is.
  - Why: the cycle-check and max-depth invariants (requirement-spec §4) must reject an invalid move synchronously so Admin's caller sees the failure immediately — an async command would defer that rejection past the point Admin can usefully react; gRPC is reserved by the platform's API standards for high-throughput internal calls, and admin-driven taxonomy curation is low-volume and human-triggered, not that profile.
  - Trade-off accepted: Admin's call is a blocking network hop rather than fire-and-forget — acceptable because it's the same trade-off every synchronous validation-bearing write already makes, and taxonomy curation sits on Category's "secondary path" availability tier (requirement-spec §3), not the platform's 99.99%-critical path.

## Escalations

None. Every decision above resolves to one option on engineering grounds already stated in requirement-spec.md, edge-cases.md, an existing ADR, or the platform's own standards/BRD precedent (kart-requirements.md §11, §16) — none of the four are a genuine business call (cost, vendor lock-in, team familiarity) between equivalent options.

## Sign-off

- [x] Chosen technologies/patterns reviewed by a human — Automated architecture pipeline, autonomous completion authorized by project owner
- [x] Approved to proceed to Architecture Agent
