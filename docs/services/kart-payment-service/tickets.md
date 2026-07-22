---
doc_type: tickets
service: kart-payment-service
status: approved
generated_by: ticket-agent
source: [architecture.md, ddd-model.md, api-contract.yaml, database-design.md, event-contract.md, design-decisions.md — all approved]
---

# Tickets: kart-payment-service

Local draft. Not yet created as real GitHub Issues — that requires the target repo to exist (Project Scaffold Agent) and is a separate, explicit step. Ticket prefix `PAY-` per `kart-conventions.md`.

## Epic: kart-payment-service v1

Idempotent charge execution, partial refunds, asynchronous gateway-confirmation ingestion (including chargebacks, ADR-0012). PCI-scope isolated per BRD §5.3.

| ID | Task | Vertical Slice (Application/Features/) | Depends On | Design Source |
|---|---|---|---|---|
| PAY-1 | Gateway adapter interface + one concrete gateway implementation | `Infrastructure/PaymentGateway/` (not a `Features/` slice — shared infra every feature below calls) | — | requirement-spec §2 Open Question #2 resolution (`IPaymentGatewayAdapter`, one concrete impl at launch, multi-gateway routing out of scope for v1) |
| PAY-2 | Idempotency ledger infrastructure (`IdempotencyRecord` reserve/confirm) | `Infrastructure/Idempotency/` (shared infra — `ChargePayment` and `RefundPayment` both call it) | — | `ddd-model.md` `IdempotencyRecord` aggregate; `database-design.md` `idempotency_keys` table; design-decisions.md's Idempotency Mechanism decision |
| PAY-3 | Charge payment | `ChargePayment` | PAY-1, PAY-2 | `api-contract.yaml` `POST /v1/payments/charge`; `ddd-model.md` `PaymentIntent` aggregate + `PaymentIntentStatus`; `database-design.md` `payment_intents` table; publishes `PaymentCompleted`/`PaymentFailed` |
| PAY-4 | Get payment intent | `GetPaymentIntent` | PAY-3 | `api-contract.yaml` `GET /v1/payments/{id}` (Support Agent refund-cap check, on-call inspection) |
| PAY-5 | Refund payment (Support Agent and Order-compensation callers, same slice) | `RefundPayment` | PAY-1, PAY-2, PAY-3 | `api-contract.yaml` `POST /v1/payments/{id}/refund`; `ddd-model.md` `Refund` child entity + captured-amount-ceiling/dispute-hold invariants; `architecture.md` Compensation-Refund Trigger; `database-design.md` `refunds` table + `idx_refunds_intent_succeeded` |
| PAY-6 | Ingest gateway charge confirmation (webhook) | `IngestGatewayChargeConfirmation` | PAY-3 | `api-contract.yaml` `POST /v1/payments/webhooks/{gateway}` (`eventType` = `charge_succeeded`/`charge_failed`); `ddd-model.md` `GatewayWebhookEvent` dedup ledger + `PaymentIntent`'s monotonic-transition guard; `database-design.md` `gateway_webhook_events` table + `trg_payment_intents_status_guard` |
| PAY-7 | Ingest gateway refund confirmation (webhook) | `IngestGatewayRefundConfirmation` | PAY-5, PAY-6 | `api-contract.yaml` same endpoint, `eventType` = `refund_succeeded`; reuses PAY-6's `GatewayWebhookEvent` dedup mechanism; publishes `RefundIssued` |
| PAY-8 | Ingest chargeback notification (webhook) | `IngestChargebackNotification` | PAY-6 | ADR-0012; `api-contract.yaml` same endpoint, `eventType` = `chargeback_received`; `ddd-model.md` `ChargebackRecord` value object, `Completed → Disputed` transition; publishes `ChargebackReceived` (**new** event) |
| PAY-9 | Idempotency-key TTL partition maintenance job | `Infrastructure/IdempotencyPartitionMaintenance/` | PAY-2 | `database-design.md`'s "TTL Cleanup & Partitioning" section — daily range-partition creation/drop for `idempotency_keys` |
| PAY-10 | Background gateway reconciliation poll | `Infrastructure/GatewayReconciliationJob/` | PAY-3, PAY-6 | requirement-spec §2 Open Question #9 resolution — resolves a `PaymentIntent` left `pending` if neither the synchronous gateway call nor the webhook path ever confirmed a terminal state |

## Notes for Sprint Planner Agent

- PAY-1 and PAY-2 are the two foundational infrastructure tickets everything else depends on, directly or transitively — sequence both first, in parallel with each other (no dependency between them).
- PAY-3 (`ChargePayment`) is the highest-value slice (it's the Order Saga's blocking step) and the deepest dependency chain root — PAY-4, PAY-5, PAY-6, PAY-10 all trace back to it.
- PAY-6, PAY-7, PAY-8 all extend the same `POST /v1/payments/webhooks/{gateway}` endpoint and share the `GatewayWebhookEvent` dedup mechanism PAY-6 establishes — recommend the engineer who builds PAY-6 also builds PAY-7/PAY-8, the same "shared-mechanism tickets grouped together" recommendation `kart-offer-service/tickets.md` makes for its own conditional-update pattern.
- PAY-5 (`RefundPayment`) serves two distinct callers (Support Agent via the public API Gateway, Order's Saga orchestrator via the internal server) through one implementation — do not split into two tickets; the domain logic (captured-amount ceiling, dispute-hold, idempotency) is identical regardless of caller identity, only the security scheme differs (`api-contract.yaml`).
- PAY-9 and PAY-10 are both background/scheduled-job tickets with no request-path dependency on each other — can build in parallel once their respective prerequisites (PAY-2, PAY-3/PAY-6) land.
- No circular dependencies in this graph. Longest chain is PAY-1/PAY-2 → PAY-3 → PAY-6 → PAY-7/PAY-8 (4 deep), or PAY-1/PAY-2 → PAY-3 → PAY-6 → PAY-10 (4 deep).
- Out of scope for this service's own backlog: wiring `kart-order-service`'s Saga orchestrator to actually call PAY-5's endpoint on compensation is a `kart-order-service` ticket, tracked there once that service's own pipeline reaches Ticket Agent — `architecture.md`'s Compensation-Refund Trigger section states the expectation from Payment's side, it does not create Order's own ticket.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner
- [x] Approved
