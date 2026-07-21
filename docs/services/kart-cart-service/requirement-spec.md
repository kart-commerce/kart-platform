---
doc_type: requirement-spec
service: kart-cart-service
status: approved
generated_by: requirement-agent
source: docs/requirements/kart-requirements.md
---

# Requirement Spec: kart-cart-service

## 1. Scope

Covers the single BRD service **Cart** (BRD §2.1 item 7: "Cart lifecycle, merge, expiry"). No merge with another BRD service applies here — unlike Offer, there is no ADR bounding this service against a sibling; Cart stands alone as its own bounded context.

Cart sits directly ahead of checkout: it is the last place a customer's intent is mutable before Order takes over as Saga orchestrator (BRD §5.1). Its three named responsibilities — lifecycle (add/update/remove items), merge (guest cart ↔ logged-in cart), and expiry (abandoned-cart reclamation) — are all present in the BRD row but none are elaborated beyond the label.

## 2. Functional Requirements

- Maintain cart contents (add/update/remove line items) via `/cart` (BRD §5.4). The BRD's condensed service table gives only the resource path, not per-verb semantics (GET/POST/PUT/DELETE) — final HTTP contract is the API Design Agent's job (non-blocking, carried forward).
- Merge a guest (anonymous-session) cart into a logged-in user's cart via `/cart/merge` (BRD §2.1 item 7, §5.4). **Resolved (Decision D2, single-service default, no ADR):** on merge, sum quantities for overlapping SKUs, keep all non-overlapping SKUs from both carts (union), and cap the merged cart at the documented line-item limit (Decision D4). See §6 for full rationale; mirrored in `edge-cases.md`'s "Guest-to-user cart merge conflict".
- Expire abandoned carts (BRD §2.1 item 7: "expiry"). **Resolved (Decision D1, single-service default, no ADR):** sliding TTL — 30 days idle for a logged-in user's cart, 7 days idle for a guest cart, both reset on any read/write touch; PostgreSQL snapshot retained 30 additional days past Redis eviction as a soft-expiry recovery window. See §6 for full rationale; mirrored in `edge-cases.md`'s "Abandoned-cart expiry races a returning user".
- Publish `CartCheckedOut` when a cart moves to checkout (BRD §5.4). **Resolved:** the BRD's Event Catalog (§10) does carry this row — publisher Cart, consumer Analytics only (funnel/conversion tracking), payload `cartId, userId, items`, retry 2x, DLQ `cart.dlq` — added by the platform's event-catalog completeness pass (ADR-0007, confirmed unchanged by ADR-0008's second pass). ADR-0007 further states explicitly that Order does **not** consume this event; Order's creation trigger is the client's synchronous `POST /orders` call (BRD §5.1, confirmed by `kart-order-service/requirement-spec.md` §5). `CartCheckedOut` is therefore audit/analytics-only, not a Saga-triggering event. The exact point in Cart's own request flow where this event is emitted (e.g. on a dedicated `POST /cart/checkout`, or as a side effect Cart raises after observing the client proceed to `POST /orders`) is final HTTP/event-wiring detail — carried non-blocking to the API Design Agent and Event Design Agent, per ADR-0007's own note that this should be "double-checked against `kart-cart-service`'s ... eventual architecture-agent output."
- Consume `InventoryReservationFailed` (BRD §5.4, confirmed as a Cart-bound event in the Event Catalog §10 row: publisher Inventory, consumers "Order, Cart") — Cart is a secondary consumer alongside Order. **Resolved (Decision D3, single-service default, no ADR):** Cart's handling is idempotent and pre-checkout-only — it flags the affected line item as unavailable for the user to see and clears the flag on the next successful validation, and is a no-op if the cart has already checked out (Order owns post-checkout compensation as sole Saga orchestrator). See `edge-cases.md`'s "Checkout races `InventoryReservationFailed`" for the full decision.
- Store cart state in Redis with a PostgreSQL snapshot (BRD §5.4: "Redis + PostgreSQL snapshot"; BRD §16 Caching: "Distributed Cache | Session tokens, cart snapshots | Redis Cluster, consistent hashing across nodes"). **Resolved (Decision D5, single-service default, no ADR, mirrors `edge-cases.md`'s "Cart lost on Redis eviction or restart"):** PostgreSQL is the durable, authoritative store; Redis is a synchronously-updated (write-through) low-latency read cache in front of it, not an independent source of truth. Every cart mutation writes PostgreSQL first (or in the same synchronous path) before the write is considered acknowledged; Redis eviction or a node restart therefore never loses a committed cart mutation — the next read is a cache-miss repopulated from PostgreSQL.

## 3. Non-Functional Requirements

Pulled from the BRD's global NFR table (§3), scoped to this service:

| Attribute | Target | Applies here because |
|---|---|---|
| Availability | 99.9% (secondary tier) — **Resolved (Decision D6, single-service default, no ADR):** the BRD's 99.99% "order path" tier (§3) is scoped to the services that actually execute the Order Saga — Order, Inventory, Payment, Shipping, the only four shown publishing onto the Message Bus in §5.5's diagram and the only four wired into §12's Saga steps. Cart, like Product/Search/Identity, is a customer-facing edge service the client reaches through the API Gateway *before* a Saga exists; a Cart outage blocks browsing-to-checkout initiation the same way a Product or Search outage would, but does not stall or corrupt an order Saga already in flight. Trade-off accepted: Cart tolerates ~526 min/year downtime budget rather than ~52 min/year; if production usage shows cart unavailability directly costing checkouts at a rate the business finds unacceptable, this tier should be revisited in a later architecture review — that data does not exist yet. | BRD §3 (tier definitions), §5.5 (diagram), §12 (Saga steps) |
| Latency | P95 < 150ms, P99 < 400ms (read path) | `/cart` is read/written on effectively every product-detail and checkout-adjacent interaction; BRD §4.1 puts average cart size at 3.2 items, implying frequent small read/write operations rather than bulk ones |
| Consistency | Strong — PostgreSQL is authoritative, Redis is a synchronously-updated read cache (write-through), not an independent CQRS read side. **Resolved (Decision D5 — see §2 and `edge-cases.md`):** this does map onto the platform's "Strong (PostgreSQL/write path)" default (BRD §3) once Redis is understood as a cache in front of PostgreSQL rather than a second system of record; Cart deliberately does not use the platform's Mongo-eventual-read-side pattern because cart reads must reflect the immediately preceding write (a user must never see a stale cart). | BRD §3 (platform default), §16 (cache stack) |
| Reliability | At-least-once delivery + idempotent consumers (BRD §3 global) | Applies to `CartCheckedOut` publication and `InventoryReservationFailed` consumption |
| Retry/DLQ | `InventoryReservationFailed`: 2x retry, `inventory.dlq` (BRD §10, shared row with Order). `CartCheckedOut`: 2x retry, `cart.dlq` (BRD §10, added by ADR-0007). | Both rows are now fully specified in the BRD's Event Catalog — no gap remains here. |

## 4. Domain Invariants

- A cart's contents are not a reservation — inferred from Cart consuming `InventoryReservationFailed` (BRD §5.4/§10) rather than holding stock itself; only Inventory Service enforces the oversell invariant (BRD §2.2). A cart line item existing does not guarantee the item is purchasable at checkout time.
- Merging a guest cart into a logged-in cart must not silently lose either cart's state — **resolved by Decision D2 (§6):** overlapping SKUs sum quantities, non-overlapping SKUs from both carts are kept (union), subject to the line-item cap in Decision D4.
- An expired cart must eventually be reclaimed (storage cannot grow unbounded) — **resolved by Decision D1 (§6):** sliding TTL (30 days logged-in / 7 days guest) plus a 30-day PostgreSQL soft-expiry recovery window past Redis eviction, after which the row is purged.
- A cart has a bounded maximum size — **resolved by Decision D4 (§6, single-service default, no ADR):** cap at 100 distinct line items per cart. The BRD gives no number (only an average of 3.2 items, BRD §4.1); 100 is a defensive upper bound to keep merge, snapshot, and checkout payloads bounded, chosen generously above observed average usage so it is not user-visible in the overwhelming majority of carts.

## 5. API Surface (from BRD, starting point only)

| Endpoint/Event | Direction | Notes |
|---|---|---|
| `/cart` | Inbound API | BRD §5.4; verb-level semantics unspecified — non-blocking, carried to API Design Agent |
| `POST /cart/merge` | Inbound API | BRD §2.1 item 7, §5.4; conflict rule resolved by Decision D2 (§6) |
| `CartCheckedOut` | Published | Consumer: Analytics only (funnel/conversion), 2x retry, `cart.dlq` — BRD §10, per ADR-0007. Not consumed by Order (Order's trigger is the client's `POST /orders`). Exact emission trigger point in Cart's own flow is non-blocking, carried to API/Event Design Agents. |
| `InventoryReservationFailed` | Consumed | Published by Inventory (BRD §10); Cart is a co-consumer with Order; handling resolved by Decision D3 (§6) |

Final contract is the API Design Agent's job, not this spec's.

## 6. Decisions Log (formerly Open Questions — all resolved)

Every item previously listed under "Open Questions / Flagged Ambiguities" has been resolved below. None remain blocking. Two items (D8, D9) are explicitly non-blocking, carried-forward handoffs to later pipeline stages, not unresolved gaps.

1. **D1 — Cart expiry TTL (was OQ1).** BRD §2.1 item 7 names "expiry" as a responsibility with no duration, absolute-vs-sliding rule, or reclamation mechanism stated. **Single-service engineering default, no ADR (not cross-cutting — affects only Cart's own storage/TTL config):**
   - Chosen: sliding TTL, reset on every read or write touch — 30 days idle for a logged-in user's cart, 7 days idle for a guest (anonymous-session) cart. On Redis eviction, the PostgreSQL snapshot remains recoverable for a further 30 days (soft-expiry grace window) before the row is purged outright.
   - Why: sliding (not absolute) matches the intuitive meaning of "abandoned" — a cart the user is actively touching should never expire mid-use. The 30/7-day split mirrors the platform's general pattern of trusting authenticated identity more than anonymous sessions (the same asymmetry Identity/User apply to token lifetimes). 30 days is long enough to cover a realistic "I'll finish this later" gap without carts growing unbounded; 7 days for guests reflects that an anonymous session has no durable identity to return to, so a shorter reclamation window is safe.
   - Trade-off accepted: a guest who returns after more than 7 days loses their cart outright with no recovery path (guest carts have no PostgreSQL soft-expiry window extension beyond what a logged-in cart gets, since there is no durable user identity to reattach the snapshot to on return). This is judged acceptable because guest-cart abandonment past a week is the common case, not the exception, in e-commerce generally.
   - Mirrors: `edge-cases.md` → "Abandoned-cart expiry races a returning user" (updated from escalated to resolved).

2. **D2 — Guest-cart/logged-in-cart merge conflict rule (was OQ2).** BRD §2.1 item 7 / §5.4 name `/cart/merge` as a responsibility without a conflict rule. **Single-service engineering default, no ADR (affects only Cart's own merge logic — Order and other services never see guest-vs-logged-in cart state):**
   - Chosen: sum quantities for SKUs present in both carts; keep all SKUs present in only one cart (union); cap the merged result at the 100-line-item limit (Decision D4), dropping the lowest-value overflow.
   - Why: sum-on-overlap is the option that loses no signal from either cart — the user added N of a SKU as a guest and M more after logging in (e.g., a second device or a later session), and summing treats both additions as real intent rather than discarding one. Union-on-distinct-SKUs is the only non-lossy choice for items that don't overlap at all. This is the same reasoning the requirement-spec's own domain invariant already demanded ("must not silently lose either cart's state without a defined rule") — sum+union is the interpretation that satisfies it without inventing a preference between the two sessions.
   - Trade-off accepted: a user could see a summed quantity larger than they explicitly intended in either individual session (e.g., they meant to replace a guest-cart quantity, not add to it) — this is judged an acceptable, correctable-at-checkout consequence versus the alternative of silently discarding a guest-cart line item the user never explicitly abandoned.
   - Mirrors: `edge-cases.md` → "Guest-to-user cart merge conflict" (updated from escalated to resolved).

3. **D3 — Cart's handling of `InventoryReservationFailed` (was implicit in FR §2, not previously a numbered Open Question but flagged in prose).** **Single-service default, no ADR:**
   - Chosen: idempotent, pre-checkout-only handling — flag the affected line item as currently unavailable (surfaced to the user on next cart view), no-op if the cart has already checked out.
   - Why: keeps Order as sole owner of post-checkout compensation (BRD §5.1, Saga orchestrator), consistent with the domain invariant that a cart line item is not a reservation.
   - Mirrors: `edge-cases.md` → "Checkout races `InventoryReservationFailed`" (already resolved; verified consistent, no change needed).

4. **D4 — Maximum cart size (new, forced by needing a concrete cap for D2's merge overflow rule).** **Single-service default, no ADR:**
   - Chosen: 100 distinct line items per cart, enforced on both direct `/cart` mutation and post-merge.
   - Why: BRD §4.1 states average cart size is 3.2 items; 100 is a generous multiple chosen to bound worst-case payload/snapshot size (merge requests, Redis values, PostgreSQL snapshot rows) without being reachable by realistic legitimate use, protecting against unbounded cart growth (abuse or a client-side bug looping `/cart` adds) without needing product input on a number the BRD never engages with at all.
   - Trade-off accepted: a legitimate bulk-buyer (rare, per BRD's own average) hitting the cap must complete checkout and start a new cart rather than add further distinct SKUs to the same one.

5. **D5 — Redis-as-primary-store durability (was OQ3).** BRD §5.4/§16 state the stack ("Redis + PostgreSQL snapshot") without stating which store is authoritative or the write path. **Single-service default, no ADR (Cart's internal storage write path is not visible to, or depended on by, any other service's contract):**
   - Chosen: write-through on every cart mutation — PostgreSQL is authoritative, Redis is a synchronously-updated read cache in front of it, not an independent system of record.
   - Why: matches the platform's existing precedent of write-through where staleness/loss is unacceptable (BRD §16 applies write-through to Promotion for the same reason); cart-mutation volume (~3.2 items/cart, BRD §4.1) is far lower than the catalog-read volume that justifies cache-aside elsewhere, so the added write latency is affordable within the P95 < 150ms budget.
   - Trade-off accepted: every cart write pays a synchronous PostgreSQL round-trip instead of returning as soon as Redis acknowledges.
   - Mirrors: `edge-cases.md` → "Cart lost on Redis eviction or restart" (already resolved; verified consistent, no change needed). Also resolves the NFR §3 Consistency row: this now maps cleanly onto the platform's "Strong (PostgreSQL/write path)" default (BRD §3).

6. **D6 — Availability tier for Cart (was OQ5).** BRD §3 scopes 99.99% to "order path" / 99.9% to "secondary" without placing Cart in either explicitly. **Single-service default, no ADR (an availability target is an internal SLO for Cart's own deployment, not a contract another service depends on):**
   - Chosen: 99.9% (secondary tier).
   - Why: the BRD's "order path" tier concretely means the services that execute the Order Saga — Order, Inventory, Payment, Shipping are the only four services shown publishing onto the Message Bus in §5.5's diagram and the only four with steps in §12's Saga flows. Cart, like Product/Search/Identity, is a pre-Saga, customer-facing edge service; a Cart outage prevents starting new checkouts (same failure mode as a Product or Search outage) but cannot corrupt or stall a Saga already in flight, which is the specific risk the 99.99% tier is protecting against.
   - Trade-off accepted: Cart tolerates a larger downtime budget (~526 min/year) than order-path services (~52 min/year). If production telemetry later shows Cart unavailability is a direct, material driver of lost checkouts, this tier should be revisited — that evidence does not exist at spec time, so this is a defensible default, not a final architectural commitment.

7. **D7 — `CartCheckedOut` Event Catalog gap (was OQ4) — resolved directly by the BRD itself, no ADR needed.** The BRD's Event Catalog (§10) already carries a full row for `CartCheckedOut` (publisher Cart, consumer Analytics only for funnel/conversion tracking, payload `cartId, userId, items`, retry 2x, DLQ `cart.dlq`), added by the platform's event-catalog completeness review (**ADR-0007**, reconfirmed by **ADR-0008**'s follow-up pass — see those files for the review process). ADR-0007 additionally states explicitly that Order does not consume `CartCheckedOut`; Order's actual creation trigger is the client's synchronous `POST /orders` call (BRD §5.1), confirmed consistent with `kart-order-service/requirement-spec.md` §5. This spec's earlier text describing `CartCheckedOut` as absent from the Event Catalog was stale relative to the current BRD and has been corrected throughout §2/§3/§5 above.

8. **D8 (non-blocking, carried forward) — Exact HTTP/event wiring for checkout.** ADR-0007 itself flags that the precise integration style (does Cart expose a dedicated `POST /cart/checkout` that emits the event as a direct side effect, or does Cart observe the client's separate `POST /orders` call and emit the event as an out-of-band signal?) should be "double-checked against `kart-cart-service`'s ... eventual architecture-agent output in case a different integration style is chosen there." This is exactly the kind of downstream sizing decision the requirement-spec is not meant to pre-empt — carried to the API Design Agent / Event Design Agent as a normal handoff, not a blocking gap.
9. **D9 (non-blocking, carried forward) — Final HTTP verb-level contract for `/cart`.** BRD §5.4 gives only the resource path. Carried to the API Design Agent as a normal handoff, not a blocking gap.

## Sign-off

- [x] Blocking open questions resolved
- [x] Reviewed by: Automated architecture pipeline -- see docs/adr and this run's decision log
- [x] Approved to proceed to Architecture Agent
