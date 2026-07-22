---
doc_type: ddd-model
service: kart-payment-service
status: approved
generated_by: ddd-agent
source: docs/services/kart-payment-service/architecture.md, docs/services/kart-payment-service/requirement-spec.md, docs/services/kart-payment-service/edge-cases.md, docs/services/kart-payment-service/design-decisions.md, docs/adr/0012-payment-chargeback-handling.md
---

# DDD Model: kart-payment-service

Three aggregate roots in one bounded context. Each is checked against the transaction-boundary test (`docs/standards/ddd-cqrs-standards.md`: "if two things can't be saved in one transaction, they are two aggregates, not one") — the split below is driven by that test, not by convenience.

## Aggregate: PaymentIntent

**Entity:** `PaymentIntent` — identified by `PaymentIntentId`. The authoritative record of a charge's state (requirement-spec Domain Invariant #2); never delegated to or duplicated inside the Order Saga's own state machine.

**Child entity:** `Refund` — identified by `RefundId`, always accessed and persisted through its parent `PaymentIntent` (requirement-spec §2, Open Question #6 resolution: `SUM(refunds.amount) <= payment_intents.captured_amount` is enforced in the *same transaction* as the refund insert — the transaction-boundary test puts `Refund` inside `PaymentIntent`'s aggregate, not as its own root, even though it lives in a physically separate child table for cardinality reasons — see Modeling Decision #1).

**Value objects:**
- `GatewayToken` — the opaque, gateway-issued reference to tokenized card data; `PaymentIntent` never holds raw card data (requirement-spec Domain Invariant #4).
- `CapturedAmount` — `{ amount, currency }` (Money shape), the ceiling every `Refund` under this intent is checked against.
- `GatewayTransactionId` (nullable until `Completed`) — the gateway-assigned transaction id set exactly once a charge succeeds; this is the `txnId` field `PaymentCompleted`'s BRD §10 payload (`orderId, txnId`) carries, so it must be durably stored on `PaymentIntent`, not derived or reconstructed after the fact.
- `PaymentIntentStatus` — `Pending | Completed | Failed | Disputed`. `Pending` is the only non-terminal state; `Completed`/`Failed` are terminal for the charge itself; `Disputed` is reachable only from `Completed` (a chargeback against a charge that never completed is not meaningful — requirement-spec/ADR-0012 model chargebacks as reversing a charge that already cleared).
- `ChargebackRecord` (nullable) — `{ chargebackId, amount, reason, receivedAt }`, set once a chargeback notification is ingested; presence of this value object is exactly what puts `PaymentIntentStatus` into `Disputed` (see Modeling Decision #4 — deliberately not a repeatable/multi-valued history, per ADR-0012's minimal scope).

**Invariants:**
- A charge must never be executed twice for the same logical attempt (requirement-spec Domain Invariant #1) — enforced in cooperation with the `IdempotencyRecord` aggregate below, not by `PaymentIntent` alone (see Cross-Aggregate Interaction).
- `PaymentIntent` is the sole authoritative record of charge state; no saga-local or in-memory state may be treated as more authoritative (requirement-spec Domain Invariant #2).
- State transitions are monotonic: once `PaymentIntentStatus` reaches a terminal value (`Completed` or `Failed`), no further charge-confirmation transition is accepted except the single legitimate escalation `Completed → Disputed`; a redelivered or out-of-order webhook implying any other transition is a no-op, not applied (edge-cases.md "Gateway Webhook Arriving Out-of-Order or Duplicated"; design-decisions.md's concurrency-control decision).
- `SUM(Refund.amount WHERE Refund.status = 'succeeded') <= CapturedAmount.amount`, enforced transactionally at the point a new `Refund` is inserted (requirement-spec Domain Invariant, Open Question #6 resolution).
- A `Disputed` `PaymentIntent` rejects any new `Refund` attempt until the dispute resolves (requirement-spec Domain Invariant, Open Question #7 resolution / ADR-0012) — enforced in the same transaction as the refund-ceiling check above, since both gate the same insert.
- A `Refund` is never a simple reversal step inside the Order Saga's own state machine — it is modeled, and orchestrated as its own Saga instance, independently of `PaymentIntent`'s own charge-lifecycle state (BRD §12.2; requirement-spec Domain Invariant #3). This is a process/orchestration statement, not a second DDD aggregate — see Modeling Decision #1 for why `Refund` still lives inside the `PaymentIntent` aggregate as data.
- Raw card/payment data is never persisted; only `GatewayToken` is stored (requirement-spec Domain Invariant #4).

**Domain events (published):**
- `PaymentCompleted` — existing, BRD §10. Fired exactly once, only when `PaymentIntentStatus` reaches `Completed`.
- `PaymentFailed` — existing, BRD §10. Fired exactly once, only when `PaymentIntentStatus` reaches `Failed`; never fired speculatively while the gateway outcome is still ambiguous (requirement-spec Open Question #9 resolution — the intent is left `Pending` instead).
- `RefundIssued` — existing, BRD §10 (gap closed by ADR-0007). Fired once per successful `Refund` child entity, carrying that `Refund`'s own `refundId`/`amount` — one event per partial refund, not one event for the whole `PaymentIntent`.
- `ChargebackReceived` — **new**, ADR-0012. Fired once per ingested chargeback notification, immediately after `ChargebackRecord` is set and `PaymentIntentStatus` moves to `Disputed`.

## Aggregate: IdempotencyRecord

**Entity:** `IdempotencyRecord` — identified by `IdempotencyKeyScope` (see value object below). Reserved *before* the external gateway call is made and confirmed *after* it returns — see Modeling Decision #2 for why this cannot be the same aggregate as `PaymentIntent`.

**Value objects:**
- `IdempotencyKeyScope` — `{ idempotencyKey, endpoint }`, where `endpoint ∈ { charge, refund }` (requirement-spec Open Question #1 resolution: scoping on the key alone would let a charge and a refund collide on the same caller-supplied value).
- `RequestPayloadHash` — a deterministic hash of the inbound request body, compared on replay to distinguish an identical-payload retry (safe to replay) from a same-key/different-payload conflict (`409`).
- `StoredResponse` (nullable until the gateway call resolves) — the response body returned on a safe replay within the TTL window.

**Invariants:**
- Unique per `IdempotencyKeyScope` (requirement-spec Domain Invariant #1/#8) — the DB-level unique constraint BRD §6.1 names.
- A 24-hour TTL bounds the replay window (requirement-spec Open Question #1 resolution, a stated industry-standard default since the BRD names the mechanism but not a number); after expiry the same key may be reused as a brand-new logical attempt — modeled as the record simply no longer being considered "live" for lookup purposes past `expiresAt`, not a physical delete.
- A lookup hit with a matching `RequestPayloadHash` within the TTL returns `StoredResponse` with no second gateway call; a lookup hit with a differing hash is a conflict (`409`), never a silent overwrite.

**Domain events:** none — this is a pure infrastructure/idempotency-ledger aggregate, not a business-meaningful entity in its own right (the same reasoning `kart-delivery-tracking-service/ddd-model.md` applies to its own `WebhookDedupEntry`).

## Aggregate: GatewayWebhookEvent

**Entity:** `GatewayWebhookEvent` — identified by `GatewayEventId` (the gateway's own event identifier, never generated by Payment). The dedup ledger for asynchronous gateway confirmations (charge/refund settlement, and chargeback notifications) arriving via `POST /payments/webhooks/{gateway}` — same shape and purpose as `kart-delivery-tracking-service`'s `WebhookDedupEntry` for carrier webhooks, applied here to the payment-gateway analogue (requirement-spec Open Question #3 resolution).

**Value objects:**
- `GatewayEventType` — the gateway-reported kind of confirmation (`charge_succeeded`, `charge_failed`, `refund_succeeded`, `chargeback_received`, etc. — exact enumeration is gateway-adapter-specific, not fixed here since requirement-spec §2 already defers concrete gateway selection to the Architecture Agent/infrastructure).
- `AppliedTransition` (nullable until processed) — records which `PaymentIntentStatus` transition (or refund/chargeback effect) this event actually caused, so a duplicate delivery can be recognized as a no-op rather than reprocessed.

**Invariants:**
- `GatewayEventId` is processed at most once (idempotent ingestion) — a duplicate delivery of the same `GatewayEventId` is a no-op, never reapplied.
- Applying an event's implied transition to the referenced `PaymentIntent` is itself gated by `PaymentIntent`'s own monotonic-transition invariant above — `GatewayWebhookEvent` records that ingestion happened, `PaymentIntent` is what actually enforces ordering; the two invariants work together, not redundantly (edge-cases.md "Gateway Webhook Arriving Out-of-Order or Duplicated").

**Domain events:** none published externally — this is Payment's own internal ingestion ledger, not a platform-visible event.

## Cross-Aggregate Interaction

- **Charge idempotency (`PaymentIntent` ↔ `IdempotencyRecord`):** creating a charge reserves an `IdempotencyRecord` first (in its own transaction), then makes the external gateway call (non-transactional by nature — an HTTP call to an external system), then confirms the outcome by writing `PaymentIntent`'s new state *and* `IdempotencyRecord.StoredResponse` together. The two aggregates cannot share one transaction across the external call, which is exactly the DDD standard's test for why they are two aggregates, not one (Modeling Decision #2). A retried request with the same `IdempotencyKeyScope` short-circuits before ever reaching `PaymentIntent` again.
- **Refund idempotency:** identical shape, `endpoint = refund` in `IdempotencyKeyScope`, whether the caller is Support Agent tooling, the client-facing API, or Order's Saga-compensation call (architecture.md's Compensation-Refund Trigger — Order derives its own deterministic key from `(orderId, paymentIntentId, "compensation-refund")`, the charge-side equivalent of deriving from `(orderId, "charge")` for the `OrderCreated`-triggered charge).
- **Webhook ingestion (`GatewayWebhookEvent` → `PaymentIntent`):** a webhook delivery first checks/inserts `GatewayWebhookEvent` by `GatewayEventId` (idempotent ingestion); only a genuinely new event proceeds to attempt a transition on the referenced `PaymentIntent`, which independently re-validates the transition is not backward before applying it. Both checks are required — the first stops exact duplicates, the second stops distinct-but-stale/out-of-order events the first check alone would let through.

## Modeling Decisions & Assumptions (resolved here, not escalated — engineering defaults, revisable)

1. **`Refund` is a child entity of the `PaymentIntent` aggregate, not its own aggregate root** — even though BRD §12.2 describes a refund as tracked "as its own Saga instance, distinct from the Order Saga's state machine." That sentence is about *process/orchestration* modeling (a refund's saga lifecycle is independent of the order's), not a DDD aggregate-boundary statement. The actual transaction-boundary test (`SUM(refunds.amount) <= captured_amount`, checked atomically against the same `payment_intents` row on every insert, requirement-spec §2/§4) requires `Refund` and `PaymentIntent` to be written in one transaction — the DDD standard's own rule ("if two things can't be saved in one transaction, they are two aggregates, not one," read in its contrapositive: if they *must* be saved in one transaction to hold an invariant, they're one aggregate) puts `Refund` inside `PaymentIntent`.
2. **`IdempotencyRecord` is a separate aggregate root from `PaymentIntent`** — the opposite conclusion from #1, and deliberately so: the external gateway call sits *between* reserving the idempotency record and confirming `PaymentIntent`'s resulting state, so those two writes structurally cannot share one transaction (an HTTP call cannot participate in a PostgreSQL transaction). This is the textbook shape the DDD standard's test is meant to catch — two aggregates, not one, precisely because atomicity across them is impossible by construction, not by choice.
3. **`GatewayWebhookEvent` is a separate aggregate root, mirroring `kart-delivery-tracking-service`'s `WebhookDedupEntry`** — its identity (`GatewayEventId`) and lifecycle (received → processed) are independent of any single `PaymentIntent`; it exists purely to make webhook ingestion idempotent, the same justification already established as platform precedent for the identical carrier-webhook problem in Delivery Tracking.
4. **Chargeback is modeled as a single nullable `ChargebackRecord` value object on `PaymentIntent`, not a repeatable child entity or its own aggregate.** ADR-0012 explicitly scopes chargeback handling to the minimal "stop the bleeding" flow — hold, notify, prevent a double refund — and explicitly defers "full dispute lifecycle management (representment/evidence submission, dispute-won reversal)" as "a new, separate decision" if ever needed. Modeling a full chargeback history/lifecycle now would be building ahead of a requirement that doesn't exist yet; a single overwritable record is sufficient for the ADR's actual scope and is the smaller, more honest model of what's actually specified.
5. **`PaymentIntentStatus`'s allowed transitions are exactly `Pending → {Completed, Failed}` and `Completed → Disputed`** — derived directly from requirement-spec's own state description (a charge is pending until it resolves terminally; a chargeback can only reverse a charge that actually completed) rather than a general-purpose state machine library; no other transition is meaningful given what this service does, so none is modeled speculatively.
6. **Idempotency key derivation for non-header-bearing callers (the `OrderCreated` consumer and Order's Saga-compensation refund call) is deterministic, not caller-supplied** — already resolved at the Architecture Agent stage (architecture.md's Sync/Async Resolution and Compensation-Refund Trigger sections); restated here only to confirm it fits `IdempotencyRecord`'s `IdempotencyKeyScope` value object with no special-casing needed.

## Proposed Ubiquitous Language Additions

No new cross-service term conflicts found. Appended to `docs/ddd/ubiquitous-language.md` under a new "Owned by `kart-payment-service`" section (this pass) — see that file for the full entries; `Order` (referenced, `kart-order-service`) is the only externally-owned term this bounded context touches, via opaque `orderId` reference only.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner
- [x] Approved to proceed to API/Database/Event Design Agents
