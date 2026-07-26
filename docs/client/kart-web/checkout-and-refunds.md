---
doc_type: checkout-and-refunds
service: kart-web
status: pending-approval
generated_by: human-authored (client tier)
source: docs/client/kart-web/requirement-spec.md §3.4/§8, docs/client/kart-web/api-integration-map.md, docs/services/kart-order-service/ddd-model.md, docs/services/kart-payment-service/requirement-spec.md
---

# Checkout & Customer Refunds: kart-web

Expands `requirement-spec.md` §3.4 into a full checkout specification and closes `api-integration-map.md`'s open question on customer-initiated refunds ("confirm whether `kart-web` only ever displays refund status, not initiates it directly").

## Part A — Checkout

### A.1 Flow

Guest or authenticated → address (saved or new) → shipping method → payment method (saved token or new, via the external gateway's hosted tokenization field, `requirement-spec.md` §5) → live re-quote (`kart-offer-service` `/pricing/quote`, currency-aware per `docs/client/localization.md`) → review → **Place Order**. Every step re-validates against server state on entry (no cached client assumption about stock/price/address survives a step transition) — consistent with Domain Invariant #2's re-quote rule.

### A.2 Idempotency

`Idempotency-Key` header (client-generated UUID, persisted for the duration of the checkout attempt) attached to every money-moving POST — `POST /orders`, the eventual `POST /payments/charge` path, and (new, §B below) `POST /orders/{id}/return-request`. The submit control is disabled from the moment of submission until a definitive response (success or failure) arrives, preventing a double-click or a network-retry from producing a second order/charge — per `requirement-spec.md` §3.4 and the platform-wide mandatory-idempotency-key rule.

### A.3 Currency & Order Locking

The currency active on the cart at submission time becomes the order's permanently locked transaction currency (`docs/client/localization.md` §"Order Currency Locking") — this is resolved before `POST /orders` fires, never after.

### A.4 Processing State

Order placement surfaces the BRD's own documented eventual-consistency window (`kart-requirements.md` §12) as an explicit "processing your order" state — never a fake-instant confirmation that can later silently fail. This state resolves to Order Confirmed or a specific failure reason (stock unavailable, payment declined) once the saga's synchronous gate (Inventory reserve) and the async chain settle far enough to know.

## Part B — Customer-Initiated Refunds

### B.1 Why This Needed a Decision

`kart-order-service/ddd-model.md`'s existing legal-transition graph already anticipates this exact flow — `Delivered → Refunded` "via the external refund saga reporting back, BRD §12" — but no document had specified what triggers that transition from the customer's side, or how it interacts with `kart-payment-service`'s existing `POST /payments/{id}/refund` (documented as "support-agent driven," per `container-diagram.md`). This section makes that concrete, reusing both existing mechanisms rather than inventing a parallel one.

### B.2 Eligible Order States & Time Window

- **Self-service return/refund request**: only from **`Delivered`**, within **30 calendar days** of the `OrderDelivered` event timestamp. 30 days is this doc's own engineering default (no BRD figure exists, same pattern the platform already uses for other unstated numbers, e.g. Identity's session TTL) — a standard e-commerce baseline.
- **`Created`/`Reserved`/`Paid`**: no refund applies — the existing **cancel** flow (`POST /orders/{id}/cancel`, already specified) is the correct action; no payment has necessarily captured yet, or the cancel-then-compensate path already unwinds it.
- **`Shipped`** (in transit, not yet delivered): cancel is already illegal at this state (`ddd-model.md`'s legal-transition graph); a customer wanting to refuse an in-transit order is directed to Support (`kart-admin-web`'s existing support-console, §3.3, already scoped) rather than a new self-service transition — reuses existing scope instead of opening a new backend transition edge this doc has no authority to add unilaterally.
- **`FulfillmentException`/`Cancelled`/already-`Refunded`**: no new return request accepted (already terminal or already in an exception-handling path with its own resolution mechanism).

### B.3 Request Submission (Client)

Order Detail → "Request a Return" (visible only when §B.2's state/window conditions hold) → reason code (required, from a fixed enum: damaged/defective, not as described, no longer needed, wrong item shipped, other) + optional free-text note + line-item/quantity selection (supports partial returns) → submit with `Idempotency-Key` (§A.2). The client computes the requested refund amount as the sum of the selected line items' captured price — **never a hand-typed amount** — though the backend's existing `SUM(refunds.amount) <= captured_amount` constraint (`kart-payment-service/requirement-spec.md` §2) remains the authoritative guard regardless of what the client sends.

### B.4 Approval Workflow

A new lightweight `ReturnRequest` child record on the `Order` aggregate (state: `Requested → Approved/Rejected → RefundIssued`) — modeled inside `kart-order-service`'s existing bounded context (it's a continuation of the `Delivered → Refunded` edge that already exists in `ddd-model.md`, not a new service; ADR-0001's merge-justification reasoning doesn't apply here since there's no cross-context ambiguity to resolve). Formalizing this in `kart-order-service`'s own docs is captured as a ticket (`tickets.md`), not invented wholesale in this client-tier doc.

- **Auto-approval fast path** — moves straight to `Approved` (no human review) when **all** of: within the 30-day window; order total ≤ **$200 USD-equivalent** (converted via the same `/pricing/quote` mechanism used for display, `docs/client/localization.md`); no prior approved return already exists on this order; the payment method supports direct programmatic refund (i.e., not a manual/offline rail); the requesting customer has fewer than **3 approved returns in the trailing 90 days** (repeat-returner signal, forces manual review regardless of amount if exceeded).
- **Manual review path** — everything else — lands in `kart-admin-web`'s new Refund Requests queue (extends existing §3.3 Customer Support Operations scope), reviewed by Support Agent/Admin, `Approved` (optionally at an adjusted amount, never higher than requested) or `Rejected` (reason required, shown verbatim to the customer, never genericized — same "never a generic rejection" rule §3.3's coupon-validation UX already sets).

### B.5 Payment Gateway Interaction

On `Approved` (either path), the existing `POST /payments/{id}/refund` endpoint is called — no new payment endpoint is introduced. The auto-approval path calls it under a system principal (`system:return-auto-approval`), the manual path under the reviewing Support Agent/Admin's own principal — both reuse the exact same endpoint, permission surface, and partial-refund mechanism (`captured_amount` constraint) `kart-payment-service` already implements. A Support Agent's action is additionally capped at their existing per-order refund-amount grant (`kart-admin-web/requirement-spec.md` §5); an amount above that cap requires `Admin` escalation.

### B.6 Customer Notifications

- **Approved → refunded**: the existing `RefundIssued` event (already consumed by Notification, `kart-payment-service/requirement-spec.md`) drives the "your refund has been processed" notification — no new event needed.
- **Rejected**: a **new** notification (reusing Notification Service's existing fan-out mechanism, no new service) informs the customer of the rejection and its stated reason — captured as a ticket, since today's event catalog has no rejection-notice trigger.
- **Requested (auto-approval pending eligibility evaluation)**: an immediate in-app acknowledgment ("we've received your request") — not a separate notification-service event, since it's synchronous with the request-submission response itself.

### B.7 Partial vs. Full Refund

Partial: the selected-line-items sum (§B.3). Full: all line items selected, equal to the order's full `captured_amount`. Both paths use the identical mechanism — "full" is not a special case, only the boundary value of "partial."

### B.8 Audit Trail

Every `ReturnRequest` transition stamps `created_by`/`updated_by` via the platform's existing `Kart.Shared.Auditing` interceptor (BRD §24.3 pattern, already used everywhere) — `system:return-auto-approval` for the auto path, the reviewing principal's id for the manual path. No new audit mechanism required.

### B.9 Fraud Prevention

The auto-approval eligibility check itself (§B.4: amount threshold, prior-return count, payment-rail restriction) **is** the fraud gate — server-evaluated, so thresholds are tightenable later without any client-code change. The rolling-90-day repeat-returner check specifically targets return-abuse patterns (e.g., wardrobing) independent of any single request's own apparent legitimacy.

## Part C — Summary Table (Order State → Available Customer Action)

| Order State | Customer Action Available |
|---|---|
| `Created`, `Reserved`, `Paid` | Cancel (`POST /orders/{id}/cancel`) |
| `Shipped` | None self-service — contact Support |
| `Delivered` | Request Return/Refund (§B), within 30 days |
| `FulfillmentException` | None — ops-driven resolution (`kart-order-service` existing flow) |
| `Cancelled`, `Refunded` | None — terminal |
