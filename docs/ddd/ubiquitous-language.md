---
doc_type: ddd-memory
status: living-document
---

# Ubiquitous Language Glossary

Every term is owned by exactly **one** bounded context. Other contexts reference the concept through an Anti-Corruption Layer, never by redefining it. Check this file before introducing a new term; append, don't silently overwrite. Built up one service at a time as each passes through the DDD Agent.

## Owned by `kart-offer-service`

| Term | Definition | Kind |
|---|---|---|
| Coupon | A code-gated discount instrument with issuance, redemption, and limit rules | Aggregate root |
| CouponCode | The unique redeemable string identifying a Coupon | Value object |
| RedemptionLimit | The combination of per-user cap, global cap, and validity window that bounds how a Coupon may be redeemed | Value object |
| PricingQuote | An immutable, point-in-time computed price for a cart/checkout context, including tax and applied promotions | Aggregate root |
| PromotionCampaign | A time-boxed campaign (flash sale, bundle deal, or general promotion) that affects price computation | Aggregate root |
| DiscountRule | The computation a PromotionCampaign applies to affected items/SKUs | Value object |
| CampaignWindow | The start/end validity period of a PromotionCampaign | Value object |

## Referenced (owned elsewhere — accessed via ACL, not redefined here)

| Term | Owning Context | How `kart-offer-service` uses it |
|---|---|---|
| Order | kart-order-service | Consumes `OrderCancelled` to void a Coupon redemption; never models Order's own lifecycle |
| SKU / Product Price | kart-product-service | Consumes `ProductPriceChanged` to recompute PricingQuote; never owns catalog price |

## Owned by `kart-delivery-tracking-service`

| Term | Definition | Kind |
|---|---|---|
| TrackingRecord | The current, exposed delivery state (status, ETA, last-updated time) for one `trackingId`; a read-side projection with no PostgreSQL write-side counterpart, created only by consuming `ShipmentDispatched` | Aggregate root |
| TrackingId | The opaque tracking identifier first seen in `ShipmentDispatched`'s payload; this service never generates one itself | Value object |
| CanonicalDeliveryStatus | The single internal delivery-status enum every exposed/published status must belong to, mapped per-carrier from raw carrier codes; never a raw carrier-native string, never `PENDING`/`Unknown` | Value object |
| LifecycleOrdinal | The monotonic ordering position of a `CanonicalDeliveryStatus` value, used to reject regressive status updates | Value object |
| Eta | The current estimated-delivery-time, either passed through from the carrier or computed from a static per-carrier SLA fallback table; recomputed on every accepted status update | Value object |
| TrackingStatusHistory | The append-only audit stream of every distinct received status (mapped or unmapped) for one `trackingId`, independent of `TrackingRecord`'s current-state document | Aggregate root |
| StatusHistoryEntry | One append-only, immutable record within a `TrackingStatusHistory` stream | Entity |
| WebhookDedupEntry | The idempotency ledger entry recognizing a duplicate carrier webhook delivery by carrier-supplied key or computed content hash | Aggregate root |
| CarrierStatusIngested | Internal-only domain event: the normalized, HMAC-verified representation of an inbound carrier webhook, durably enqueued before dedup/ordinal/mapping is applied | Domain event |
| UnmappedCarrierStatusFlagged | Internal/ops-only domain event: raised when a carrier's status code fails to resolve to a `CanonicalDeliveryStatus`, driving the operational triage queue | Domain event |

## Referenced (owned elsewhere — accessed via ACL, not redefined here)

| Term | Owning Context | How `kart-delivery-tracking-service` uses it |
|---|---|---|
| Order | kart-order-service | `TrackingRecord.orderId` is a reference field only, populated from `ShipmentDispatched`'s payload; never models Order's own state machine |
| Shipment / `ShipmentDispatched` | kart-shipping-service | Consumed only as the `TrackingRecord` creation trigger; never models Shipping's own aggregate |

## Owned by `kart-analytics-service`

| Term | Definition | Kind |
|---|---|---|
| IngestedEvent | The durable, idempotently-upserted (by `EventId`) landing record for one instance of any platform event, consumed under the full fan-in default ([ADR-0004](../adr/0004-analytics-full-fanin-ingestion.md)); the single source of truth every dashboard/funnel read model is recomputed from | Aggregate root |
| EventId | The publisher-assigned event identifier; the de-dup/idempotency key for `IngestedEvent` | Value object |
| SchemaVersionPointer | `{ schemaId, versionLabel }` — the Confluent schema-registry-assigned id (wire-format version pointer) plus its human-readable `MAJOR.MINOR` subject-metadata label (requirement-spec.md §6 D2) | Value object |
| EventEnvelope | The publisher-supplied metadata common to every consumed event regardless of type: `eventType`, `publisherService`, `partitionKey`, `occurredAt` | Value object |
| DeadLetteredEvent | The parked record of a consumed event that exhausted its 3x exponential-backoff retry budget while Analytics attempted to persist it (requirement-spec.md §6 D5); references its originating `EventId` by value, never by transactional foreign key | Aggregate root |
| ReconciliationRun | The audit record of one nightly batch reconciliation pass (at most one per `RunDate`), whose completion is what flips read-model documents from provisional to final | Aggregate root |
| PiiRedactionRecord | The immutable, compliance-facing audit record of one `UserDataErased`-triggered redaction sweep across `IngestedEvent` ([ADR-0016](../adr/0016-user-gdpr-erasure-policy.md) item 6) | Aggregate root |
| EventIngested | Internal-only domain event: raised once a consumed event is durably upserted into `IngestedEvent`; drives the near-real-time incremental read-model projector | Domain event |
| EventDeadLettered | Internal-only domain event: raised when a `DeadLetteredEvent` is created (DLQ hand-off) | Domain event |
| EventReprocessed | Internal-only domain event: raised when the scheduled reprocessor successfully replays a `DeadLetteredEvent` back into `IngestedEvent` | Domain event |
| ReconciliationCompleted | Internal-only domain event: raised when a `ReconciliationRun` transitions to `completed`; drives the nightly batch reconciler's read-model write step | Domain event |
| UserDataRedacted | Internal-only domain event: raised once a redaction sweep for a given `userId` completes across every matching `IngestedEvent` row, immediately before its `PiiRedactionRecord` is written | Domain event |

**Note on referenced terms:** `kart-analytics-service` deliberately does not decompose any consumed event's payload into modeled reference fields (no `IngestedEvent.orderId`, no `IngestedEvent.userId` as a typed reference) — every other bounded context's own domain terms (Order, Payment, Product, User, etc.) are stored only as opaque, registry-validated `payload` data on `IngestedEvent`, never redefined or partially modeled here. This opacity **is** this context's Anti-Corruption Layer; see `docs/services/kart-analytics-service/ddd-model.md`'s "Referenced Elsewhere" section for the full rationale. No per-term reference table is added here for the same reason.

## Owned by `kart-identity-service`

| Term | Definition | Kind |
|---|---|---|
| UserIdentity | The account/credential/role aggregate — native, social-federated, and enterprise-federated accounts all share this one shape; the single source of truth for "who is this" platform-wide | Aggregate root |
| UserId | The stable identifier issued by Identity for a `UserIdentity`; every other bounded context that needs to reference "which user" does so via this opaque id, never redefining identity itself | Value object |
| FederatedIdentity | One external IdP link (enterprise SAML/OIDC or social OIDC) to a `UserIdentity`, JIT-created on first successful federation | Entity |
| MfaCredential | The single active-or-pending TOTP (RFC 6238) credential for a `UserIdentity` | Entity |
| RoleGrant | A `(Role, GrantedAt, GrantedBy, RevokedAt)` tuple; the platform's single source of truth for "does this user hold this role" — no other service maintains an independent copy | Value object |
| Session | The login-to-logout/revocation lifecycle a refresh-token rotation family belongs to | Aggregate root |
| RefreshToken | A single-use, rotation-chained token within a `Session`; replay of an already-consumed one revokes the entire `Session` | Entity |
| ServicePrincipal | An OAuth2 Client Credentials-flow identity (Partner API clients, or another service's internal caller) — never has a `Session`/`RefreshToken` | Aggregate root |
| IdpGroupRoleMapping | The config-driven, fail-closed authority mapping one enterprise IdP's group/claim value to exactly one Kart role | Aggregate root |
| UserDataErased | Consumed domain event (ADR-0016): triggers PII tombstoning on `UserIdentity` and full `Session` revocation | Domain event |

## Referenced (owned elsewhere — accessed via ACL, not redefined here)

| Term | Owning Context | How `kart-identity-service` uses it |
|---|---|---|
| Admin (fine-grained permission grant) | kart-admin-service | Identity resolves only the coarse `Admin` `RoleGrant`; Admin Service owns and consults the separate, narrower `admin_permission_grants` table for which back-office categories an `Admin`-role holder can exercise (ADR-0010) |

## Owned by `kart-category-service`

| Term | Definition | Kind |
|---|---|---|
| Category | A taxonomy node (id, name, parent, hierarchy position, status); the smallest, least-contended bounded context on the platform — max depth 4, materialized-path storage | Aggregate root |
| CategoryId | The stable identifier issued by Category for a taxonomy node; never reassigned or reused, since it is the shard key `kart-product-service`/`kart-search-service` use downstream | Value object |
| AncestorPath | The ordered root-to-immediate-parent chain of `CategoryId`s for a `Category`, making ancestor/cycle checks an index lookup rather than a recursive walk | Value object |
| CategoryStatus | The `Active`/`Deprecated` lifecycle state of a `Category`; deprecation is the only removal path, `CategoryId` is never physically deleted | Value object |

## Referenced (owned elsewhere — accessed via ACL, not redefined here)

| Term | Owning Context | How `kart-category-service` uses it |
|---|---|---|
| Admin (RBAC-gated write caller) | kart-identity-service / kart-admin-service | Category's write endpoints trust the Identity-issued `Admin` role claim (BRD §24.1) and are called by Admin Service as an orchestration-layer client (ADR-0010); Category never models Admin's own fine-grained permission grants |

## Owned by `kart-inventory-service`

| Term | Definition | Kind |
|---|---|---|
| WarehouseStock | The per-`(warehouseId, sku)` stock row every reservation/release/replenishment write locks via `SELECT ... FOR UPDATE`; the oversell-prevention boundary — the platform's highest-contention aggregate | Aggregate root |
| Reservation | The hold created by a stock reserve call, correlated 1:1 with one order line-item request; TTL-bounded (15 min) and idempotently released via a terminal-state machine | Aggregate root |
| WarehouseAllocation | One `(warehouseId, qty)` pair within a `Reservation`; more than one only on the multi-warehouse fallback (no single warehouse could fully satisfy the line) | Entity |
| ReservationStatus | The `Reserved`/`Released`/`Expired` terminal-state machine a `Reservation` moves through; once terminal, further release attempts are idempotent no-ops | Value object |

## Referenced (owned elsewhere — accessed via ACL, not redefined here)

| Term | Owning Context | How `kart-inventory-service` uses it |
|---|---|---|
| Order (`orderId`) | kart-order-service | `Reservation.orderId` is a reference only; Inventory never models Order's own Saga/state machine, it only reacts to `OrderCancelled`/`OrderCompensationTriggered` |

## Owned by `kart-cart-service`

| Term | Definition | Kind |
|---|---|---|
| Cart | The mutable, pre-checkout basket of line items belonging to exactly one owner (a logged-in user or a guest session); the last place customer intent is mutable before Order takes over as Saga orchestrator | Aggregate root |
| CartLineItem | One `Sku`-and-quantity pairing within a Cart, unique per `Sku` within its parent Cart, carrying its own `LineItemAvailability` flag | Entity |
| CartOwner | The mutually exclusive `UserId`-or-`GuestSessionId` identity a Cart belongs to; a Cart always has exactly one | Value object |
| CartVersion | The optimistic-concurrency version counter checked and incremented on every Cart write (direct mutation or merge), rejecting a stale-write conflict | Value object |
| LineItemAvailability | The `Available`/`FlaggedUnavailable` state of a `CartLineItem`, set by consuming `InventoryReservationFailed` pre-checkout only, cleared on the line item's next successful validation | Value object |
| CartStatus | The `Active`/`CheckedOut` lifecycle state of a Cart; `CheckedOut` is terminal and gates post-checkout no-op handling of `InventoryReservationFailed` | Value object |
| GuestSessionId | The opaque anonymous-session identifier Cart treats as one of the two possible `CartOwner` shapes; modeled locally by Cart since no other bounded context currently claims ownership of an anonymous-session concept (see `ddd-model.md` Modeling Decision #4) | Value object |

## Referenced (owned elsewhere — accessed via ACL, not redefined here)

| Term | Owning Context | How `kart-cart-service` uses it |
|---|---|---|
| Sku / Product | kart-product-service | `CartLineItem.sku` is a reference only, resolved via a synchronous, fail-open lazy-validation call at checkout time; Cart never owns catalog or price data |
| UserId | kart-identity-service | `CartOwner` references a `UserId` issued by Identity (BRD §2.1 item 1); Cart never models authentication, token issuance, or session lifecycle itself |
| Order | kart-order-service | `CartCheckedOut` is published for Analytics only; Cart never models Order's own Saga/state machine, and Order's creation trigger (`POST /orders`) bypasses Cart entirely |
| InventoryReservationFailed | kart-inventory-service | Consumed only to flag a `CartLineItem`'s availability pre-checkout; Cart never models Inventory's own reservation aggregate |
