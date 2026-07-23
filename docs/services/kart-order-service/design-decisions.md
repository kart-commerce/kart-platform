---
doc_type: design-decisions
service: kart-order-service
status: approved
generated_by: design-decision-agent
source: docs/services/kart-order-service/requirement-spec.md, docs/services/kart-order-service/edge-cases.md
---

# Design Decisions: kart-order-service

Cross-cutting technology/design-pattern choices forced by this service's requirement-spec and edge-cases. Service boundaries, aggregate/domain model, and schema/table design are out of scope here (Architecture/DDD/Database Design Agents).

## Decision: Saga Orchestration Style

- **Requirement driving this:** Domain Invariant "Sole orchestrator invariant" (requirement-spec §4); BRD §2.2's forced-decision note that Order "is the Saga orchestrator ... forces distributed transaction design."
- **Options considered (2):** orchestrated saga — Order holds the full state machine and explicitly drives each step · choreography — each service reacts to the prior service's event with no central owner.
- **Decision:**
  - Chosen: orchestrated saga, single Order-owned state machine.
  - Why: the sole-orchestrator invariant is explicit that no service other than Order may drive a cross-service business transaction; choreography has no single owner by design and would directly violate that invariant.
  - Trade-off accepted: Order becomes a higher-blast-radius single point of coordination (mitigated by its own 99.99% availability tier and the elevated Retry/DLQ tier below), versus choreography's more distributed but harder-to-reason-about failure surface.

## Decision: Saga Compensation Strategy

- **Requirement driving this:** edge-cases.md's "Payment-Success/Shipping-Failure Compensation Ordering" (requirement-spec Open Questions resolution #1, final); Domain Invariant "Compensation completeness" (requirement-spec §4).
- **Options considered (3):** backward recovery in strict reverse execution order (release Inventory, then refund Payment) · parallel compensation of all failed-forward steps · forward recovery / retry-until-success on the failed step instead of undoing prior ones.
- **Decision:**
  - Chosen: backward recovery, strict reverse order — release Inventory reservation first, then issue the Payment refund.
  - Why: mirrors BRD §12.2's existing reverse-of-forward compensating-transaction convention and keeps money movement as the last, most auditable action; forward recovery is inapplicable since Order cannot force a failed Shipping step to succeed, and leaving the order non-terminal would violate compensation completeness.
  - Trade-off accepted: a slightly longer intermediate "compensating" window than parallel compensation, since refund cannot start until inventory release confirms.

## Decision: Communication Style Per Saga Dependency

- **Requirement driving this:** BRD §5.1 Dependencies row (Inventory "sync reserve call + async confirm"; Payment/Shipping/Delivery Tracking async); ADR-0002 (Order↔Shipping fully async); ADR-0009 (Order↔Inventory reserve call is genuinely synchronous, ADR-0002's note does not extend to it).
- **Options considered (3):** synchronous REST/HTTP request-reply · synchronous gRPC (internal, high-throughput) · asynchronous pub/sub over the message bus.
- **Decision:**
  - Chosen: synchronous REST (`POST /inventory/reserve`) for the one call that gates order creation (Inventory reserve); asynchronous pub/sub for Payment (charge), Shipping (shipment creation), and Delivery Tracking (status updates).
  - Why: Inventory reserve is the only downstream call BRD/ADR-0009 fix as a genuine blocking RPC directly inside the `POST /orders` write path; everything else is deliberately decoupled (ADR-0002/ADR-0005) so a Payment/Shipping/Delivery Tracking outage cannot cascade into order creation failing.
  - Trade-off accepted: the one synchronous call needs its own timeout/circuit-breaker treatment (see below) since a slow Inventory response now sits directly in the client-facing latency budget, unlike the fully decoupled async steps.

## Decision: Concurrency Control for Order State Transitions

- **Requirement driving this:** edge-cases.md's "Client Cancel Request Racing an In-Flight Saga" (single writer through the state machine) and "Saga Step Timeout vs. Eventual-Success Race" ("every transition checks current saga state before applying"); Domain Invariant "Legal state transitions only" (requirement-spec §4).
- **Options considered (3):** optimistic concurrency via state-guard/compare-and-swap on the order's current status (check expected state before applying a transition, reject if mismatched) · pessimistic row-level lock (`SELECT ... FOR UPDATE`) held for the duration of the transition · distributed lock (e.g., Redis/Redlock) per order id spanning saga steps.
- **Decision:**
  - Chosen: optimistic state-guard (compare-and-swap on current status), the same pattern edge-cases.md already names repeatedly (Saga Step Timeout race, `DeliveryStatusUpdated`-before-`Shipped` race, Client Cancel racing Saga).
  - Why: saga steps involve network round-trips to Inventory/Payment/Shipping; holding a DB row lock across those round-trips would be unacceptable against the sub-300ms write-path NFR, whereas a cheap expected-state check at each transition point serializes writers without blocking on I/O.
  - Trade-off accepted: a transition that loses the compare-and-swap must be retried/rejected by its own caller path (saga step handler or the cancel endpoint returning `409`) rather than blocking automatically the way a DB lock would.

## Decision: Idempotency Mechanism — `POST /orders` (API Layer)

- **Requirement driving this:** edge-cases.md's "Duplicate Order Submission" (requirement-spec Open Questions resolution #3, final); BRD §24's platform-wide mandatory idempotency keys on money-moving POSTs.
- **Options considered (3):** client-supplied `Idempotency-Key` header, deduplicated via a unique DB constraint (mirrors Payment's `idempotency_keys` table) · server-derived dedup key (`userId` + cart checkout token) · accept duplicates and reconcile/cancel the second order asynchronously.
- **Decision:**
  - Chosen: client-supplied `Idempotency-Key` header + unique constraint, same pattern as Payment.
  - Why: reuses an already-specified platform pattern (BRD §5.3/§6.1) instead of inventing a second dedup mechanism, keeping the platform internally consistent.
  - Trade-off accepted: requires clients to generate and persist an idempotency key across retries, versus a purely server-side reconciliation that needs no client change.

## Decision: Idempotency Mechanism — Saga Event Consumers

- **Requirement driving this:** Domain Invariant "Idempotent event consumption" (requirement-spec §4: `InventoryReserved`, `PaymentCompleted`, `PaymentFailed`, `ShipmentDispatched`, `DeliveryStatusUpdated` must not double-advance the saga); edge-cases.md's "Duplicate/Redelivered `DeliveryStatusUpdated` Terminal Event."
- **Options considered (3):** a single dedicated idempotency-key/dedup tracking table applied uniformly to every consumed event · state-guard against current order/state-machine status only, applied uniformly to every consumed event · hybrid split by event class — state-guard for the one exactly-once, terminal-destination transition (`DeliveryStatusUpdated` → `Delivered`), and state-guarded-per-saga-step handling for the mid-saga events that can legitimately be evaluated at multiple non-terminal points.
- **Decision:**
  - Chosen: hybrid split, exactly as edge-cases.md itself reasons — a plain state-guard ("already `Delivered`" → no-op) for `DeliveryStatusUpdated`, and per-transition state-guard checks (current saga state must match the expected pre-state) for `InventoryReserved`/`PaymentCompleted`/`PaymentFailed`/`ShipmentDispatched`.
  - Why: `Shipped → Delivered` has exactly one trigger and one destination state nothing else writes to, so a full key-tracking table adds no protection a state check doesn't already give; the other four events occur at multiple non-terminal saga points and need the same per-transition state-guard the Saga Step Timeout edge case already establishes, not a separate dedup table either.
  - Trade-off accepted: two related but distinct idempotency justifications to maintain instead of one uniform mechanism — accepted because it mirrors a real difference between a single-destination terminal event and multi-point mid-saga events, not an invented distinction.

## Decision: Consumer Ordering Guard for `DeliveryStatusUpdated` Arriving Before `Shipped`

- **Requirement driving this:** edge-cases.md's "`DeliveryStatusUpdated` Terminal Event Arriving Before Order Reaches `Shipped`" (final, hold/retry window resolved to 60s); Domain Invariant "Legal state transitions only" (requirement-spec §4: "no transition may skip states"); requirement-spec Open Questions resolution #6 (Shipping asynchronous dispatch budget, 60s — the numeric bound this pattern reuses).
- **Options considered (3):** state-guard the consumer — if the order is not yet in `Shipped` when the terminal event arrives, NACK so the broker redelivers/requeues with backoff, bounded to a fixed window, then escalate to DLQ rather than hold indefinitely · park/buffer the event in a dedicated delayed-retry queue and reapply once `Shipped` is reached · relax ordering and allow a direct jump straight to `Delivered` regardless of current state.
- **Decision:**
  - Chosen: state-guard the consumer with NACK-and-backoff redelivery, bounded to the Shipping dispatch budget (60s, requirement-spec resolution #6); if the order still hasn't reached `Shipped` once that window elapses, the event is routed to `tracking.dlq` instead of held indefinitely.
  - Why: the "Legal state transitions only" invariant is explicit that no transition may skip states — this is the one consumer that must actively enforce ordering rather than trust broker delivery order, since admitting a direct skip here is the single place that invariant would otherwise be silently violated; reusing `tracking.dlq` (`DeliveryStatusUpdated`'s existing retry/DLQ tier per BRD §10) avoids standing up a second alerting path for the same event.
  - Trade-off accepted: an order whose `ShipmentDispatched` is genuinely lost (not just late) holds the terminal delivery event unresolved for the full 60s window before it's escalated, rather than failing fast or silently advancing the state machine early — a dedicated delayed-retry queue would add equivalent latency without removing this trade-off, so it wasn't chosen over the simpler NACK/backoff mechanism.

## Decision: Outbox Table Strategy

- **Requirement driving this:** BRD §11 Outbox Pattern (requirement-spec §2 Persistence & Messaging); requirement-spec Open Questions resolution #5, final ("`order_events` doubles as the Outbox table").
- **Options considered (3):** reuse `order_events` as both the audit-trail table and the Outbox relay table (add `published_at`/event-type/routing columns plus an `idx_outbox_unpublished`-equivalent partial index) · introduce a separate, dedicated `outbox` table alongside `order_events` · CDC-based outbox (e.g., a Debezium-style WAL tail) instead of an application-level poller.
- **Decision:**
  - Chosen: reuse `order_events` for both roles; no second table.
  - Why: BRD §5.1 already names `order_events` as Order's table and BRD §11 already specifies the generic Outbox schema — a second, unlisted table would contradict the resolved decision and double the write-path's row-insert cost for no benefit.
  - Trade-off accepted: `order_events`'s schema is now dual-purpose (audit trail + outbox relay); any future audit-only change (e.g., retention policy) must not silently break the outbox poller's assumptions, and vice versa.

## Decision: Cross-Event Ordering Guarantee

- **Requirement driving this:** edge-cases.md's "Outbox Publish Failure/Reordering After DB Commit."
- **Options considered (3):** publish strictly in `created_at` order per the existing `idx_outbox_unpublished` index, plus a per-order monotonic sequence number embedded in the event payload · shard the outbox poller by aggregate id so a single poller instance always owns a given order's events · rely on broker/consumer-side timestamp comparison alone with no explicit sequence number.
- **Decision:**
  - Chosen: `created_at`-ordered publish (existing index) plus a per-order monotonic sequence number in the event payload.
  - Why: reuses existing Outbox infrastructure with no new poller architecture, while giving Saga-critical consumers (Inventory, Payment, Shipping) a concrete, cheap way to detect and buffer out-of-order delivery — poller sharding is heavier operationally for the same guarantee.
  - Trade-off accepted: consumers must implement sequence-tracking/buffering logic instead of assuming broker-delivered order is always safe to apply directly.

## Decision: Per-Step Saga Timeout Budget

- **Requirement driving this:** requirement-spec Open Questions resolution #6, final (Inventory 2s / Payment 30s / Shipping 60s); this also fixes the Orphaned Saga staleness threshold and the `DeliveryStatusUpdated`-before-`Shipped` hold/retry window (both edge-cases.md).
- **Options considered (3):** fixed, concrete per-step budget tailored to each step's sync/async nature and position in the saga · a single uniform saga-wide timeout applied identically to every step · adaptive/percentile-based timeout computed from rolling downstream latency history.
- **Decision:**
  - Chosen: fixed per-step budgets — Inventory (sync reserve): 2s; Payment (async completion): 30s; Shipping (async dispatch): 60s.
  - Why: each number is derived from the step's position in the saga (sync/gating vs. async/non-gating) and the write path's own P95<300ms NFR; a uniform timeout would be either too tight for Shipping's legitimately slow carrier handoff or too loose for the write-path-gating Inventory call.
  - Trade-off accepted: three separate numbers to tune and monitor instead of one; explicitly carried forward to the Architecture Agent as non-blocking numeric refinement pending real load-test data (the existence of per-step budgets is not open, only their exact values).

## Decision: Circuit Breaker on Outbound Calls

- **Requirement driving this:** NFR Fault Tolerance row (requirement-spec §3): "circuit breakers on all outbound calls ... directly applies to Order's synchronous Inventory reserve call and its dependency edges to Payment/Shipping/Delivery Tracking."
- **Options considered (3):** per-dependency circuit breaker (closed/open/half-open) wrapping the synchronous Inventory call and the outbox poller's broker-publish call · timeout + retry only, no breaker state · bulkhead isolation (separate connection/thread pool per dependency) without breaker semantics.
- **Decision:**
  - Chosen: circuit breaker on the two calls Order actually makes directly outbound — the synchronous Inventory reserve call (tripping on the 2s timeout) and the outbox poller's publish-to-broker call (tripping on sustained publish failure).
  - Why: Payment/Shipping/Delivery Tracking are pure async consumers/producers over the message bus, not calls Order issues directly — the breaker's real point of leverage is the one synchronous RPC and the broker-publish call, matching what the NFR calls out by name.
  - Trade-off accepted: an open breaker on Inventory fails `POST /orders` fast rather than queuing/retrying indefinitely, favoring write-path availability over guaranteed reservation attempts — consistent with "graceful degradation, no cascading failure."

## Decision: Retry/DLQ Tiering for Published Events

- **Requirement driving this:** requirement-spec Open Questions resolution #7, final (Order's own lifecycle events elevated to 5x + paged-on-call); NFR Retry/DLQ row (requirement-spec §3); reusable event-standards.md's TTL-ladder and criticality-scaled retry rule.
- **Options considered (3):** TTL-ladder parking-lot retry (`retry.5s`/`retry.30s`/`retry.5m`) at 5x exponential + paged on-call, applied to `OrderCreated`/`OrderConfirmed`/`OrderCancelled`/`OrderCompensationTriggered`/`OrderDelivered` · leave those events at BRD §10's original 3x/manual-replay-only tier · immediate in-place requeue retry (rejected platform-wide per event-standards.md — hot-loop risk under persistent failure).
- **Decision:**
  - Chosen: TTL-ladder, 5x exponential retry to `order.dlq`, paged on-call, for all five of Order's own published lifecycle events.
  - Why: a stuck `OrderCreated` blocks Payment from ever being invoked — at least as operationally severe as a stuck `PaymentCompleted` — and Order is the named subject of BRD §3's 99.99% availability tier; gating its own events behind a lower-touch manual-replay tier would undercut that target.
  - Trade-off accepted: materially more on-call paging volume for Order's own events than the BRD's original default tier implied; `DeliveryStatusUpdated` (a consumed, not published, event) keeps its own separate 3x/`tracking.dlq` tier, unaffected by this elevation.

## Decision: Orphaned/Stuck Saga Reconciliation Mechanism

- **Requirement driving this:** edge-cases.md's "Orphaned/Stuck Saga Detection"; BRD §27's interview question on detecting a saga stuck halfway forever.
- **Options considered (2):** periodic reconciliation job sweeping `orders` for rows stuck past a threshold and forcing compensation · rely purely on message-broker redelivery/DLQ alerting with no dedicated reconciliation sweep.
- **Decision:**
  - Chosen: periodic reconciliation sweep, run every 60s, acting on orders stuck past 2x the budget of the step currently awaited (4s awaiting `InventoryReserved`, 60s awaiting `PaymentCompleted`/`PaymentFailed`, 120s awaiting `ShipmentDispatched` — derived from the Per-Step Saga Timeout Budget decision above). **The action taken is not uniform**: Inventory-await and Payment-await cases force the original reverse-order compensation (release Inventory, mark `Cancelled`); the Shipping-await case instead forces entry into `FulfillmentException` (see the decision below) — never automatic refund-and-cancel — since `PaymentCompleted` has already been received by that point, matching how an explicit `ShipmentCreationFailed` is handled.
  - Why: reuses the same reconcile-by-polling operational shape the platform already applies via the Outbox poller (BRD §11), keeping Order's operational model consistent; broker DLQ alone does not catch a crashed in-process timeout handler, which is exactly the gap the sweep exists to close. The Shipping-await carve-out keeps this decision consistent with "Post-Confirmation Fulfillment Exception Handling" below rather than silently reintroducing automatic post-confirmation refunding through a second code path.
  - Trade-off accepted: up to one sweep interval (60s) plus the grace threshold can elapse before a genuinely stuck saga is acted on — not instant detection.

## Decision: Post-Confirmation Fulfillment Exception Handling

- **Requirement driving this:** requirement-spec.md's "Post-Confirmation Fulfillment Exception Handling" (Saga Orchestration, ADR-0015); edge-cases.md's "Shipment Creation Permanently Fails After Order Confirmation."
- **Options considered (3):** reuse the existing pre-confirmation compensation flow (release Inventory, mark `OrderCancelled`) despite payment already being captured · introduce a new, distinguishable non-terminal hold state (`FulfillmentException`) requiring an explicit manual/ops action to resolve · auto-cancel and auto-refund immediately with no human review.
- **Decision:**
  - Chosen: new `FulfillmentException` hold state (`Paid → FulfillmentException`), entered either by consuming `ShipmentCreationFailed` directly or by the Orphaned/Stuck Saga sweep's Shipping-await threshold firing with no such event ever received (see the Reconciliation Mechanism decision above) — the two triggers converge on the identical state, since a silent timeout is no more automatically resolvable than an explicit failure. Resolved only by an explicit manual/ops action into either `Paid` (retry) or `Cancelled` (a conditional, idempotent Inventory-release attempt followed by an explicit Payment refund call).
  - Why: the existing compensation flow was designed for a reservation/charge that never completed — reusing it here would silently leave a captured charge unaccounted for; auto-refunding on the first carrier failure (or the first sweep-detected timeout) forecloses a correctable failure (e.g., bad address) with no BRD-stated basis for a specific auto-retry policy.
  - Trade-off accepted: this is the one Saga transition in the whole state machine that depends on a human/operational trigger rather than resolving itself automatically — a deliberate, narrow exception to the otherwise fully automated saga.

## Decision: Chargeback Reaction Mechanism

- **Requirement driving this:** requirement-spec.md's "Chargeback Reaction" (Saga Orchestration, ADR-0012); edge-cases.md's "Chargeback Received Against an Order in Any Post-Payment State."
- **Options considered (3):** treat `ChargebackReceived` as illegal/ignorable before `Delivered`, actionable only afterward · carve out a narrow, explicit exception allowing a direct `→ Refunded` transition from any state `Paid` onward, including the non-terminal `FulfillmentException` hold · introduce a third terminal state distinct from both `Cancelled` and `Refunded` specifically for chargeback-driven closures.
- **Decision:**
  - Chosen: narrow carve-out — direct `→ Refunded` transition from **any** state `Paid` onward (`Paid`, `Shipped`, `Delivered`, or `FulfillmentException`), plus a state-guarded (idempotent no-op if already released) Inventory release attempt; no second Payment-initiated refund call is ever made. `FulfillmentException` is deliberately included, not omitted — a held order has already had `PaymentCompleted`, so it is exactly as reachable by a bank-initiated chargeback as any other post-`Paid` state.
  - Why: the chargeback has already reversed the charge externally by the time this event arrives regardless of Order's current lifecycle position — treating it as illegal pre-`Delivered` would leave Order's own read model wrong about the order's true payment state; a third terminal state would duplicate `Refunded`'s existing meaning for no behavioral difference.
  - Trade-off accepted: the previously-exceptionless "`Refunded` only reachable from `Delivered`" rule now has exactly one named exception — scoped tightly to this one ADR-driven event, not a general loosening of the state machine.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner
- [x] Technology/pattern choices approved
- [x] Approved to proceed to Architecture Agent
