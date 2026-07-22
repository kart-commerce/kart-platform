---
doc_type: event-contract
service: kart-wishlist-service
status: approved
generated_by: event-design-agent
source: docs/services/kart-wishlist-service/requirement-spec.md, docs/services/kart-wishlist-service/edge-cases.md, docs/services/kart-wishlist-service/design-decisions.md, docs/services/kart-wishlist-service/architecture.md, docs/services/kart-wishlist-service/ddd-model.md, docs/services/kart-wishlist-service/database-design.md, docs/adr/0007-event-catalog-completeness.md, docs/adr/0016-user-gdpr-erasure-policy.md, docs/services/kart-product-service/event-contract.md, docs/services/kart-identity-service/event-contract.md, docs/services/kart-category-service/event-contract.md
---

# Event Contract: kart-wishlist-service

Exchange: `ecommerce.events` (RabbitMQ topic exchange, per [kart-conventions.md](../../standards/kart-conventions.md)). Routing key convention: `service.entity.action`. Every consumer queue gets its own DLQ per the reusable event standard (`event-standards.md`) — never shared.

## Published Events

| Event | Routing Key | Consumers | Payload (key fields) | Retry | DLQ (per consumer group) | Criticality Justification |
|---|---|---|---|---|---|---|
| `WishlistPriceAlertTriggered` | `wishlist.price-alert.triggered` | Notification, Analytics | `userId`, `sku`, `oldPrice`, `newPrice` | 2x | `notification.wishlist-price-alert-triggered.dlq`, `analytics.wishlist-price-alert-triggered.dlq` | Standard business-event tier — see below |

### Bulkhead — Per-Consumer-Group DLQs, Not One Shared `wishlist.dlq`

BRD §10/**ADR-0007**'s `wishlist.dlq` label (requirement-spec §3's Retry/DLQ row) is the **retry-tier name**, not a literal single physical queue — the same reconciliation `kart-category-service/event-contract.md` (`catalog.dlq` → per-consumer-group) and `kart-product-service/event-contract.md` (same correction, at larger scale) already made for their own BRD-simplified shared DLQ labels. `WishlistPriceAlertTriggered` has two independent consumers (Notification, Analytics per ADR-0007); each gets its own queue and DLQ so a slow/backed-up Notification consumer (e.g. during the Alert Storm scenario `edge-cases.md` already sizes for) can never block or delay Analytics' own independent ingestion of the same event, or vice versa. The retry **count** (2x) is unchanged from BRD §10/ADR-0007 — only the shared queue label is corrected.

## Consumed Events

| Event | Routing Key | Publisher | Payload (key fields) | Retry (this service's own consumer queue) | DLQ (this service's own consumer queue) | Notes |
|---|---|---|---|---|---|---|
| `ProductPriceChanged` | `product.price.changed` | `kart-product-service` | `sku`, `oldPrice`, `newPrice`, `occurredAt` | 3x | `wishlist.product-price-changed.dlq` | Drives the 5%-threshold/24h-cooldown alert evaluation (requirement-spec §2, §4). Retry count matches Product's own publish-side tier (`kart-product-service/event-contract.md`). Publisher resolved to Product, not Pricing, per the BRD §5.4-vs-§10 contradiction already settled in `kart-offer-service/requirement-spec.md` §6 Q1 — not re-opened here. |
| `ProductDiscontinued` | `product.product.discontinued` | `kart-product-service` | `sku`, `discontinuedAt` | 3x | `wishlist.product-discontinued.dlq` | Second, event-driven invalidation path alongside the hourly reconciliation job (requirement-spec §2, §4, §6 item 7; `edge-cases.md`'s "Stale Wishlist Entry" decision). Retry count matches Product's own publish-side tier (`kart-product-service/event-contract.md`) — standard catalog criticality, not compliance-critical, since the reconciliation job is an independent backstop for whatever this event misses. |
| `UserDataErased` | `user.data-erased` | `kart-user-service` | `userId`, `erasedAt` | 5x, exponential backoff, on-call paging on final DLQ landing | `wishlist.user-data-erased.dlq` | **Compliance-critical tier**, per ADR-0016 item 7. `kart-user-service/event-contract.md` (approved) already lists Wishlist by name among this event's seven confirmed consumers, with this exact routing key, retry count, and DLQ name — no asymmetry to flag here, unlike `ProductDiscontinued` above. |

**Cross-service consistency note on `ProductDiscontinued`:** `kart-product-service/event-contract.md`'s own Consumers column currently lists only "Search, Analytics" for this event, not Wishlist — a known, non-blocking asymmetry, not a contradiction this document can resolve unilaterally (Product's own doc is the publish-side source of truth for that column and DLQ list). Contrast with `UserDataErased` above, where `kart-user-service/event-contract.md` already lists Wishlist by name — so this asymmetry is specific to `ProductDiscontinued`, not a pattern across every consumed event here. This mirrors the exact situation `kart-analytics-service/event-contract.md` already documents for several sibling services' pending-approval contracts: Wishlist's own consumer-side retry/DLQ tier above is this service's own to define regardless of whether Product's table lists it yet, the same way Search's own consumption of this event was finalized on Search's side independent of Product's table catching up. **Recommended follow-up (out of this service's scope):** `kart-product-service/event-contract.md`'s `ProductDiscontinued` row should be updated in a future documentation pass to add Wishlist to its Consumers column and `wishlist.product-discontinued.dlq` to its DLQ list — not applied here, the same "decide the integration pattern, don't edit the sibling service's docs directly" boundary ADR-0016/ADR-0017 already observed for their own cross-service consequences.

## Naming-Convention Compliance

`WishlistPriceAlertTriggered` = Entity `WishlistPriceAlert` + past-tense verb `Triggered` — compliant with the `<Entity><PastTenseVerb>` convention (`event-standards.md`); this is the BRD-fixed name (§5.4/§10), not renamed here. Routing key follows `service.entity.action` (`kart-conventions.md`): `wishlist.price-alert.triggered` (kebab-case multi-word entity, matching the precedent already set by `identity.user-account.updated` in `kart-identity-service/event-contract.md`). No collision found against any event name already registered in this repo's other `event-contract.md` files (`kart-offer-service`, `kart-admin-service`, `kart-cart-service`, `kart-category-service`, `kart-product-service`, `kart-identity-service`, `kart-analytics-service`, `kart-delivery-tracking-service`).

## Retry-Tier Justification

**`WishlistPriceAlertTriggered` — 2x retry, no on-call paging, per-consumer-group DLQ.** Restated against this service's own actual failure-mode risk, not copied forward from BRD §10/ADR-0007 unexamined:

- Not the `Payment*`/`UserDataErased` compliance-critical tier: a lost/DLQ'd delivery costs a user one missed or delayed price-drop notification — a UX/engagement miss, never a financial, compliance, or oversell risk. Wishlist's own PostgreSQL write side (`wishlist_entries`, `wishlist_alert_dedup`) remains the durable, correct record of what qualified and what already alerted regardless of whether the downstream publish is ever delivered.
- Not the fire-and-forget audit tier (1x) either: unlike `AdminActionPerformed`'s own durable local audit table, a `WishlistPriceAlertTriggered` that never reaches Notification means the *only* channel through which the user would have been told about a real, qualifying price drop is silently lost — 2x (BRD's own originally-assigned count, restated as still appropriate) gives a thin-but-real budget against a transient broker blip without over-engineering a tier the underlying risk doesn't call for.
- **Consumer assignment (Notification, Analytics) is correct, not incomplete** — both are independently confirmed: Notification by BRD §5.4's own row naming this event by name (requirement-spec §2, §5), Analytics under its standing full-fan-in default (ADR-0004). No third consumer is named or safely inferable anywhere in this service's own docs or any sibling service's.

**Consumed events, restated against this service's own risk, not the publisher's tier alone:**

- **`ProductPriceChanged` (3x, standard catalog tier):** a lost delivery to Wishlist means one qualifying price drop for one `(userId, sku)` pair is missed — a UX miss (the same class of risk `kart-product-service/event-contract.md`'s own retry-tier justification already assigns this event), never a correctness gap Wishlist's own write side can't recover from on the *next* qualifying `ProductPriceChanged` for that pair.
- **`ProductDiscontinued` (3x, standard catalog tier):** a lost delivery leaves the affected `WishlistEntry` un-marked `stale` until the next hourly reconciliation cycle — bounded, non-blocking staleness (`edge-cases.md`'s own accepted trade-off for the reconciliation job), not a reason to escalate this consumer-side tier above what Product's own publish-side tier already justifies.
- **`UserDataErased` (5x, paged, compliance-critical tier):** justified above — the one event in this contract where a lost/DLQ'd delivery is a compliance failure (leaving an erased user's PII resident in Wishlist's stores indefinitely), not a tolerable staleness window, matching the identical reasoning `kart-identity-service/event-contract.md` already applied to its own consumption of this same event.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner
- [x] Approved
