---
doc_type: edge-cases
service: kart-order-service
status: approved
generated_by: edge-case-analyzer-agent
source: docs/services/kart-order-service/requirement-spec.md
---

# Edge Cases: kart-order-service

## Edge Case: Payment-Success / Shipping-Failure Compensation Ordering

- **What happens:** `PaymentCompleted` arrives and the charge succeeds, but the subsequent Shipping step fails or times out, requiring Order to unwind an already-completed money-moving step, not just an inventory hold.
- **Why it happens:** requirement-spec Open Question 2 — the BRD's only documented compensation flow unwinds Inventory when Payment fails; it never defines what unwinds when a *later* step fails after Payment already succeeded, so refund-vs-inventory-release ordering is undefined.
- **Solutions available (3):** compensate in strict reverse execution order (release Inventory, then refund Payment) · compensate all failed-forward steps in parallel · refund Payment first, then release Inventory ("money-first").
- **Decision (3-5 bullets max):**
  - Chosen: reverse-order compensation — release the Inventory reservation first, then issue the Payment refund.
  - Why: mirrors the compensating-transaction convention the BRD already establishes in §12.2 (undo in reverse of forward execution order) and keeps the money-movement step as the last, most auditable action.
  - Trade-off accepted: the order sits in an intermediate "compensating" state slightly longer than parallel compensation would allow, since refund can't start until inventory release confirms.

## Edge Case: Duplicate Order Submission (double-click / client retry)

- **What happens:** a client double-clicks checkout or retries `POST /orders` after a timeout, producing two order-create requests for the same checkout intent.
- **Why it happens:** requirement-spec Open Question 4 — `POST /orders` has no documented `Idempotency-Key` requirement, unlike Payment's `/payments/charge`, so a plain client-side retry is free to create two orders for one checkout.
- **Solutions available (3):** require a client-supplied `Idempotency-Key` header on `POST /orders`, deduplicated via a unique constraint (mirrors Payment's `idempotency_keys` table) · dedupe server-side on a derived key (userId + cart checkout token) · accept duplicates and reconcile/cancel the second order asynchronously after the fact.
- **Decision (3-5 bullets max):**
  - Chosen: client-supplied `Idempotency-Key` + unique constraint, same pattern as Payment.
  - Why: the BRD (§24, requirement-spec §3) mandates idempotency keys on all money-moving POSTs, and order creation is the entry point to a money-moving Saga; reusing Payment's already-specified pattern keeps the platform internally consistent instead of inventing a second dedup mechanism.
  - Trade-off accepted: requires clients to generate and persist an idempotency key across retries, versus a purely server-side reconciliation that needs no client change.

## Edge Case: Saga Step Timeout vs. Eventual-Success Race

- **What happens:** Order times out waiting for `PaymentCompleted`/`ShipmentDispatched` and triggers compensation, but the downstream service actually completes the step right after — so a "late" success event arrives after compensation has already started.
- **Why it happens:** requirement-spec Open Question 7 — no per-step Saga timeout budget is defined in the BRD, and Payment/Shipping communicate asynchronously via events, so nothing prevents a race between a fired timeout and an in-flight downstream success.
- **Solutions available (3):** saga state-guard — every transition checks current saga state before applying; a late success event received after compensation has started is treated as "compensate the compensation" (e.g., a late `PaymentCompleted` after cancellation triggers an immediate refund) · two-phase timeout — soft-timeout pings downstream for current status before triggering compensation · no timeout — wait indefinitely and rely on downstream DLQ/paging instead.
- **Decision (3-5 bullets max):**
  - Chosen: saga state-guard with compensate-the-compensation handling for late success events.
  - Why: consistent with the BRD's idempotent-consumer NFR (requirement-spec §3, Reliability row) and avoids leaving money charged or stock reserved against a cancelled order, which would violate the no-double-charge/no-oversell domain rules (BRD §2.2).
  - Trade-off accepted: Order must implement a code path beyond the BRD's single-direction compensation flow (§12.2) — refund-after-cancel — that the BRD itself never anticipated.

## Edge Case: Outbox Publish Failure/Reordering After DB Commit

- **What happens:** Order commits an order/state-transition row and its outbox row in one transaction, but the outbox poller is delayed or fails to publish (broker down, network partition) before a subsequent state-changing request for the same order is committed, risking out-of-order delivery of the two events.
- **Why it happens:** the Outbox Pattern (BRD §11) deliberately decouples DB commit from broker publish via an independent poller loop, so a window exists where write-side state is ahead of published events for a given order.
- **Solutions available (3):** publish strictly in `created_at` order per aggregate, reusing the BRD's existing `idx_outbox_unpublished` index · attach a per-order monotonic sequence number to the event payload so consumers can detect and buffer out-of-order delivery · shard the poller by aggregate so each order's events are always published by a single poller instance.
- **Decision (3-5 bullets max):**
  - Chosen: publish in `created_at` order per the existing index, plus a per-order monotonic sequence number embedded in the event payload.
  - Why: reuses the Outbox table/index the BRD already specifies (§11) rather than introducing new infrastructure, while giving Saga-critical consumers (Inventory, Payment, Shipping) a concrete way to detect reordering — which matters far more for Order than for less state-sensitive services.
  - Trade-off accepted: consumers need extra sequence-tracking logic instead of assuming broker-delivered order is always safe to apply directly.

## Edge Case: Orphaned/Stuck Saga Detection

- **What happens:** a saga instance stalls indefinitely in a non-terminal state (e.g., Inventory reserved, but neither `PaymentCompleted` nor `PaymentFailed` ever arrives), with no automatic path to resolution.
- **Why it happens:** requirement-spec Open Question 7 (no per-step timeout budget) combined with the BRD's own acknowledgment that this is a live concern (§27's interview question "How do you detect a saga that's stuck halfway forever?") without the Saga Pattern section (§12) documenting any stuck-detection mechanism.
- **Solutions available (2):** a periodic reconciliation job scans `orders` for rows stuck in a non-terminal status past a threshold and forces compensation · rely purely on message-broker redelivery/DLQ alerting with no dedicated reconciliation sweep.
- **Decision (3-5 bullets max):**
  - Chosen: periodic reconciliation job scanning for orders stuck past a threshold, forcing compensation.
  - Why: the BRD already relies on this reconcile-by-polling shape elsewhere (the Outbox poller, §11), so extending the same operational pattern to saga-state reconciliation keeps the platform's operational model consistent rather than introducing a new one.
  - Trade-off accepted: unresolved — the exact staleness threshold cannot be set without the per-step timeout budgets from requirement-spec Open Question 7; escalated together with that question rather than picked arbitrarily here.

## Edge Case: Client Cancel Request Racing an In-Flight Saga

- **What happens:** a client calls `POST /orders/{id}/cancel` while the Saga is mid-flight (e.g., Payment already charged but `ShipmentDispatched` not yet received), racing the orchestrator's own forward progress.
- **Why it happens:** requirement-spec Open Question 3/API surface — the BRD lists `POST /orders/{id}/cancel` as a first-class API (§5.1) alongside the automatic Saga compensation flow (§12.2) but never specifies whether a client-initiated cancel routes through the same compensation machinery or is a separate code path, creating two potential writers to the same order state.
- **Solutions available (2):** route client-initiated cancel through the same Saga/compensation state machine as any other failure trigger (single writer) · handle client cancel as a fully separate code path with its own locking.
- **Decision (3-5 bullets max):**
  - Chosen: route client-initiated cancel through the same Saga/compensation state machine.
  - Why: Order's Boundary Rationale (BRD §5.1) establishes it as the *sole* driver of cross-service business transactions — a second, separate cancellation code path would violate that single-writer principle and reopen the double-compensation risk already identified in the Payment-success/Shipping-failure edge case above.
  - Trade-off accepted: a user-facing cancel click may not take effect instantly if the saga is mid-step — it must wait for the current step to resolve before applying, versus an out-of-band cancel that force-writes a `Cancelled` status immediately.

## Edge Case: `DeliveryStatusUpdated` Terminal Event Arriving Before Order Reaches `Shipped`

- **What happens:** Order consumes `DeliveryStatusUpdated`'s terminal "delivered" value for an order whose own state machine has not yet advanced to `Shipped` — e.g. the terminal delivery event arrives before Order has processed `ShipmentDispatched` for that order, or `ShipmentDispatched` itself is delayed/lost.
- **Why it happens:** requirement-spec's "Terminal delivery event" section (Saga Orchestration, ADR-0005) establishes Delivery Tracking as a genuinely independent async publisher, distinct from and not gated on Order's own `ShipmentDispatched` consumption from Shipping — nothing in the spec requires Delivery Tracking's pipeline for a shipment to wait on Order having already processed `ShipmentDispatched` for the same order, so the two inbound events race with no ordering guarantee between them.
- **Solutions available (3):** state-guard the consumer — if the order is not yet in `Shipped` when the terminal event arrives, do not apply it; NACK so the broker redelivers, or requeue with backoff, until Order's own state catches up · park/buffer the event in a delayed-retry queue and reapply once `Shipped` is reached · relax ordering and allow a direct jump straight to `Delivered` regardless of current state.
- **Decision (3-5 bullets max):**
  - Chosen: state-guard the consumer (option 1) — reject/requeue the event until the order is actually in `Shipped`, never advance the state machine ahead of it.
  - Why: requirement-spec's "Legal state transitions only" Domain Invariant (§4) is explicit that no transition may skip states, and the same section calls out `Shipped → Delivered` as the one transition driven solely by this consumption — admitting a direct skip here would be the one place that invariant is silently violated by the very event that's supposed to respect it.
  - Trade-off accepted: unresolved bound — how long Order should hold/retry the event before treating it as genuinely stuck (rather than merely racing) depends on the per-step timeout budget requirement-spec Open Question 6 leaves undefined; escalated together with that question rather than picked arbitrarily here, same posture as the "Orphaned/Stuck Saga Detection" edge case above.

## Edge Case: Duplicate/Redelivered `DeliveryStatusUpdated` Terminal Event

- **What happens:** a duplicate or redelivered `DeliveryStatusUpdated` terminal "delivered" event arrives for an order already in the `Delivered` state, risking a second `OrderDelivered` publish for the same order.
- **Why it happens:** requirement-spec's Domain Invariants section (§4, "Idempotent event consumption") states directly that "a duplicate or replayed terminal-status delivery must not re-publish a second `OrderDelivered` for the same order," extending the platform's general at-least-once/idempotent-consumer NFR (§3 Reliability row) to this newly-added consumed event.
- **Solutions available (2):** reuse the dedicated idempotency-key/dedup-table pattern used elsewhere on the platform (e.g. Payment's `idempotency_keys` table, per the "Duplicate Order Submission" edge case above) · a simpler state-guard — since `Delivered` is terminal for this transition with no other Order-Saga-driven transition out of it, check the order's current state before publishing and treat "already `Delivered`" as an unconditional no-op.
- **Decision (3-5 bullets max):**
  - Chosen: state-guard against current order state (option 2), not a dedicated idempotency-key table.
  - Why: unlike `PaymentCompleted`/`PaymentFailed`, which need dedup against replay at multiple *non-terminal* points mid-Saga, `Shipped → Delivered` per requirement-spec's "Terminal delivery event" section has exactly one trigger and one destination state that nothing else in the state machine writes to — once the order is `Delivered`, any further terminal `DeliveryStatusUpdated` for it is unconditionally a no-op, so a full key-tracking table adds no protection a plain state check doesn't already give.
  - Trade-off accepted: this specific guard is Order-specific to this transition and doesn't generalize back to the harder mid-Saga idempotency cases above — it only works because `Delivered` has no valid onward Order-Saga transition (refunds are handled by the separate refund saga per requirement-spec §2, not by this state machine).

## Edge Case: Client Cancel Request Racing a Terminal `DeliveryStatusUpdated`

- **What happens:** a client calls `POST /orders/{id}/cancel` at or after the point a terminal `DeliveryStatusUpdated` is in flight or has just been consumed for the same order — i.e. cancellation is requested once physical delivery has already happened or is in the process of being recorded as complete.
- **Why it happens:** the existing "Client Cancel Request Racing an In-Flight Saga" edge case above resolves cancel-vs-Saga races generally by routing cancel through the same state machine as single writer, but that resolution doesn't say what the state-guard should decide when the competing transition is `Shipped → Delivered` specifically — requirement-spec Open Question 2 (state-machine edge transitions) is explicit that it remains open whether `Cancelled` is reachable from `Shipped` at all, and that question is now compounded by an async terminal event that can win or lose the race against the cancel request.
- **Solutions available (2, not a pick between engineering equivalents — see Decision):** reject `POST /orders/{id}/cancel` outright once the order is in `Shipped` (or once a terminal `DeliveryStatusUpdated` is already being processed), forcing the client into a separate returns/refund flow instead · allow the cancel call to remain legal from `Shipped` and let the state-guard's tie-break decide — e.g. an in-flight terminal `DeliveryStatusUpdated` always wins because physical delivery already happened, cancellation is moot.
- **Decision (3-5 bullets max):**
  - Chosen: **escalated, unresolved** — not decided here.
  - Why not decided here: requirement-spec Open Question 2 has already flagged that the BRD gives no basis to determine whether `Cancelled` is reachable from `Shipped`/`Paid` at all; picking a tie-break for this race would silently answer that open product question as a side effect of an engineering pattern, which is exactly the kind of business/policy call the "Orphaned/Stuck Saga Detection" edge case above already treats as escalate-don't-pick, per this agent's own failure-condition guidance for genuine business judgment calls.
  - Trade-off accepted: N/A — pending human decision; carried forward together with requirement-spec Open Question 2 for sign-off, since the two questions can't be resolved independently of each other.
