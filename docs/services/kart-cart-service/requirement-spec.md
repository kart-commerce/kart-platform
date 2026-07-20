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

- Maintain cart contents (add/update/remove line items) via `/cart` (BRD §5.4). The BRD's condensed service table gives only the resource path, not per-verb semantics (GET/POST/PUT/DELETE) — final HTTP contract is the API Design Agent's job.
- Merge a guest (anonymous-session) cart into a logged-in user's cart via `/cart/merge` (BRD §2.1 item 7, §5.4). The BRD does not specify the conflict-resolution rule when both carts hold state for the same item — see Open Questions.
- Expire abandoned carts (BRD §2.1 item 7: "expiry"). No TTL value, expiry trigger (absolute vs. sliding), or reclamation mechanism is stated — see Open Questions.
- Publish `CartCheckedOut` when a cart moves to checkout (BRD §5.4). Not present in the BRD's Event Catalog (§10) — no payload, retry policy, or named consumer is given there, unlike every other cross-service event in that table.
- Consume `InventoryReservationFailed` (BRD §5.4, confirmed as a Cart-bound event in the Event Catalog §10 row: publisher Inventory, consumers "Order, Cart") — Cart is a secondary consumer alongside Order, presumably to reflect a failed reservation back into the cart's state, but the BRD does not state what Cart is expected to do with it (restore the cart? flag the item? nothing user-visible?).
- Store cart state in Redis with a PostgreSQL snapshot (BRD §5.4: "Redis + PostgreSQL snapshot"; BRD §16 Caching: "Distributed Cache | Session tokens, cart snapshots | Redis Cluster, consistent hashing across nodes"). The BRD does not state which store is authoritative for an in-flight cart, or the write path between them — see Open Questions.

## 3. Non-Functional Requirements

Pulled from the BRD's global NFR table (§3), scoped to this service:

| Attribute | Target | Applies here because |
|---|---|---|
| Availability | 99.9% (secondary path) — BRD §5.5's service boundary diagram does not show Cart publishing onto the Message Bus the way Order/Inventory/Payment/Shipping do, suggesting Cart is not treated as part of the 99.99% "order path" tier | BRD does not call out Cart specifically in either availability tier; inferred from the diagram, not stated directly — see Open Questions |
| Latency | P95 < 150ms, P99 < 400ms (read path) | `/cart` is read/written on effectively every product-detail and checkout-adjacent interaction; BRD §4.1 puts average cart size at 3.2 items, implying frequent small read/write operations rather than bulk ones |
| Consistency | Not stated for Cart specifically. BRD §3 gives "Strong (PostgreSQL/write path), Eventual (MongoDB/read path)" as the platform default, but Cart's stack is Redis + PostgreSQL, which the default CQRS split doesn't map onto cleanly | See Open Questions — Redis-as-primary durability |
| Reliability | At-least-once delivery + idempotent consumers (BRD §3 global) | Applies to `CartCheckedOut` publication and `InventoryReservationFailed` consumption |
| Retry/DLQ | `InventoryReservationFailed`: 2x retry, `inventory.dlq` (BRD §10, shared row with Order) | `CartCheckedOut` has no retry/DLQ entry in the BRD's Event Catalog at all — see Open Questions |

## 4. Domain Invariants

- A cart's contents are not a reservation — inferred from Cart consuming `InventoryReservationFailed` (BRD §5.4/§10) rather than holding stock itself; only Inventory Service enforces the oversell invariant (BRD §2.2). A cart line item existing does not guarantee the item is purchasable at checkout time.
- Merging a guest cart into a logged-in cart must not silently lose either cart's state without a defined rule — the BRD states merge as a responsibility (§2.1 item 7) but does not state the conflict rule itself; the invariant that *some* deterministic, non-lossy-by-default rule must exist is inferable, but which rule is not (see Open Questions).
- An expired cart must eventually be reclaimed (storage cannot grow unbounded) — inferred from "expiry" being named as a first-class responsibility (BRD §2.1 item 7), though the BRD gives no TTL or reclamation trigger.

## 5. API Surface (from BRD, starting point only)

| Endpoint/Event | Direction | Notes |
|---|---|---|
| `/cart` | Inbound API | BRD §5.4; verb-level semantics unspecified |
| `POST /cart/merge` | Inbound API | BRD §2.1 item 7, §5.4 |
| `CartCheckedOut` | Published | No consumer named in BRD §10 Event Catalog — see Open Questions |
| `InventoryReservationFailed` | Consumed | Published by Inventory (BRD §10); Cart is a co-consumer with Order |

Final contract is the API Design Agent's job, not this spec's.

## 6. Open Questions / Flagged Ambiguities

1. **Cart expiry TTL is unspecified.** BRD §2.1 item 7 names "expiry" as a responsibility but gives no duration, no absolute-vs-sliding rule, and no reclamation mechanism. Carried to a human product decision before the Architecture Agent can size Redis TTL/eviction policy.
2. **Guest-cart vs. logged-in-cart merge conflict rule is unspecified.** BRD §2.1 item 7 / §5.4 name `/cart/merge` as a responsibility but do not state what happens when both carts contain the same item at different quantities (sum? take-max? logged-in-wins?) or when they contain different items entirely (union assumed, but not stated). This is a business rule, not an engineering default — do not guess.
3. **Redis-as-primary-store durability guarantee is unstated.** BRD §5.4 lists "Redis + PostgreSQL snapshot" and §16 lists cart snapshots under "Distributed Cache... Redis Cluster," but neither states which store is authoritative for an in-flight cart, the write path (write-through vs. write-behind/async snapshot), or what happens to cart state on Redis eviction or node restart before the next PostgreSQL snapshot. Carried to the Architecture Agent.
4. **`CartCheckedOut` is missing from the BRD's Event Catalog (§10).** Every other cross-service event in that table has a stated publisher, consumer(s), payload, retry count, and DLQ strategy; `CartCheckedOut` has none of these. Additionally, Order Service's own stated consumes-list (BRD §5.1: `InventoryReserved`, `InventoryReservationFailed`, `PaymentCompleted`, `PaymentFailed`, `ShipmentDispatched`) does not include `CartCheckedOut` — it's unclear whether Order actually consumes this event to initiate order creation, whether checkout is instead a synchronous API call from Cart (or client) to Order, or whether `CartCheckedOut` is audit-only. Carried to the Event Design Agent.
5. **Availability tier for Cart is inferred, not stated.** BRD §3's 99.99% tier is scoped to "order path" and 99.9% to "secondary"; the BRD never places Cart in either tier explicitly. This spec inferred "secondary" from the §5.5 diagram (Cart is shown reachable from the API Gateway but not shown publishing onto the Message Bus like Order/Inventory/Payment/Shipping), but a cart failure immediately blocks checkout, which is an argument for treating it as order-path-adjacent. Flagged for confirmation rather than assumed.

## Sign-off

- [ ] Blocking open questions resolved
- [ ] Reviewed by:
- [ ] Approved to proceed to Architecture Agent
