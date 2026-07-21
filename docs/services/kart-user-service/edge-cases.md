---
doc_type: edge-cases
service: kart-user-service
status: approved
generated_by: edge-case-analyzer-agent
source: docs/services/kart-user-service/requirement-spec.md
---

# Edge Cases: kart-user-service

## Edge Case: Stale MongoDB read after PostgreSQL write

- **What happens:** A client calls `GET /users/{id}` and receives a profile that doesn't yet reflect a write that just committed.
- **Why it happens:** The read projection is populated asynchronously via Outbox → RabbitMQ, so a propagation window always exists between write-commit and projection (requirement-spec §3 Consistency row; §5 API Surface).
- **Solutions available (3):** Read-your-writes via sticky routing back to the write model right after a client's own update · Client-side "processing" acknowledgment state until the projection event is observed (the pattern BRD §7 prescribes for Order) · Accept silent staleness within the P95/P99 latency budget and document it as expected
- **Decision (3-5 bullets max):**
  - Chosen: Client-side "processing" acknowledgment state
  - Why: Mirrors how the platform already handles this exact window for Order (BRD §7: staleness "must be surfaced to the client... rather than hidden") — no reason to invent a different UX pattern for User
  - Trade-off accepted: Slight added client complexity (a transient "saved, updating..." state) vs. silently masking staleness

## Edge Case: Outbox poller stall causing unbounded staleness

- **What happens:** If the Outbox poller/relay for User Service stops running, the MongoDB profile projection stops updating entirely rather than lagging by the usual sub-second window.
- **Why it happens:** The read projection has no independent freshness signal, so a poller outage is indistinguishable from normal lag on the read side (requirement-spec §4 domain invariant: projection "must be rebuildable... and must eventually converge").
- **Solutions available (2):** Poller-lag/queue-depth alerting, reusing the platform's existing HPA/observability metric (BRD §22, §23) · Per-record staleness timestamp exposed in the read model so consumers can detect and reject overly-stale reads
- **Decision (3-5 bullets max):**
  - Chosen: Poller-lag alerting only, for the initial cut
  - Why: Reuses existing platform primitives rather than adding a new per-record freshness contract
  - Trade-off accepted: Clients cannot detect staleness themselves and depend entirely on ops response — acceptable given User Service's resolved non-critical-path (secondary, 99.9%) availability tier (requirement-spec §3, §6 decision 7), but should be revisited if a later stage finds User Service actually gates some order-path flow the BRD doesn't mention

## Edge Case: Concurrent profile writes from multiple devices/sessions

- **What happens:** Two devices submit conflicting profile writes close together (e.g. two different addresses set as "default"); the second silently overwrites the first with no conflict signal.
- **Why it happens:** The write-model uniqueness invariant (requirement-spec §4: "exactly one canonical profile write-model record per user id") says nothing about concurrent-write ordering, and the BRD gives no optimistic-concurrency requirement for User, unlike Inventory's explicit `SELECT ... FOR UPDATE` pattern (BRD §6.1).
- **Solutions available (3):** Last-write-wins (no client change required) · Optimistic concurrency token (version column, `If-Match`, 409 on conflict) · Field-level merge instead of whole-record replace
- **Decision (3-5 bullets max):**
  - Chosen: Last-write-wins for this pass
  - Why: The BRD gives User Service no concurrency-control requirement anywhere (unlike Inventory/Payment, where it's explicit); adding optimistic locking here would be inventing a requirement the BRD doesn't support
  - Trade-off accepted: An edit from one device can be silently lost if another edit lands first — acceptable severity for profile data (not money- or stock-moving), but should be revisited if product requirements later demand it

## Edge Case: Duplicate/out-of-order `UserRegistered` delivery

- **What happens:** RabbitMQ's at-least-once delivery redelivers `UserRegistered` for a user id that already has a profile record.
- **Why it happens:** The global NFR requires idempotent consumers under at-least-once delivery (requirement-spec §3 Reliability row), but the BRD gives no event-id/dedup contract specific to `UserRegistered`.
- **Solutions available (2):** Upsert keyed on user id (idempotent by construction, since the target record's key is the same id carried in the event) · Consumer-side dedup table keyed on event id (the platform's general Outbox/consumer dedup pattern, BRD §11)
- **Decision (3-5 bullets max):**
  - Chosen: Upsert on user id
  - Why: User id is already the natural, stable key (`/users/{id}`); no need for a separate dedup table when the target record's key doubles as the idempotency key
  - Trade-off accepted: Doesn't generalize to a future event that isn't naturally keyed this way (e.g. a hypothetical field-level update event) — those would need the dedup-table approach

## Edge Case: Address write with invalid/unvalidatable data

- **What happens:** A client submits an address that is malformed, non-existent, or unresolvable to a real location as part of a profile write.
- **Why it happens:** The requirement-spec's functional requirement to "store and manage addresses" (§2) has no validation, geocoding, or format requirement behind it in the BRD — nothing today rejects or normalizes a bad address before it reaches the write model.
- **Solutions available (3):** Reject at write time with format-only validation (no geocoding) · Integrate a synchronous geocoding/address-verification provider on write · Accept as-is and defer validation to a downstream consumer (e.g. Shipping) at time of use
- **Decision (3-5 bullets max):**
  - Chosen: Reject at write time with format-only validation (required-field presence + country-aware format checks, e.g. postal-code pattern per `countryCode`); no synchronous geocoding provider on the write path
  - Why: The BRD gives no basis to pick a paid geocoding vendor or its cost/latency budget, but the write-path latency NFR (requirement-spec §3, P95 < 300ms including Outbox insert) argues against adding a synchronous third-party call regardless of vendor; format-only validation is a defensible engineering default that needs no vendor decision, and delivery-grade correctness is Shipping's own concern to enforce at label-generation time (BRD §5.4), not User Service's
  - Trade-off accepted: A format-valid but non-existent address (e.g. a real postal code with a fabricated street number) passes through undetected until a downstream consumer or carrier rejects it at time of use — acceptable because User Service's role here is storage, not a delivery guarantee; synchronous geocoding can be added later behind the same write endpoint without a breaking change if the business later requires it

## Edge Case: Email/contact-field drift between Identity Service and User Service

- **What happens:** A user changes their login email via Identity Service, but User Service's profile (write and read model both) continues to serve the old email indefinitely.
- **Why it happens:** The only inbound event User Service consumed from Identity was previously `UserRegistered` alone (requirement-spec §5 API Surface); this is now resolved.
- **Solutions available (3):** Identity publishes a new change event (e.g. `IdentityContactChanged`/`UserAccountUpdated`) that User Service consumes · User Service becomes sole owner of contact fields post-registration and Identity stops treating them as its own · User Service queries Identity synchronously at read time for identity-owned fields
- **Decision (3-5 bullets max):**
  - Chosen: Identity publishes `UserAccountUpdated` (payload: `userId`, `email`, `displayName`) on every login-email/display-name change; User Service consumes it and reconciles its own denormalized copy — resolved by `docs/adr/0006-identity-user-profile-sync-event.md`, already reflected in BRD §5.4/§10
  - Why: This is the exact data-ownership question requirement-spec Open Question 1 flagged; ADR-0006 settled it platform-wide (Identity owns the field, User keeps an eventually-consistent copy) rather than each service guessing independently
  - Trade-off accepted: User Service's copy of email/display name can lag Identity's by the same eventual-consistency window as any other projected field — acceptable since User Service never treats these two fields as write-authoritative anyway (requirement-spec §4 domain invariant)

## Edge Case: PII lingering in the read projection after a correction or deletion

- **What happens:** A user's PII is corrected or a deletion is requested against the PostgreSQL write model, but the MongoDB projection, caches, or logs continue to expose the old value for some period, or indefinitely if nothing re-triggers a full projection refresh.
- **Why it happens:** The requirement-spec's Security NFR previously covered encryption but not deletion propagation; this is now resolved for both the correction case and the deletion/erasure case.
- **Solutions available (2):** Treat correction/deletion as a normal profile write, reusing the existing `UserProfileUpdated` → projection pipeline with no new mechanism · Build a dedicated erasure workflow with projection/cache/log purge guarantees and an audit trail
- **Decision (3-5 bullets max):**
  - Chosen: Split by request type — an ordinary **correction** reuses the existing `UserProfileUpdated` → Outbox → projection pipeline with no new mechanism (the normal sub-second staleness window already covered above under "Stale MongoDB read after PostgreSQL write" is an acceptable answer for a correction); a **verified erasure request** gets the dedicated workflow in ADR-0016 (`docs/adr/0016-user-gdpr-erasure-policy.md`): PII tombstoned in the write model within 30 days, re-projected via the same Outbox pipeline, and a new `UserDataErased` event published so downstream services (Order, Notification, Analytics, Review, Recommendation, Wishlist) redact their own copies
  - Why: A correction has no compliance SLA and the existing pipeline already guarantees eventual convergence (requirement-spec §4); an erasure request does have an implicit compliance expectation (a GDPR-style "without undue delay" bound) that a purely eventual, best-effort re-projection can't promise on its own — it needs an explicit completion window and an explicit fan-out event, which the normal write pipeline doesn't provide
  - Trade-off accepted: The 30-day tombstone window and the choice of a new event rather than reusing `UserProfileUpdated` are engineering/compliance defaults made in the absence of BRD or legal guidance (flagged as such in the PENDING ADR), not a legally-reviewed policy; and downstream redaction is only as reliable as each consuming service's own handler — a service that never implements one keeps stale PII, mitigated only by the same DLQ/paging visibility every other event gets
