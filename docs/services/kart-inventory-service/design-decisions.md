---
doc_type: design-decisions
service: kart-inventory-service
status: pending-approval
generated_by: design-decision-agent
source: docs/services/kart-inventory-service/requirement-spec.md, docs/services/kart-inventory-service/edge-cases.md
---

# Design Decisions: kart-inventory-service

Cross-cutting technology/design-pattern choices this service's requirement-spec and edge-cases force. Service boundaries, aggregates/domain model, and schema/table design are out of scope here — those belong to the Architecture, DDD, and Database Design Agents respectively. Every decision below either restates an already-resolved requirement-spec/edge-cases call in technology-palette terms (referenced, not re-derived) or adds a new cross-cutting pattern choice the spec's NFRs/invariants force but don't themselves name a mechanism for.

## Decision: Concurrency Control Pattern for Stock Rows

- **Requirement driving this:** Domain Invariant (requirement-spec §4): stock must never go negative/be oversold under concurrent reservation; FR §2 and NFR §3 both state `SELECT ... FOR UPDATE` on stock rows; edge-cases.md's "Oversell under concurrent reservation," "Replenishment racing an active reservation," and "Multi-warehouse split-stock allocation races."
- **Options considered (3):** Pessimistic row lock (`SELECT ... FOR UPDATE`) held for the transaction · Optimistic concurrency (version column, retry-on-conflict at commit) · Atomic conditional statement (single `UPDATE ... WHERE qty >= N`, no explicit lock)
- **Decision:**
  - Chosen: Pessimistic row-level locking via `SELECT ... FOR UPDATE`, applied uniformly to every writer that touches a stock row — reservation, release, and replenishment — never a different mechanism per writer. For the multi-warehouse fallback (no single warehouse can satisfy the line), all candidate warehouse rows for that SKU are locked in one transaction, in ascending `warehouse_id` order, allocated greedily, all-or-nothing.
  - Why: requirement-spec Decision 1 (§6) resolves §2.2's "optimistic locking" phrasing as superseded shorthand — §5.2/§6.1's concrete `SELECT ... FOR UPDATE` design is authoritative, corroborated by `PLATFORM_BLUEPRINT.md` naming Inventory the platform's highest-contention service on exactly this mechanism. The replenishment edge case requires the identical lock-compatible mechanism on that write path too — an app-level read-then-write would not be safely serialized even against the same row. The multi-warehouse edge case requires the ascending-`warehouse_id` lock order to avoid deadlock across the multi-row transaction.
  - Trade-off accepted: reduced throughput on hot SKUs from lock contention (vs. optimistic locking's higher throughput but retry-storm risk, rejected in both the requirement-spec and the oversell edge case) — and replenishment writes now contend for the same row as hot reservation traffic, accepted since replenishment is presumably far less frequent (edge-cases.md notes the BRD gives no volume figures to confirm this, so it stays a stated assumption, not a proven fact).

## Decision: Reservation Hold Expiry Mechanism

- **Requirement driving this:** Domain Invariant (§4): a reservation hold is time-bounded and must not persist indefinitely; edge-cases.md's "Reservation left dangling by a failed/abandoned Saga step" and "TTL firing while Payment is merely slow, not actually failed."
- **Options considered (3):** TTL-based periodic sweep, self-contained inside Inventory, no cross-service signal · Saga-side timeout watchdog in Order Service that force-triggers compensation · Manual/admin reconciliation tooling only, no automated expiry
- **Decision:**
  - Chosen: TTL = 15 minutes from reservation creation; a periodic sweep (every 60 seconds), owned entirely inside Inventory, drives any expired-but-still-`RESERVED` hold through the same idempotent release path as an explicit release, publishing the same `InventoryReleased` event (no distinct expiry event). The sweep is deliberately blind to Payment/Order's live status — no heartbeat, no renew, no query-back.
  - Why: requirement-spec Decision 2 (§6). Keeping the sweep entirely inside Inventory's own boundary matches its Boundary Rationale (independently scalable/lockable without depending on Order staying healthy). Edge-cases.md's TTL-vs-slow-Payment race explicitly rejects heartbeat/renew and query-before-release options because both would reintroduce the cross-service dependency this design deliberately avoids.
  - Trade-off accepted: a legitimately slow-but-succeeding Payment can lose its stock hold past 15 minutes; mitigated (not eliminated) by a mandatory "late success" handling path on Order's side — a `PaymentCompleted` arriving after TTL-release must trigger a fresh reservation attempt, with refund-and-cancel as the fallback if that reservation fails. This is a real, knowingly-accepted business/customer-experience cost, not a free trade-off.

## Decision: Release Idempotency & State Machine Design

- **Requirement driving this:** Domain Invariant (§4): release must be idempotent regardless of trigger (explicit API call, `OrderCancelled`, `OrderCompensationTriggered`, TTL sweep) — must not double-credit stock nor re-publish a duplicate `InventoryReleased`; edge-cases.md's "Compensating-transaction rollback correctness if Payment fails after Inventory already reserved."
- **Options considered (3):** Idempotent release keyed on reservation ID, backed by an explicit reservation state machine with terminal states (`RESERVED → RELEASED`/`EXPIRED`) · Distributed lock/mutex around release per reservation ID · Idempotency enforced purely at the message-consumer layer (dedupe table), with no domain-level state machine
- **Decision:**
  - Chosen: Idempotent release keyed on reservation ID, backed by an explicit state machine with terminal states. Every release trigger converges on the same state-checked write, inside the same PostgreSQL transaction as the stock-row lock — a release against an already-terminal reservation is a no-op that still returns success (and does not re-publish `InventoryReleased`).
  - Why: edge-cases.md's resolution — directly satisfies §4's no-duplicate-publish invariant without new infrastructure, and stays consistent with Inventory's PostgreSQL-as-source-of-truth NFR (§3) rather than introducing a distributed lock as a second source of truth.
  - Trade-off accepted: gives up the stronger single-point-of-truth guarantee a distributed lock would provide, in favor of a state-machine check inside the same transaction that already holds the row lock — judged sufficient since no cross-instance coordination is otherwise needed.

## Decision: Event Publish Atomicity — Transactional Outbox Pattern

- **Requirement driving this:** Domain Invariant (§4): `InventoryReserved`/`InventoryReleased` must only publish once the stock-row write is durably committed, never before; NFR §3 write latency budget explicitly "includes Outbox insert"; Reliability NFR (§3): at-least-once delivery + idempotent consumers, applied uniformly to all of Inventory's own events (requirement-spec Decision 6).
- **Options considered (3):** Transactional Outbox (event row written in the same DB transaction as the stock-row write; a separate relay publishes from the Outbox table) · Direct dual-write (commit the DB write, then publish directly from the request handler) · Change-Data-Capture (CDC) off the stock/reservation table
- **Decision:**
  - Chosen: Transactional Outbox — every `InventoryReserved`/`InventoryReservationFailed`/`InventoryReleased`/`InventoryReplenished` write is inserted into an Outbox table inside the same transaction as the stock-row lock/write; a separate relay process publishes from the Outbox, never a direct in-request publish.
  - Why: this is the only option that satisfies the "publish only after durable commit" invariant without a distributed transaction; the BRD already names the Outbox pattern platform-wide, and requirement-spec §3's write-latency budget explicitly accounts for "Outbox insert" as part of `/inventory/reserve` and `/inventory/release`'s cost, confirming Inventory is meant to use it rather than a lighter mechanism.
  - Trade-off accepted: publish latency trails commit by the relay's poll/dispatch interval instead of being instantaneous — acceptable because Order's saga only needs eventual, at-least-once confirmation via the async event; the synchronous part of reserve is the API response itself (ADR-0009), not the event's arrival.

## Decision: Communication Style for Reserve/Release — Synchronous REST, Diverging From the Generic gRPC Example

- **Requirement driving this:** FR §2/API Surface §5: `POST /inventory/reserve` and `POST /inventory/release` are stated as concrete, sync, REST-shaped endpoints; ADR-0009 confirms the reserve step is genuine synchronous RPC over this endpoint, not an async event.
- **Options considered (2):** Synchronous REST/HTTP, per the BRD's own concrete endpoint definitions · Internal gRPC — the reusable `agent-reusables/docs/standards/api-standards.md` names "an inventory reserve check" as its own illustrative example of when gRPC is the right default ("Reserved for internal, high-throughput synchronous calls only")
- **Decision:**
  - Chosen: Synchronous REST/HTTP, matching the BRD's already-approved, concrete endpoint shape.
  - Why: requirement-spec §5's API Surface table states these as REST-shaped endpoints (`POST /inventory/reserve`, `POST /inventory/release`), not RPC service definitions, and ADR-0009 independently confirms the reserve step is a genuine synchronous call over that shape. The generic reusable standard's gRPC example is a project-agnostic illustration of *a kind* of call ("an inventory reserve check"), not a Kart-specific mandate — it does not override this service's own approved, sign-off'd contract shape.
  - Trade-off accepted: gives up gRPC's lower serialization overhead/native streaming under the platform's stated 100K RPS sustained / 1M RPS burst ceiling — accepted because REST already meets the stated write-latency budget (§3: P95 < 300ms) and changing the wire protocol now would contradict the requirement-spec's already-approved endpoint definitions. If a future load test shows REST/HTTP is the actual throughput bottleneck, that is a new cross-cutting question for a fresh ADR, not a re-opening of this one.

## Decision: Read-Path Caching Strategy for `GET /inventory/{sku}`

- **Requirement driving this:** NFR §3: read latency P95 < 150ms, P99 < 400ms; NFR §3: strong consistency on the PostgreSQL write path; NFR §3: 100K RPS sustained / 1M RPS burst throughput.
- **Options considered (3):** No cache — read directly from PostgreSQL on every call · Short-TTL cache-aside (e.g. Redis, a few seconds) in front of the read endpoint only · Write-through cache, synchronously invalidated on every stock-row write
- **Decision:**
  - Chosen: Short-TTL cache-aside (Redis) in front of `GET /inventory/{sku}` only. The reservation/release/replenishment write path never reads through this cache — it always takes a fresh `SELECT ... FOR UPDATE` inside its own transaction, so the oversell invariant is never exposed to cached staleness.
  - Why: this read endpoint is informational display, not a source of truth for any allocation decision — the Domain Invariants (§4) govern the write path, not this read — so a small bounded staleness window is safe, and it directly serves the stated read-latency budget under the platform's highest-contention throughput ceiling.
  - Trade-off accepted: `GET /inventory/{sku}` can show a briefly stale quantity (up to the cache TTL) immediately after a reservation/release/replenishment commits — accepted since no functional requirement ties this endpoint's response to real-time exactness; write-through invalidation was rejected as unnecessary complexity on the hottest write path for a read endpoint that doesn't need strict freshness.

## Decision: Resilience Budget — Lock-Wait Fail-Fast Timeout for Reservation Writes

- **Requirement driving this:** NFR §3: write latency P95 < 300ms; `PLATFORM_BLUEPRINT.md`'s framing of Inventory as "the platform's highest-contention service"; availability tier 99.99% (requirement-spec Decision 8, order-path tier).
- **Options considered (3):** Bounded `lock_timeout` on the `SELECT ... FOR UPDATE` acquisition, failing fast with a retryable error once exceeded · Unbounded lock wait (block until acquired) · Application-level bulkhead/semaphore per SKU limiting concurrent in-flight reservation attempts before they reach the DB lock
- **Decision:**
  - Chosen: A bounded PostgreSQL `lock_timeout` on the reservation transaction's `SELECT ... FOR UPDATE`, set comfortably inside the P95 < 300ms write budget, returning a fast, retryable failure to the synchronous caller (Order) rather than queuing indefinitely.
  - Why: an unbounded wait on a hot SKU would let lock-queue depth grow unboundedly under the stated 1M RPS flash-sale burst, risking connection-pool exhaustion that starves unrelated SKUs — directly threatening the 99.99% availability tier this service carries as an order-path-critical dependency. A bounded, fail-fast timeout confines the blast radius of one hot SKU's contention to that SKU's own callers.
  - Trade-off accepted: a caller can receive a transient failure on a genuinely hot SKU even though stock exists overall, requiring Order to retry — acceptable since Order's synchronous call already needs a fail path for genuine oversell (`InventoryReservationFailed`); a lock-timeout failure is a distinct, retryable case alongside it, not a new category of caller-facing complexity.

## Decision: Event Retry/DLQ Tier for Inventory's Published Events — Standard Tier Confirmed

- **Requirement driving this:** NFR §3 Retry/DLQ row; requirement-spec Decision 7 (§6); `docs/standards/kart-conventions.md`'s "Money-Moving Criticality" rule (Payment* events get the highest retry count + paging; other events use the standard tier).
- **Options considered (2):** Standard platform tier — 2x retry → `inventory.dlq` (§10; ADR-0007) · Payment's heavier tier — 5x retry + human paging on final failure
- **Decision:**
  - Chosen: Standard 2x-retry/`inventory.dlq` tier for `InventoryReserved`, `InventoryReservationFailed`, `InventoryReleased`, and `InventoryReplenished` — not upgraded to Payment's tier.
  - Why: requirement-spec Decision 7 — Inventory's correctness under message loss already has an independent, non-messaging safety net Payment lacks: the synchronous reserve call fails fast for the caller regardless of the async event's fate, and the TTL sweep self-heals a lost release. PostgreSQL remains the durable source of truth regardless of whether the event describing a state change is ever delivered.
  - Trade-off accepted: a DLQ'd Inventory event can sit unprocessed longer before a human notices than a paged Payment event would — accepted per requirement-spec's own risk-acceptance rationale (Decision 7); this is a confirmation of an already-set tier, not a new call.

## Sign-off

- [ ] Reviewed by a human before this service proceeds to the Architecture Agent
- [ ] Chosen technologies/patterns approved as-is, or corrections requested
