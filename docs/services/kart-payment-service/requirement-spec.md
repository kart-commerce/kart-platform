---
doc_type: requirement-spec
service: kart-payment-service
status: approved
generated_by: requirement-agent
source: docs/requirements/kart-requirements.md
---

# Requirement Spec: kart-payment-service

## 1. Scope

Covers the single BRD service **Payment Service** (BRD §2.1 item 9): "Payment intents, gateways, refunds." No merge; no ADR applies.

Payment is one of only three services the BRD treats as a dedicated deep-dive (§5.1 Order, §5.2 Inventory, §5.3 Payment), rather than folding it into the condensed "Remaining Services" table (§5.4). It is also the platform's explicitly named money-moving-critical service: BRD §2.2 states "Payment must never double-charge → forces idempotency keys + Saga compensation," and §10's Event Catalog gives `Payment*` events the platform's highest retry budget and only paged-on-call DLQ tier ("Money-moving events (`Payment*`) get the highest retry budget and human paging"). This spec draws on §5.3's deep-dive table plus every other BRD section that names Payment (§2.2, §3, §6.1, §10, §11, §12, §18, §22, §24, §27) — see §6 for gaps the BRD leaves unresolved despite this depth.

## 2. Functional Requirements

- Execute an idempotent charge against a payment gateway (`POST /payments/charge`, requiring a mandatory `Idempotency-Key` header, BRD §5.3).
- Enforce idempotent charge-attempt semantics via a unique constraint on the `idempotency_keys` table (BRD §5.3, §6.1: "guarantees exactly-once charge attempt semantics") — this is the concrete mechanism the BRD's domain rule at §2.2 ("must never double-charge") forces.
- Issue refunds against a completed charge (`POST /payments/{id}/refund`, BRD §5.3).
- Consume `OrderCreated` to initiate a charge for a newly created order (BRD §5.3 Consumes row; payload includes `orderId, userId, items, total` per §10).
- Publish `PaymentCompleted` on a successful charge, carrying `orderId, txnId` (BRD §10), consumed by Order and Analytics.
- Publish `PaymentFailed` on a failed or declined charge, carrying `orderId, reason` (BRD §10), consumed by Order to drive Saga compensation (§12.2).
- Publish `RefundIssued` on a successful refund (BRD §5.3 Publishes row) — the BRD states this event exists but gives it no payload fields, consumer, retry count, or DLQ strategy anywhere, unlike `PaymentCompleted`/`PaymentFailed`; see Open Questions.
- Integrate with one or more payment gateways, tokenizing card data at the gateway rather than storing it (BRD §2.1 item 9 names "gateways" plural; BRD §24: "payment data never stored — tokenized by the gateway provider"). No specific gateway/provider is named anywhere in the BRD; see Open Questions.
- Track a refund as its own Saga instance, distinct from the Order Saga's state machine, because refunds "can be partial and asynchronous relative to the original order lifecycle" (BRD §12.2, "Payment Saga" note).
- Participate as a required step in the Order Saga's success flow (`Order->Payment: Charge` → `PaymentCompleted`, BRD §12.1) and as the trigger for compensation on the failure flow (`PaymentFailed` → Order releases the Inventory reservation, BRD §12.2).
- Never persist raw card data; mandatory idempotency keys on all money-moving POSTs (BRD §24, Security/API Security rows) — this applies platform-wide but is stated with Payment as the motivating case.

## 3. Non-Functional Requirements

Pulled from the BRD's global NFR table (§3), the cross-cutting Security section (§24), and the Event Catalog (§10), scoped to this service:

| Attribute | Target | Applies here because |
|---|---|---|
| Availability | 99.99% (order path) — not stated by Payment's name in §3 (which splits tiers only generically as "order path" vs. "secondary"), but far less ambiguous than for a service like Identity: Payment is a required step in both Order Saga sequence diagrams (§12.1, §12.2) and is explicitly listed in Order's own Dependencies row (§5.1: "Payment Service (async)") | An order cannot reach `Confirmed` without a completed charge; Payment failure directly drives Saga compensation |
| Latency | P95 < 300ms (write path, includes Outbox insert), P95 < 150ms / P99 < 400ms (read path) | `POST /payments/charge` is a write on the Order Saga's synchronous critical path; the BRD gives no Payment-specific latency override, so the general write-path NFR applies |
| Consistency | Strong (PostgreSQL write path: `payment_intents`, `idempotency_keys`) | BRD §6.1 names Payment explicitly as write-heavy, "Correctness > raw read speed → PostgreSQL is source of truth"; a stale or eventually-consistent charge state is a correctness defect, not a UX one |
| Reliability | At-least-once delivery + idempotent consumers; "no data loss on Order/Payment events" (BRD §3, general rule, Payment named explicitly) | Applies to `OrderCreated` consumption and `PaymentCompleted`/`PaymentFailed`/`RefundIssued` publication |
| Retry/DLQ | `PaymentCompleted` & `PaymentFailed`: **5x exponential, `payment.dlq`, paged on-call** — the platform's highest retry/paging tier (BRD §10, footnote: "Money-moving events get the highest retry budget and human paging") | Contrasts directly with `OrderCreated`'s own 3x/manual-replay tier and `CouponRedeemed`'s 2x/no-paging tier — Payment is the only service in the BRD's Event Catalog given the paged tier |
| Throughput | 100K RPS sustained / 1M RPS burst platform-wide (BRD §3, §4.2); Peak Orders/Day at 20x during flash sale (§4.1) | Every order that reaches the charge step drives one `POST /payments/charge`, so Payment inherits the platform's peak/flash-sale multiplier directly |
| Security | Zero plaintext secrets, TLS everywhere, PCI-scope isolation ("only this service touches gateway tokens," BRD §5.3 Boundary Rationale); payment data tokenized, never stored (§24); payment gateway API keys held as Kubernetes Secrets (§22); mandatory idempotency keys on money-moving POSTs (§24) | This is Payment's defining NFR — the entire service boundary (§5.3) exists to contain PCI scope to one service |

## 4. Domain Invariants

- A charge must never be executed twice for the same logical payment attempt (double-charge prevention, BRD §2.2: "Payment must never double-charge"), enforced via the unique constraint on `idempotency_keys` (BRD §6.1).
- `payment_intents` is the authoritative record of a charge's state; the BRD's own convention (write-heavy, PostgreSQL source of truth, §6.1) implies no other store or in-memory saga state should be treated as more authoritative than it.
- A refund is a distinct lifecycle from the original charge — "can be partial and asynchronous relative to the original order lifecycle" (BRD §12.2) — and therefore must not be modeled as a simple reversal step inside the Order Saga's own state machine.
- Raw card/payment data must never be persisted by this service; only gateway-issued tokens are stored (BRD §24, §5.3 Boundary Rationale).
- `OrderCreated` consumption and `PaymentCompleted`/`PaymentFailed`/`RefundIssued` publication must be idempotent under RabbitMQ's at-least-once delivery (BRD §3 Reliability row; §13's general Duplicate Message scenario: "Idempotency key check at consumer — second delivery is a no-op").
- A refund amount must not exceed the amount actually captured on the originating charge — inferred from standard payment domain logic and the BRD's general correctness posture (§6.1), not stated explicitly anywhere in the BRD; flagged rather than assumed as designed.

## 5. API Surface (from BRD, starting point only)

| Endpoint/Event | Direction | Notes |
|---|---|---|
| `POST /payments/charge` | Inbound API | Requires `Idempotency-Key` header (BRD §5.3) |
| `POST /payments/{id}/refund` | Inbound API | BRD §5.3; no request/response schema stated |
| `OrderCreated` | Consumed | Published by Order (BRD §5.3, §10); payload `orderId, userId, items, total`; 3x retry / `order.dlq` on the publisher side (§10) |
| `PaymentCompleted` | Published | Consumed by Order, Analytics (BRD §10); payload `orderId, txnId`; 5x retry, `payment.dlq`, paged on-call |
| `PaymentFailed` | Published | Consumed by Order (BRD §10); payload `orderId, reason`; 5x retry, `payment.dlq`, paged on-call |
| `RefundIssued` | Published | Stated only in §5.3's Publishes row; absent from the §10 Event Catalog entirely — no payload, consumer, retry, or DLQ policy stated anywhere; see Open Questions |

No inbound webhook/callback endpoint for asynchronous gateway confirmation appears anywhere in the BRD. Final contract is the API Design Agent's job, not this spec's.

## 6. Open Questions / Flagged Ambiguities

1. **Idempotency-Key semantics unspecified.** BRD §5.3 requires the header and §6.1 states a unique constraint, but the BRD never defines the key's TTL, its scope (per-order, per-user, or globally unique forever), or the expected behavior when the same key is reused with a different request payload (reject as a conflict, vs. silently replay the stored result). Blocking — this is the direct mechanism the §2.2 domain rule depends on.
2. **Payment gateway(s) not named.** BRD §2.1 item 9 says "gateways" (plural) and §5.3's Boundary Rationale references "gateway tokens," but no specific provider (e.g., a card processor, a wallet provider) is named anywhere in the BRD, nor is it stated whether multi-gateway routing/failover is an actual requirement or just plural phrasing. Architecturally significant for the gateway-abstraction layer.
3. **Asynchronous gateway confirmation (webhook) ingestion is absent from the stated API surface.** Only `POST /payments/charge` and `POST /payments/{id}/refund` appear (§5.3), both synchronous. Real gateway integrations underlying "gateways" (§2.1 item 9) typically confirm charges/refunds asynchronously; the BRD states no inbound webhook endpoint, no webhook event contract, and no reconciliation mechanism against gateway-side state.
4. **`RefundIssued` missing from the Event Catalog (§10).** `PaymentCompleted` and `PaymentFailed` both get an explicit retry count (5x) and DLQ strategy (`payment.dlq`, paged on-call); `RefundIssued` is stated as published (§5.3) but has no payload fields, retry count, or DLQ row anywhere in the BRD — a direct BRD gap, not a downstream design choice.
5. **Refund SLA/timing unspecified.** No latency or completion-time target for `POST /payments/{id}/refund` appears anywhere in the BRD, distinct from the generic read/write-path latency NFRs (§3) which are not stated per-refund.
6. **Partial refund / partial capture unaddressed.** BRD §27's own interview-question list (Q29) poses "Design a saga for a partial refund that only covers 2 of 5 items in an order," implying the BRD's authors intended partial refunds to be a real case — but no functional requirement, schema field, or event payload anywhere states how a partial refund or partial capture is represented against `payment_intents`.
7. **Chargeback/dispute handling entirely absent.** No event, API, or NFR anywhere in the BRD mentions chargebacks or disputes, despite this being a standard concern for any money-moving payment integration and a direct interaction risk with the refund saga (§12.2).
8. **Availability tier not assigned by name.** BRD §3 splits Availability only generically into "order path" (99.99%) vs. "secondary" (99.9%) and never places Payment in either explicitly — though Payment's presence in both Order Saga diagrams (§12.1, §12.2) and Order's declared Dependencies row (§5.1) makes the 99.99% read considerably stronger here than for a service the BRD doesn't name in any saga flow. Left to the Architecture Agent to confirm, not assumed here.
9. **Gateway-call retry policy conflated with event-delivery retry.** §10's "5x exponential, paged on-call" governs `PaymentCompleted`/`PaymentFailed` **event delivery** after the fact, not the underlying charge attempt against the gateway itself. The BRD never states how many times (if any) Payment retries an ambiguous or failed gateway call before deciding to publish `PaymentFailed`.

## Sign-off

- [ ] Blocking open questions resolved (Q1 in particular)
- [ ] Reviewed by:
- [ ] Approved to proceed to Architecture Agent
