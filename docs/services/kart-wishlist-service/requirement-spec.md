---
doc_type: requirement-spec
service: kart-wishlist-service
status: pending-approval
generated_by: requirement-agent
source: docs/requirements/kart-requirements.md
---

# Requirement Spec: kart-wishlist-service

## 1. Scope

Covers the single BRD service **Wishlist** (BRD §2.1 item 13: "Saved items, price-drop alerts"). No merge — unlike `kart-offer-service` ([ADR-0001](../../adr/0001-offer-service-merge.md)), Wishlist maps one-to-one from BRD row to service, so no ADR is needed to justify scope.

The BRD's treatment of this service is minimal: one row in the core-modules table (§2.1), one condensed row in the service-design table (§5.4), and a single Event Catalog entry (§10) for the event it consumes — but not for the event it publishes. Several gaps below follow directly from that thinness; they are named rather than filled in.

## 2. Functional Requirements

### Saved Items
- Maintain a user's saved/wishlisted products (BRD §2.1 item 13, "Saved items").
- Expose wishlist operations via `/wishlist` (BRD §5.4) — the BRD gives only this base path; it does not enumerate HTTP verbs or sub-paths (add item, list items, remove item). See Open Questions.

### Price-Drop Alerts
- Consume `ProductPriceChanged` (BRD §5.4) to detect price movement on wishlisted products.
- Publish `WishlistPriceAlertTriggered` when a price-drop condition is met (BRD §5.4) — the BRD does not define what qualifies as a "drop" (any decrease vs. a minimum threshold) or over what window. See Open Questions.
- `WishlistPriceAlertTriggered` has no entry in the BRD's Event Catalog (§10), unlike every other event named in §5.4's condensed table (`CouponRedeemed`, `PriceQuoteIssued`, `PromotionActivated`, etc., all of which have full Event Catalog rows). This means the BRD states no consumer, retry count, or DLQ strategy for this event. Notification Service (BRD row 15) is described as consuming "almost every event in catalog" (§5.4 preamble), but since this event is absent from §10 entirely, whether Notification actually consumes it is unconfirmed. See Open Questions.

## 3. Non-Functional Requirements

Pulled from the BRD's global NFR table (§3), scoped to this service:

| Attribute | Target | Applies here because |
|---|---|---|
| Availability | 99.9% (secondary path) | Wishlist is not named on the Order Saga's critical path (§5.5); BRD does not call out Wishlist specifically in the 99.99% tier |
| Latency | P95 < 150ms, P99 < 400ms (read path) | `/wishlist` reads (viewing saved items) sit on the browse path, not the checkout write path |
| Consistency | Not fully determinable — BRD lists Wishlist's database as simply "MongoDB" (§5.4), unlike sibling MongoDB-read-side services (Product, User, Review) which the BRD pairs with a PostgreSQL write side per the platform's stated CQRS pattern (§6, §7). See Open Questions. |
| Reliability | At-least-once delivery + idempotent consumers (global NFR) | Applies to `ProductPriceChanged` consumption and `WishlistPriceAlertTriggered` publication |
| Retry/DLQ | `ProductPriceChanged`: 3x retry, `catalog.dlq` (BRD §10, publisher-side) | Governs the inbound event Wishlist consumes; no equivalent policy is stated for the outbound `WishlistPriceAlertTriggered` since it has no Event Catalog row — see Open Questions |

## 4. Domain Invariants

- A `WishlistPriceAlertTriggered` must reflect the actual current price of the wishlisted product at trigger time, not a stale cached price — inferred from the service's stated role of reacting to `ProductPriceChanged`, analogous to Pricing's `PriceQuoteIssued` invariant in `kart-offer-service`.
- Alert publication must be idempotent under RabbitMQ's at-least-once delivery (BRD NFR §3, Reliability row) — the BRD does not state whether a redelivered `ProductPriceChanged` for a price already alerted on should be suppressed; see Open Questions.
- A wishlist entry belongs to exactly one user (implied by "saved items" being an inherently per-user concept) — the BRD does not state this explicitly for Wishlist, so it is inferred rather than quoted.

## 5. API Surface (from BRD, starting point only)

| Endpoint/Event | Direction | Notes |
|---|---|---|
| `/wishlist` | Inbound API | BRD §5.4 — verb/sub-path granularity (add/list/remove) not specified |
| `WishlistPriceAlertTriggered` | Published | Not present in BRD Event Catalog (§10); consumer(s), retry, and DLQ policy unconfirmed — see Open Questions |
| `ProductPriceChanged` | Consumed | BRD §5.4's service table attributes this to Product; BRD §10's Event Catalog attributes it to Pricing. Same contradiction already surfaced and resolved in `kart-offer-service`'s requirement spec (Product publishes, Pricing only consumes) — this spec adopts that resolution rather than re-opening it. |

Final contract is the API Design Agent's job, not this spec's.

## 6. Open Questions / Flagged Ambiguities

**Resolved (by reference — already settled in `kart-offer-service`, an approved spec):**

1. **`ProductPriceChanged` publisher contradiction.** Product publishes it; Pricing (and, here, Wishlist) are consumers only. See `kart-offer-service/requirement-spec.md` §6 Q1 for the original resolution. Not re-opened here.

**Open (blocking — human decision needed before sign-off):**

2. **Price-drop threshold undefined.** The BRD states Wishlist triggers alerts on price drops but gives no minimum delta (absolute or percentage) or debounce window. Without one, any decrease — including a $0.01 rounding change — could trigger `WishlistPriceAlertTriggered`.
3. **Alert dedup/debounce across repeated small price drops.** If the same product receives several small successive `ProductPriceChanged` events (e.g., during a promotion ramp), the BRD does not say whether each qualifying drop re-triggers an alert or whether there's a cooldown per user/product pair.
4. **`WishlistPriceAlertTriggered` missing from the Event Catalog (§10).** No consumer, retry count, or DLQ strategy is stated, unlike every other published event in the platform. In particular, it's unconfirmed whether Notification Service (row 15) consumes it for the email/SMS/push fan-out that a "price-drop alert" implies a user would expect.

**Carried forward (non-blocking — resolved by a later pipeline stage, not here):**

5. **Write-side datastore ambiguity.** BRD §5.4 lists Wishlist's database as just "MongoDB," unlike Product/User/Review which the BRD pairs with a PostgreSQL write side under the platform's stated CQRS convention (§6, §7). Carried to the **Architecture Agent** to decide whether Wishlist is a deliberate exception (Mongo as both write and read store) or whether a PostgreSQL write side was simply omitted from the condensed table.
6. **`/wishlist` verb/sub-path granularity** — carried to the **API Design Agent** to define add/list/remove semantics.
7. **Wishlist size limits** (max saved items per user) — not stated by the BRD; carried to the **DDD Agent** as a potential aggregate invariant.
8. **No product-removal/discontinuation event feed.** The BRD states Wishlist consumes only `ProductPriceChanged`; it names no event for product deletion or discontinuation. Handling of stale wishlist entries pointing at a no-longer-available product is unspecified. Carried to the **Architecture/DDD Agent** stages.

## Sign-off

- [ ] Blocking open questions resolved (Q2–Q4)
- [ ] Reviewed by:
- [ ] Approved to proceed to Architecture Agent
