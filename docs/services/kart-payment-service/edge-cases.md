---
doc_type: edge-cases
service: kart-payment-service
status: approved
generated_by: edge-case-analyzer-agent
source: docs/services/kart-payment-service/requirement-spec.md
---

# Edge Cases: kart-payment-service

## Edge Case: Double-Charge Under Client Retry / Network Timeout Ambiguity

- **What happens:** A caller (Order Service, or a client retry upstream of it) retries `POST /payments/charge` after a network timeout with no confirmed response, risking two completed charges for one logical payment attempt if the original request actually succeeded at the gateway before the response was lost in transit.
- **Why it happens:** A timeout only means "no response observed" — not "no charge occurred." The underlying gateway call may have already committed. This is precisely the failure mode Domain Invariant #1 and requirement-spec's cited BRD §2.2 rule ("Payment must never double-charge") exist to prevent, and why `POST /payments/charge` mandates an `Idempotency-Key` header (requirement-spec §2, §5).
- **Solutions available (3):** DB-level unique constraint on `idempotency_keys`, checked before the gateway call, replaying the stored outcome for a repeated key (requirement-spec's stated mechanism, BRD §6.1) · Two-phase authorize-then-capture with a reconciliation query against actual gateway state before any retry decision · Client-generated idempotency key propagated end-to-end into the gateway call itself, for gateways that accept native idempotency keys
- **Decision:**
  - Chosen: Unique constraint on `idempotency_keys`, replaying the previously stored result on key reuse; forward the same key to the gateway call where the gateway supports native idempotency.
  - Why: matches the mechanism the requirement-spec already cites as BRD-stated (§6.1: "guarantees exactly-once charge attempt semantics") rather than introducing a reconciliation subsystem the BRD never mentions.
  - Trade-off accepted: does not by itself resolve the case where the *original* attempt is itself still unresolved at the gateway when a retry arrives with the same key — that half of the problem is covered separately below ("Saga Compensation Against a Pending/Unknown Gateway State").
  - Escalate: exact idempotency-key TTL and scope (per-order vs. globally unique forever) is unresolved — requirement-spec Open Question #1.

## Edge Case: Gateway Webhook Arriving Out-of-Order or Duplicated

- **What happens:** Asynchronous gateway confirmation for a charge or refund is delivered twice (duplicate), or a "failed"/"pending" notification arrives after a later "succeeded" one due to gateway-side retry, causing a naive consumer to flip a `payment_intent`'s state backward or double-publish `PaymentCompleted`.
- **Why it happens:** requirement-spec Open Question #3 — no inbound webhook endpoint or webhook contract is stated anywhere in the BRD, only the synchronous `POST /payments/charge`/`POST /payments/{id}/refund` pair, yet real gateway integrations behind "gateways" (BRD §2.1 item 9, cited in requirement-spec §2) confirm asynchronously; this is the gateway-origin analogue of the general Duplicate Message failure the BRD itself acknowledges (§13: "Idempotency key check at consumer — second delivery is a no-op").
- **Solutions available (3):** Idempotent ingestion keyed on the gateway's own event ID, plus a monotonic state-ordering guard on `payment_intents` that rejects any transition older than the currently stored state · Deduplicate purely on gateway event ID with no ordering logic · Poll/reconcile gateway status directly instead of trusting push delivery
- **Decision:**
  - Chosen: Idempotent-by-gateway-event-ID ingestion plus a monotonic state-ordering guard rejecting backward transitions on `payment_intents`.
  - Why: mirrors the platform's own stated duplicate-message handling (BRD §13) and requires no new infrastructure beyond the state machine `payment_intents` already needs (requirement-spec Domain Invariants #2).
  - Trade-off accepted: this defines a webhook contract and ordering semantics the BRD states none of — new surface carried to the Architecture/API Design Agents, not resolved here.

## Edge Case: Refund Racing a Chargeback/Dispute on the Same Charge

- **What happens:** A refund (via `POST /payments/{id}/refund`) and a gateway-reported chargeback/dispute against the same original charge are in flight concurrently, risking funds being returned twice (refund completes, then the chargeback separately reverses the same charge again) or a refund being attempted against a charge the gateway has already reversed.
- **Why it happens:** requirement-spec §2 (BRD §12.2) states a refund is tracked as its own Saga instance, separate from the Order Saga, "since refunds can be partial and asynchronous relative to the original order lifecycle" — but requirement-spec Open Question #7 notes the BRD never mentions chargebacks or disputes at all, so nothing reconciles a refund Saga with a dispute landing on the same `payment_intent` concurrently.
- **Solutions available (3):** Mark the `payment_intent` dispute-held on chargeback notification, rejecting new refund attempts against it until resolved · Let both proceed independently and reconcile financially after the fact via ledger reconciliation · Query gateway-side authoritative balance/state synchronously before permitting any refund
- **Decision:**
  - Chosen: Dispute-hold flag on `payment_intents` blocking new refunds once a chargeback is recorded against that intent.
  - Why: cheapest correctness guarantee available given the BRD states no chargeback handling at all (Open Question #7); refusing to act on a disputed intent is safer than letting two independent money movements race, and is consistent with `payment_intents` already being the system of record (requirement-spec Domain Invariants #2, BRD §6.1).
  - Trade-off accepted: chargeback/dispute ingestion, its event contract, and its SLA remain entirely unspecified — this only prevents the race, it doesn't design the missing feature.
  - Escalate: chargeback/dispute handling is a genuine BRD gap (requirement-spec Open Question #7), not an engineering default — needs human/product input before the Architecture Agent designs around it.

## Edge Case: Saga Compensation Against a Pending/Unknown Gateway State

- **What happens:** The Order Saga's compensation flow needs to reverse a charge (e.g., a later saga step fails after `PaymentCompleted` was expected), but the underlying `payment_intent` is still pending or unknown at the gateway — the original synchronous charge call timed out, or its async confirmation (see webhook edge case above) hasn't arrived yet. Issuing a refund in this state risks refunding money that was never actually taken, or racing the eventual confirmation.
- **Why it happens:** requirement-spec §2 cites the BRD's compensation flow (§12.2) only for the case where Payment has already returned `PaymentFailed` before compensation begins — it does not model compensation being triggered while Payment's own state is still unresolved, which is exactly the reachable state the double-charge ambiguity (first edge case above) implies must exist.
- **Solutions available (3):** Compensation must resolve `payment_intent` to a terminal state (via reconciliation against the gateway, not just local event state) before issuing any refund · Model "pending" as its own explicit saga step requiring a timeout-and-reconcile before compensation can proceed · Issue a conditional/idempotent refund request that gateways can safely no-op if no charge actually completed
- **Decision:**
  - Chosen: Compensation logic must resolve `payment_intent` to a terminal state via gateway reconciliation before issuing a refund; a refund against a still-pending intent is rejected/deferred, never fired unconditionally.
  - Why: firing a refund against an unresolved charge is the direct double-money-movement risk BRD §2.2 (requirement-spec Domain Invariants #1) exists to prevent; `payment_intents` (requirement-spec Domain Invariants #2) is the authoritative state to gate on, not saga-local assumptions about Payment's status.
  - Trade-off accepted: introduces a wait/reconciliation step that can stall an order's cancellation if the gateway itself is slow or unreachable — a correctness-over-latency trade the BRD's "never double-charge" rule justifies, but one whose acceptable stall duration the BRD never bounds (requirement-spec Open Question #5, refund SLA unspecified).
