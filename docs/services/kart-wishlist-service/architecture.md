---
doc_type: architecture
service: kart-wishlist-service
status: approved
generated_by: architecture-agent
source: docs/services/kart-wishlist-service/requirement-spec.md, docs/services/kart-wishlist-service/edge-cases.md, docs/adr/0016-user-gdpr-erasure-policy.md, docs/services/kart-product-service/event-contract.md
---

# Architecture: kart-wishlist-service

## Boundary Rationale

`kart-wishlist-service` is the bounded context that answers "which products has this user chosen to track, and should they be told a tracked price moved" — it owns saved/wishlisted items and the price-drop-alert evaluation that reacts to them (requirement-spec §1, §2). It maps one-to-one onto a single BRD row (BRD §2.1 item 13); no merge ADR is required the way one was for Offer (ADR-0001).

Wishlist is a **secondary-availability, read-adjacent** service, not a participant in the Order Saga (BRD §12) and not named in the BRD's 99.99% order-path tier (requirement-spec §3). Its read path (`/wishlist`) sits on the browse experience, and its write/reactive path (evaluating `ProductPriceChanged`) is a background, event-driven concern with no synchronous caller waiting on it. This shapes its dependency posture below: everything on Wishlist's *critical* path (client reads/writes, alert evaluation) is either local or async; the one synchronous outbound call it makes is a background reconciliation job, deliberately kept off the user-facing request path.

Wishlist never owns product catalog truth (name, price, availability) or notification-delivery mechanics — it holds only a per-`(userId, sku)` wishlist entry and the alerting state (reference price, cooldown window, dedup record) needed to decide *whether* to raise `WishlistPriceAlertTriggered`, and defers to Product for catalog facts and to Notification for actually reaching the user.

## Dependencies

| Direction | Peer Service | Mechanism | Type | Notes |
|---|---|---|---|---|
| Inbound (client) | Client/Mobile/Web via API Gateway | `/wishlist` (add/list/remove) | **Sync** (REST) | BRD §5.4 names only the base path (requirement-spec §5); verb/sub-path granularity is carried to the API Design Agent (requirement-spec §6 item 5) — not a boundary/dependency question, so not resolved here |
| Inbound (consumed) | Product Service | `ProductPriceChanged` | **Async** | Publisher resolved to Product (BRD §5.4 vs §10 contradiction; requirement-spec §5 adopts the resolution already recorded in `kart-offer-service/requirement-spec.md` §6 Q1 — Product publishes, Pricing/Offer and Wishlist are consumers only). 3x retry, `catalog.dlq` (BRD §10) |
| Outbound (published) | Notification, Analytics | `WishlistPriceAlertTriggered` | **Async** | Consumers and retry tier confirmed by [ADR-0007](../../adr/0007-event-catalog-completeness.md): payload `userId, sku, oldPrice, newPrice`; 2x retry; DLQ `wishlist.dlq`. Notification's consumption is independently confirmed by name in BRD §5.4's own Notification row (requirement-spec §2, §5) |
| Outbound (new, sync, background job only) | Product Service | `GET /products/{id}` | **Sync** (REST) | **New dependency resolved by this pass**, per `edge-cases.md`'s "Stale Wishlist Entry for a Discontinued Product" decision. Used only by the periodic reconciliation job (see Sync vs. Async Resolution below) — never called synchronously from the client-facing `/wishlist` read path, so it does not sit inside the P95 < 150ms / P99 < 400ms read-path budget (requirement-spec §3) |
| Inbound (consumed, new) | Product Service | `ProductDiscontinued` | **Async** | `ProductDiscontinued` is now formally approved (`kart-product-service/ddd-model.md`/`event-contract.md`, payload `sku`, `discontinuedAt`, 3x retry). Second, event-driven invalidation path alongside the reconciliation job above (requirement-spec §2, §4, §6 item 7) — resolves what the prior draft could only carry as an interim default pending Product's own approval. Consumer-side DLQ `wishlist.product-discontinued.dlq` (see `event-contract.md`) |
| Inbound (consumed, new) | User Service | `UserDataErased` | **Async** | **ADR-0016** (User Data Erasure Policy) already names Wishlist directly as an expected consumer — closes the gap `design-decisions.md`'s "Escalations" section flagged (no FR/invariant existed yet to design against). Payload `userId`, `erasedAt`; 5x retry, exponential backoff, on-call paging on DLQ exhaustion (compliance-critical tier, ADR-0016 item 7); consumer-side DLQ `wishlist.user-data-erased.dlq`. Triggers hard deletion of the user's wishlist entries, alert-cooldown/reference-price state, and dedup-table rows (requirement-spec §2, §4; `edge-cases.md`'s "Residual Wishlist State After a `UserDataErased` Event" decision) |

No other service's requirement-spec or architecture doc names a dependency on Wishlist beyond the two already recorded above (Notification, Analytics consuming `WishlistPriceAlertTriggered`) — confirmed against both services' existing `architecture.md` entries in `docs/architecture/service-boundaries.md`. The two new inbound edges above widen Wishlist's own async fan-in from one publisher (Product, via `ProductPriceChanged`) to two publishers (Product, User Service) across three events — this does not change the risk assessment below since both remain async and neither sits on the `/wishlist` request path.

## Sync vs. Async Resolution

Two integration-contract questions were explicitly carried to this stage; both are resolved here.

**1. Stale/discontinued wishlist entries (requirement-spec §6 item 7; `edge-cases.md`'s "Stale Wishlist Entry" decision).** The edge-case decision already chose a periodic reconciliation job over a synchronous per-read check or a dependency on the not-yet-approved `ProductDiscontinued` event; this pass resolves the two things that decision explicitly left to the Architecture Agent:

- **Mechanism:** synchronous REST call (`GET /products/{id}`), not an event subscription — no BRD-stated event exists yet for product removal/discontinuation, so a request/response check against Product's own API surface (BRD §5.4) is the only mechanism available today. If/when `ProductDiscontinued` is approved, it becomes a second, faster invalidation path *alongside* this job (edge-cases.md's own forward path), not a replacement resolved here.
- **Cadence:** **hourly**, run as a scheduled batch job over every SKU currently held by any wishlist entry, paginated so a single run never issues an unbounded burst of calls to Product Service. Hourly bounds the staleness window (edge-cases.md accepts this is a UX rough edge, not a correctness/money-moving concern) to something tighter than a daily cadence while still keeping call volume low relative to Product's read-heavy traffic profile (BRD §4.4's 20:1 read:write ratio) — a plain, revisitable config value, not a hardcoded architectural constraint.
- **Isolation from the request path:** this job's calls to Product Service are never in the critical path of `/wishlist` reads or of `ProductPriceChanged` alert evaluation — both of those continue to use only Wishlist's own local data. This is what keeps the new synchronous edge from becoming a distributed-monolith risk (see below).

**2. Write-side datastore ambiguity (requirement-spec §6 item 4).** BRD §5.4's condensed service table lists Wishlist's database as simply "MongoDB," with no paired PostgreSQL write side shown — unlike User/Product/Review, which the same table pairs explicitly ("PostgreSQL → MongoDB read"). The requirement-spec correctly declined to resolve this itself, noting (unlike Category's ADR-0011) there is no *explicit* §5.4-vs-§6.1 contradiction for Wishlist, just an omission — §6.1's own Read-Heavy vs. Write-Heavy table doesn't mention Wishlist in either direction, so it gives no signal either way. **Resolved here as: Wishlist follows the platform's default CQRS split (PostgreSQL write side, MongoDB read side), not a deliberate Mongo-only exception.** Reasons:

- The platform-wide default stated in BRD §6/§7 ("every service is write-optimized in PostgreSQL, read-optimized in MongoDB," BRD line ~36) and restated as an unconditional rule in the reusable DDD/CQRS standard ("Write model is always PostgreSQL and is the source of truth") is the baseline every service gets unless something explicitly overrides it for that service — and nothing here does.
- The requirement-spec and `edge-cases.md` already commit Wishlist to mechanisms that assume a relational, transactional write store: the Outbox pattern for publishing `WishlistPriceAlertTriggered` (edge-cases.md's "Duplicate Alert Delivery" decision — "matches the platform's existing Outbox-Poller-RabbitMQ pipeline"), and a dedup table keyed on `(userId, sku, priceObserved)` that must commit atomically with the outbox row in the same transaction as the alert-worthy state change. Both are the platform's standard PostgreSQL-side pattern elsewhere (`kart-offer-service`, `kart-review-service`); nothing in Wishlist's domain makes it a special case that needs a different mechanism.
- No cross-cutting impact exists that would warrant escalating this to an ADR the way Category's explicit table contradiction did (ADR-0011) — this is a single-service documentation gap in a condensed BRD table, exactly the class of decision this agent's Failure Conditions section reserves for direct resolution rather than escalation, since it doesn't conflict with any other service's already-recorded boundary.
- **Concrete shape:** PostgreSQL holds the wishlist-entry write model (`userId`, `sku`, reference price, added-at timestamp), the per-`(userId, sku)` alert-cooldown/reference-price state (requirement-spec §4), and the `(userId, sku, priceObserved)` dedup table, all written in the same transaction as the Outbox row. MongoDB holds the denormalized read model behind `/wishlist` reads (BRD §5.4's stated database), projected from the same Outbox → RabbitMQ pipeline as every other service on this platform (BRD §7).

## Distributed-Monolith Risk

**None identified on the request/critical path.** Wishlist's only synchronous outbound dependency (`GET /products/{id}`) is scoped entirely to the hourly reconciliation job, never to `/wishlist` reads or to `ProductPriceChanged` alert evaluation — both of the latter are served from Wishlist's own local write/read model. This means Wishlist's live read-path availability and latency budget (P95 < 150ms / P99 < 400ms) do not depend on Product Service's uptime at request time, unlike `kart-recommendation-service`'s two new synchronous request-time calls to Inventory/Product (see that service's `architecture.md` for the contrasting, higher-risk pattern this deliberately avoids).

One risk still worth naming for the eventual implementation, scoped to the background job only: if Product Service is slow or unavailable during a scheduled reconciliation run, that run must skip/retry on the next hourly cycle rather than blocking, crashing, or retrying in a tight loop against a degraded dependency — a soft failure of one reconciliation pass only widens the staleness window by one cycle, it does not affect any user-facing request.

No fan-out risk is introduced downstream either: `WishlistPriceAlertTriggered`'s two consumers (Notification, Analytics, per ADR-0007) are both async, and the Alert Storm mitigation (per-user 15-minute rolling batch/digest window, 60-minute hard cap — `edge-cases.md`) is a publish-cadence choice internal to Wishlist, not a new dependency edge; it shapes *when* Wishlist publishes, not *what* it depends on.

**The two new inbound edges (`ProductDiscontinued`, `UserDataErased`) add no new risk either.** Both are async, both are one-way (Wishlist never calls back synchronously to Product or User Service to consume them), and a slow/down publisher only widens Wishlist's own staleness window for that one signal — a delayed `ProductDiscontinued` leaves the existing hourly reconciliation job as the sole invalidation path (no worse than before this pass), and a delayed `UserDataErased` is covered by that event's own compliance-critical retry/paging tier (ADR-0016 item 7) rather than anything Wishlist's architecture needs to compensate for structurally.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner
- [x] Approved to proceed to DDD Agent
