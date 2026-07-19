---
doc_type: edge-cases
service: kart-user-service
status: pending-approval
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
  - Trade-off accepted: Clients cannot detect staleness themselves and depend entirely on ops response — acceptable given User Service's inferred non-critical-path status (requirement-spec Open Question 7), but should be revisited if that inference is wrong

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
  - Chosen: Escalated — unresolved
  - Why: Choosing a geocoding provider, and its cost/latency budget on the write path, is a business/vendor call the BRD gives no basis to make, not an engineering default
  - Trade-off accepted: N/A — flagged for the Architecture Agent, per requirement-spec Open Question 5 (address schema unspecified)

## Edge Case: Email/contact-field drift between Identity Service and User Service

- **What happens:** A user changes their login email via Identity Service, but User Service's profile (write and read model both) continues to serve the old email indefinitely.
- **Why it happens:** The only inbound event User Service consumes from Identity is `UserRegistered` (requirement-spec §5 API Surface); the BRD defines no event for subsequent Identity-side field changes, and requirement-spec Open Question 1 leaves the ownership boundary for shared fields unresolved.
- **Solutions available (3):** Identity publishes a new change event (e.g. `IdentityContactChanged`) that User Service consumes · User Service becomes sole owner of contact fields post-registration and Identity stops treating them as its own · User Service queries Identity synchronously at read time for identity-owned fields
- **Decision (3-5 bullets max):**
  - Chosen: Escalated — unresolved
  - Why: This is exactly the data-ownership question already flagged in requirement-spec Open Question 1 — picking one silently here would preempt an Architecture Agent decision that affects both services' boundaries
  - Trade-off accepted: N/A — carried forward

## Edge Case: PII lingering in the read projection after a correction or deletion

- **What happens:** A user's PII is corrected or a deletion is requested against the PostgreSQL write model, but the MongoDB projection, caches, or logs continue to expose the old value for some period, or indefinitely if nothing re-triggers a full projection refresh.
- **Why it happens:** The requirement-spec's Security NFR (AES-256 at rest, TLS in transit) covers encryption but not deletion propagation, and the BRD states no deletion/erasure requirement at all for its primary PII-holding service (requirement-spec Open Question 6).
- **Solutions available (2):** Treat correction/deletion as a normal profile write, reusing the existing `UserProfileUpdated` → projection pipeline with no new mechanism · Build a dedicated erasure workflow with projection/cache/log purge guarantees and an audit trail
- **Decision (3-5 bullets max):**
  - Chosen: Escalated — unresolved
  - Why: Whether reusing the normal write pipeline is sufficient depends on a legal/compliance requirement (a GDPR-style erasure SLA) the BRD never states — an engineering default can't substitute for that answer
  - Trade-off accepted: N/A — carried forward to the same Open Question (6) already flagged in the requirement-spec
