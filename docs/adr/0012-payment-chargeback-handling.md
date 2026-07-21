---
doc_type: adr
status: proposed
---

# ADR-0012: Chargeback/Dispute Handling — New `ChargebackReceived` Event

## Status

Proposed (pending sequential ADR number assignment)

## Context

`kart-requirements.md` names no event, API, or NFR anywhere for chargebacks or disputes, despite this being a standard concern for any money-moving payment integration (BRD §2.1 item 9 "gateways", §2.2 "Payment must never double-charge", §12.2's refund-as-its-own-saga note). `kart-payment-service`'s `requirement-spec.md` (Open Question #7) and `edge-cases.md` ("Refund Racing a Chargeback/Dispute on the Same Charge") both correctly flagged this as a genuine BRD gap rather than silently guessing, and the edge-case's Decision explicitly escalated it as needing a resolution before the Architecture Agent designs around it.

This is cross-cutting in the same shape as ADR-0005 (`OrderDelivered`) and ADR-0006 (`UserAccountUpdated`): it introduces a brand-new domain event not previously named anywhere in the BRD, with a consumer in another service (`kart-order-service`) that must react to it. It is not a single-service internal engineering default, so it is recorded here rather than decided silently inside one service's own docs.

`kart-order-service`'s own `requirement-spec.md`/`edge-cases.md` already resolve the adjacent question of compensation ordering when a later Saga step fails after Payment has already succeeded (Order's edge-case "Payment-Success / Shipping-Failure Compensation Ordering": reverse-order compensation, release Inventory then refund Payment). The chargeback flow defined here must stay consistent with that resolution: a chargeback is an *externally* forced reversal of a charge that has already cleared, so Order's reaction is to hold/cancel and release inventory — it must never also trigger a Payment-side refund for the same funds, since the gateway/bank has already reversed them.

## Decision

1. **New event `ChargebackReceived`**, published by Payment, added to `kart-requirements.md` §10's Event Catalog:

   | Event | Publisher | Consumer(s) | Payload (key fields) | Retry | DLQ Strategy |
   |---|---|---|---|---|---|
   | `ChargebackReceived` | Payment | Order, Notification, Analytics | `orderId, paymentIntentId, chargebackId, amount, reason` | 5x (money-critical) | `payment.dlq`, paged on-call |

   Routed under the existing `payment.*` routing key convention (§9), so it falls automatically under Notification's already-resolved consumed scope (ADR-0003, rule 1: "all `order.*` and `payment.*` routed events") and Analytics' already-resolved full fan-in (ADR-0004) — neither of those ADRs needs modification, this event simply joins their existing default rule. Order is added as an explicit functional consumer because it must act, not just log.

2. **Payment-side handling**: on receiving a chargeback notification from the gateway (via the webhook ingestion path Payment's own docs define for asynchronous gateway confirmation), Payment:
   - Marks the corresponding `payment_intent` as `disputed` (a dispute-hold flag, per `edge-cases.md`'s existing decision), blocking any new refund attempt against that intent.
   - Publishes `ChargebackReceived` carrying the original `orderId` so Order can correlate it back to its own saga/state machine.
   - Does **not** itself initiate a refund — the chargeback is the money movement; Payment only records and reports it.

3. **Order-side handling** (functional expectation on `kart-order-service`, to be reflected in its own docs on its own pass): on consuming `ChargebackReceived`, Order holds or cancels the order using its own existing compensation logic — release Inventory if still held, mark the order into a terminal `Cancelled`/`Refunded`-adjacent state — but does **not** call Payment for a refund, since the chargeback has already reversed the charge externally. This keeps the flow consistent with Order's reverse-order compensation decision without double-reversing funds.

## Consequences

- Chargeback/dispute handling now has a minimal, concrete event contract instead of being entirely unmodeled; `kart-payment-service`'s Open Question #7 and its escalated edge-case are both resolved by this decision.
- `kart-order-service`'s own docs will need `ChargebackReceived` added to its Consumes list and a short note on its hold/cancel reaction the next time its own pipeline pass runs — this ADR states the expectation but does not edit that service's files directly (out of scope for this run).
- This does not design full dispute lifecycle management (e.g., representment/evidence submission, dispute-won reversal back to a healthy `payment_intent`) — only the minimal "stop the bleeding" flow: hold, notify, prevent a double refund. Fuller chargeback lifecycle handling, if ever needed, is a new, separate decision.
- The reconciliation/webhook mechanism this decision assumes as the ingestion path for gateway-reported chargebacks is the same one `kart-payment-service`'s own docs already define for asynchronous gateway confirmation generally (charge/refund status) — no new ingestion mechanism is introduced solely for chargebacks.
