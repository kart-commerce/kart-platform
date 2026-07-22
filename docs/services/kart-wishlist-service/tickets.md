---
doc_type: tickets
service: kart-wishlist-service
status: approved
generated_by: ticket-agent
source: [requirement-spec.md, edge-cases.md, design-decisions.md, architecture.md, ddd-model.md, api-contract.yaml, database-design.md, event-contract.md]
---

# Tickets: kart-wishlist-service

Local draft. Not yet created as real GitHub Issues — that requires the target repo to exist (Project Scaffold Agent) and is a separate, explicit step.

All 9 upstream design artifacts for this service are `status: approved`. This ticket list is decomposed directly from that fully-approved set — three vertical slices map 1:1 to `api-contract.yaml`'s three paths, and five more cover the async/scheduled behaviors `event-contract.md`/`architecture.md`/`edge-cases.md` commit to. No endpoint or consumed event in the design package is left undecomposed.

## Epic: kart-wishlist-service v1

Saved items + price-drop alerts (BRD §2.1 item 13): client-facing add/list/remove, async price-drop evaluation with batched alerting, stale-entry invalidation (event-driven + reconciliation), and GDPR erasure (ADR-0016) — a secondary-availability, read-adjacent bounded context not on the Order Saga's critical path (`architecture.md`, Boundary Rationale).

| ID | Task | Vertical Slice (Application/Features/) | Depends On | Design Source |
|---|---|---|---|---|
| WL-1 | List the caller's own wishlist entries | `ListWishlist` | WL-2 | `api-contract.yaml` `GET /wishlist`; `database-design.md` MongoDB `wishlist_read` collection |
| WL-2 | Add a product SKU to the caller's own wishlist | `AddWishlistEntry` | — | `api-contract.yaml` `POST /wishlist`; `ddd-model.md` `WishlistEntry` aggregate (unique `(userId, sku)`, `ReferencePrice` set at add-time, 500-active-entry cap); `database-design.md` `wishlist_entries` table, `uq_wishlist_entries_user_sku`, `idx_wishlist_entries_user_status` |
| WL-3 | Remove a product SKU from the caller's own wishlist | `RemoveWishlistEntry` | WL-2 | `api-contract.yaml` `DELETE /wishlist/{sku}`; idempotent-DELETE semantics (204 whether or not the entry existed) |
| WL-4 | Evaluate an inbound `ProductPriceChanged` for alert-worthiness | `EvaluatePriceDropAlert` | WL-2 | `event-contract.md` `ProductPriceChanged` consumption; `ddd-model.md` 5%-threshold/24h-cooldown invariants, `AlertCooldownState`; `database-design.md` `wishlist_alert_dedup` table (redelivery-idempotency); `edge-cases.md` "Duplicate Alert Delivery", "Noise Alerts" decisions; queues a qualifying trigger into the Redis accumulator (`design-decisions.md`) for WL-5 to flush |
| WL-5 | Flush the per-user alert digest and publish `WishlistPriceAlertTriggered` | `FlushAlertDigest` | WL-4 | `design-decisions.md` "State-Store Mechanism for the Per-User Alert Batching/Digest Window" (Redis, 15-min rolling/60-min hard cap) and "Resilience Pattern for the Digest-Send-Time Price Re-Check" (fail-safe circuit breaker); `edge-cases.md` "Alert Storm on Sitewide Price Drop", "Price Rebound During the Batching/Digest Window"; `database-design.md` `wishlist_outbox_events` (Transactional Outbox); `event-contract.md` `WishlistPriceAlertTriggered` (2x retry, per-consumer-group DLQ) |
| WL-6 | Mark wishlist entries stale on `ProductDiscontinued` | `MarkEntriesStaleOnProductDiscontinued` | WL-2 | `event-contract.md` `ProductDiscontinued` consumption (3x retry, `wishlist.product-discontinued.dlq`); `ddd-model.md` `WishlistEntryStatus` transition to `Stale`; `database-design.md` `idx_wishlist_entries_sku` |
| WL-7 | Hourly reconciliation job for stale/discontinued products | `ReconcileStaleWishlistEntries` | WL-2, WL-6 | `edge-cases.md` "Stale Wishlist Entry for a Discontinued Product" decision; `architecture.md`'s Sync vs. Async Resolution (hourly cadence, `GET /products/{id}`, not on the request path); `design-decisions.md` "Resilience & Fan-out Pattern for the Stale-Entry Reconciliation Job" (bounded-concurrency bulkhead + circuit breaker); `database-design.md` `idx_wishlist_entries_status_sku`. Defense-in-depth alongside WL-6, not a replacement for it. |
| WL-8 | Erase a user's wishlist data on `UserDataErased` | `EraseUserWishlistDataOnUserDataErased` | WL-2, WL-4, WL-5 | `event-contract.md` `UserDataErased` consumption (5x retry, paged, `wishlist.user-data-erased.dlq`, compliance-critical tier per ADR-0016 item 7); `design-decisions.md` "Erasure Mechanism for `UserDataErased`" (synchronous multi-store hard delete); `edge-cases.md` "Residual Wishlist State After a `UserDataErased` Event"; `database-design.md`'s GDPR Erasure Write Path (PostgreSQL `wishlist_entries`/`wishlist_alert_dedup` deletes + MongoDB document delete + Redis accumulator purge, one handler) |

## Flagged Gaps — Not Decomposed Into Tickets (would invent scope, not decompose it)

- **No cross-service update to `kart-product-service/event-contract.md`'s `ProductDiscontinued` Consumers column.** `event-contract.md`'s own cross-service consistency note already names this as Product's own doc's follow-up, not Wishlist's — no ticket here; if Product's own docs are updated in a future pass, no Wishlist-side ticket changes as a result (WL-6 already implements the consumer side regardless of that table's contents).
- **No PATCH/update-in-place endpoint for a `WishlistEntry`.** `api-contract.yaml`'s own header note states no field is user-editable once added — not invented here.

## Notes for Sprint Planner Agent

- WL-2 (`AddWishlistEntry`) has no dependency and is the foundation every other ticket needs at least one existing row to act on — build it first.
- WL-1 and WL-3 each depend only on WL-2 and are otherwise independent of each other — parallelizable once WL-2 lands.
- WL-4 → WL-5 is a hard sequential chain (digest flush needs the accumulator WL-4 populates); WL-6 is independent of both and can be built in parallel with WL-4/WL-5.
- WL-7 depends on WL-6 only because both mutate the same `status` field and should share the same state-transition code path, not because either blocks the other's own external trigger (event vs. schedule) — safe to parallelize implementation once WL-2 lands, sequencing only the final integration/testing pass.
- WL-8 is the longest chain (WL-2 → WL-4 → WL-5 → WL-8, 4 nodes) because it must clean up state each of those tickets introduces (dedup table, Redis accumulator) — build last among the async tickets, and re-verify it against whatever WL-4/WL-5's actual final schema looks like before considering it done.
- No circular dependencies in this graph.
