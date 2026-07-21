---
doc_type: design-decisions
service: kart-user-service
status: proposed
generated_by: design-decision-agent
source: docs/services/kart-user-service/requirement-spec.md, docs/services/kart-user-service/edge-cases.md
---

# Design Decisions: kart-user-service

Cross-cutting technology/design-pattern choices this service's approved `requirement-spec.md` and `edge-cases.md` force, beyond what those two docs already settled themselves. Service boundaries, aggregates/domain model, and schema are out of scope here (Architecture, DDD, and Database Design Agents). The Identity/User data-ownership boundary (formerly Open Question 1) and the GDPR/erasure policy (formerly Open Question 6) are **both already fully resolved** — by `docs/adr/0006-identity-user-profile-sync-event.md` and `docs/adr/0016-user-gdpr-erasure-policy.md` respectively — and are cited below where they generalize into a technology/pattern choice, never re-decided.

## Decision: Event Publication Reliability — Transactional Outbox for `UserProfileUpdated` and `UserDataErased`

- **Requirement driving this:** requirement-spec §2 (profile writes publish `UserProfileUpdated` "projected asynchronously into MongoDB via the platform's standard Outbox pipeline"); NFR §3 Reliability ("at-least-once delivery + idempotent consumers"); ADR-0016 item 2, which extends "the existing Outbox pipeline" to re-project the tombstoned record on erasure rather than introducing a separate purge mechanism.
- **Options considered (3):** Transactional Outbox (event row written in the same PostgreSQL transaction as the domain write, relayed by a separate poller) · Dual write (publish to RabbitMQ directly, then commit the DB write, or vice versa) · Change-Data-Capture directly off the PostgreSQL WAL, bypassing an explicit outbox table.
- **Decision (4 bullets max):**
  - Chosen: Transactional Outbox, one mechanism reused for both ordinary profile writes (`UserProfileUpdated`) and the erasure tombstone write (`UserDataErased`) — not two different publish paths for the two write types.
  - Why: requirement-spec §2 already assumes an Outbox insert on the profile write path, and ADR-0016 explicitly reuses that same pipeline for the tombstone write rather than inventing a second one; dual-write is the exact failure mode Outbox exists to avoid (a DB commit and a broker publish can never be made atomic any other way without 2PC, which this platform does not use); CDC would add a second capture mechanism alongside the platform's already-standard poller-based Outbox with no stated benefit at this service's volume.
  - Trade-off accepted: a poller/relay process is a hard dependency for both write types — already accepted platform-wide, and mitigated for this service by the poller-lag alerting edge-cases.md already commits to ("Outbox poller stall causing unbounded staleness").

## Decision: Idempotency Mechanism for Inbound Event Consumption (`UserRegistered`, `UserAccountUpdated`)

- **Requirement driving this:** NFR §3 Reliability (at-least-once delivery + idempotent consumers), applying to both events consumed from Identity Service; edge-cases.md "Duplicate/out-of-order `UserRegistered` delivery" already resolves the specific case with upsert-on-user-id.
- **Options considered (3, per edge-cases.md):** Upsert keyed on user id (idempotent by construction, since the target record's key is the same id carried in the event) · Consumer-side dedup table keyed on event id (the platform's general Outbox/consumer dedup pattern, BRD §11) · An event-sourced replay log retaining every processed event for exact-once semantics.
- **Decision (4 bullets max):**
  - Chosen: Upsert keyed on user id, as already decided in edge-cases.md for `UserRegistered` — generalized here as this service's standing idempotency mechanism for every inbound event whose payload is naturally keyed by `userId`, which covers both `UserRegistered` (profile creation) and `UserAccountUpdated` (denormalized email/display-name reconciliation, ADR-0006).
  - Why: both events' target record shares the same natural key, so re-applying either is idempotent without a separate dedup-table lookup; a dedup table would add a second store and failure mode for a guarantee upsert-by-key already provides for free here.
  - Trade-off accepted: unchanged from edge-cases.md — doesn't generalize to a hypothetical future event not naturally keyed by `userId` alone (e.g. a field-level patch event), which would need the dedup-table approach instead; not a concern for the two events this service currently consumes.

## Decision: Concurrency Control for Profile Writes — Last-Write-Wins

- **Requirement driving this:** requirement-spec §4 domain invariant ("exactly one canonical profile write-model record per user id" states nothing about concurrent-write ordering); edge-cases.md "Concurrent profile writes from multiple devices/sessions" already resolves this for the write model.
- **Options considered (3, per edge-cases.md):** Last-write-wins (no client change required) · Optimistic concurrency token (version column, `If-Match`, 409 on conflict) · Field-level merge instead of whole-record replace.
- **Decision (4 bullets max):**
  - Chosen: Last-write-wins, as already decided in edge-cases.md — generalized here as this service's standing concurrency-control default for the profile write model as a whole (addresses, preferences, and any future profile field), not scoped only to the "two default addresses" case it was first raised against.
  - Why: the BRD gives User Service no concurrency-control requirement anywhere, unlike Inventory/Payment's explicit optimistic-locking/`SELECT ... FOR UPDATE` requirements — adding version tokens or field-level merge machinery here would invent a requirement neither document supports, for a data class (profile, not money or stock) where a lost update is low-severity.
  - Trade-off accepted: unchanged from edge-cases.md — an edit from one device/session can be silently lost if another edit lands first; revisit if product requirements later demand a stronger guarantee.

## Decision: Resilience Pattern — Retry/DLQ Tier Classification (Standard vs. Compliance-Critical)

- **Requirement driving this:** requirement-spec §3 Retry/DLQ row (`UserRegistered` 3x → `identity.dlq`; `UserProfileUpdated` 2x → `user.dlq`; `UserAccountUpdated` 2x → `identity.dlq`, per ADR-0007/ADR-0008) alongside ADR-0016 item 7's distinct rule for `UserDataErased` — "the same high-retry-budget/human-paging tier the platform already reserves for money-critical events... rather than the looser catalog/search tier."
- **Options considered (3):** One uniform standard retry/DLQ tier for every event this service publishes/consumes · A second, compliance-critical tier (higher retry budget + human paging on final DLQ landing) for `UserDataErased` only, extending the platform's existing money-moving-criticality convention (`docs/standards/kart-conventions.md`) by analogy · Route `UserDataErased` onto the literal same DLQ/paging config as Payment's own events, sharing infrastructure rather than a parallel tier.
- **Decision (4 bullets max):**
  - Chosen: Two-tier classification — `UserRegistered`/`UserProfileUpdated`/`UserAccountUpdated` stay on the standard tier already fixed by ADR-0007/0008 (2-3x retry, per-consumer-queue DLQ, no paging); `UserDataErased` gets its own compliance-critical tier (high retry budget, human paging on final DLQ landing), per ADR-0016 item 7 — formalized here as this service's general rule for classifying its own events, not a one-off carve-out.
  - Why: `docs/standards/kart-conventions.md`'s "Money-Moving Criticality" rule already establishes the platform pattern of a distinct high-stakes tier layered on the standard default; ADR-0016 extends that same pattern by analogy to a compliance-critical event rather than a money-moving one — a silently-DLQ'd erasure event is a compliance failure, not a tolerable staleness window, so it needs Payment's escalation posture without literally sharing Payment's queue/DLQ (kept separate per the platform's per-consumer-queue default).
  - Trade-off accepted: this service now maintains two operationally distinct alerting/paging configurations instead of one uniform policy — accepted because the two event classes have genuinely different failure consequences (a lost profile-update retry vs. a lost legal-erasure guarantee).

## Not Decided Here

- **Identity/User data-ownership boundary** — fully resolved by `docs/adr/0006-identity-user-profile-sync-event.md` (Identity owns login-email/display-name as source of truth, publishes `UserAccountUpdated`; User Service keeps a denormalized, eventually-consistent copy). Requirement-spec §1/§6 item 1 already cites this ADR directly as the closure of the former Open Question 1 — not re-decided here, only its idempotent-consumption pattern is generalized above.
- **Caching strategy for `/users/{id}` reads** — no forcing requirement beyond the CQRS MongoDB read projection requirement-spec §3/§4 already mandates; neither doc names a Redis or other cache layer in front of that projection (unlike Product Service's stated Redis cache-aside, BRD §16) — nothing to decide without inventing a requirement this service's docs don't state.
- **Serialization format for events/payloads** — neither requirement-spec.md nor edge-cases.md states a service-specific forcing requirement beyond the platform's existing event-schema-versioning default (`event-standards.md`); no divergence reason exists.
- **HTTP verb / read-vs-write split on `/users/{id}`** — requirement-spec §7 explicitly and correctly leaves this to the API Design Agent (a platform-wide REST/command convention call, not a User-Service-local one); not re-decided here.
- **Erasure-request intake / trigger mechanism** — how a verified erasure request is delivered to User Service (a synchronous internal call vs. an event User Service consumes) is not stated by requirement-spec.md, edge-cases.md, or ADR-0016, which only specify what happens once User Service's own tombstone write occurs. Not enough grounding here to decide without inventing the caller/topology — left to the Architecture Agent when the erasure workflow's cross-service shape is designed.

## Escalations

None. All four decisions above are grounded directly in this service's approved `requirement-spec.md`/`edge-cases.md`, citing `docs/adr/0006-identity-user-profile-sync-event.md` and `docs/adr/0016-user-gdpr-erasure-policy.md` where a chosen fix generalizes into a standing pattern, and are consistent with the project's shared standards (`docs/standards/kart-conventions.md`'s money-moving-criticality convention, extended by analogy; the platform's Outbox/idempotent-consumer defaults). No genuinely equivalent options requiring a business call were found.

## Sign-off

- [ ] Chosen technologies/patterns reviewed by a human
- [ ] Approved to proceed to Architecture Agent
