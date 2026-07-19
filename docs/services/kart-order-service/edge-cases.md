---
doc_type: edge-cases
service: kart-order-service
status: pending-approval
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
