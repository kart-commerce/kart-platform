---
doc_type: design-decisions
service: kart-cart-service
status: pending-approval
generated_by: design-decision-agent
source: docs/services/kart-cart-service/requirement-spec.md, docs/services/kart-cart-service/edge-cases.md
---

# Design Decisions: kart-cart-service

Cross-cutting technology/design-pattern choices this service's approved `requirement-spec.md` and `edge-cases.md` force. Service boundaries, domain model, and schema are out of scope here (Architecture/DDD/Database Design Agents). Decisions already made at the requirement/edge-case stage (D1–D5) are referenced, not re-derived, except where they generalize into a pattern choice not yet made explicit.

## Decision: Caching Strategy for Cart State (Redis + PostgreSQL)

- **Requirement driving this:** FR §2 "store cart state in Redis with a PostgreSQL snapshot" (BRD §5.4/§16); NFR §3 Consistency = Strong; Domain Invariant §4 "an expired cart must eventually be reclaimed."
- **Options considered (3):** write-through (every mutation synchronously writes PostgreSQL, Redis as read cache) · write-behind/periodic async snapshot (Redis authoritative, PostgreSQL lags) · Redis persistence only (AOF/RDB), no separate PostgreSQL sync path.
- **Decision:**
  - Chosen: write-through on every mutation, PostgreSQL authoritative; sliding TTL on the Redis entry — 30 days idle (logged-in), 7 days idle (guest), reset on every read/write touch; 30-day PostgreSQL soft-expiry recovery window past Redis eviction before the row is purged.
  - Why: write-through is the only option that satisfies NFR Consistency = Strong without a stale-read window, already settled as requirement-spec Decision D5; sliding TTL is the only eviction policy that matches "abandoned" without racing an actively-returning user, already settled as Decision D1. Both are single-service defaults (no ADR — Cart's storage/TTL config is not visible to, or depended on by, any other service's contract).
  - Trade-off accepted: every mutation pays a synchronous PostgreSQL round-trip instead of returning as soon as Redis acknowledges; a guest cart has no recovery path once past 7 days idle (no durable identity to reattach a snapshot to), unlike a logged-in cart's 30-day PostgreSQL grace window.
  - Mirrors: `requirement-spec.md` §6 D1/D5; `edge-cases.md` → "Cart lost on Redis eviction or restart" and "Abandoned-cart expiry races a returning user" (both already resolved — this decision generalizes them into one caching-strategy statement, not a new choice).

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

## Escalations

None. All four decisions above are grounded directly in this service's approved `requirement-spec.md`/`edge-cases.md` and are single-service engineering defaults consistent with the project's shared standards (`docs/standards/api-standards.md`'s gRPC guidance, `docs/standards/ddd-cqrs-standards.md`'s Outbox/replay expectation, `docs/standards/event-standards.md`'s at-least-once/DLQ defaults) — no genuinely equivalent options requiring a business call were found.

## Sign-off

- [ ] Reviewed by a human
- [ ] Approved to proceed to Architecture Agent
