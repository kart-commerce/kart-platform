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

## Owned by `kart-product-service`

| Term | Definition | Kind |
|---|---|---|
| Product | The parent/grouping catalog record (name, description, category, brand) shared by one or more sellable Variants; never itself priced or orderable | Aggregate root |
| ProductStatus | The `Draft`/`Published`/`Archived` lifecycle of a Product; `Archived` cascades to discontinuing every child Variant | Value object |
| Variant | The actual sellable, priced unit — one row per SKU, referencing its parent Product; the aggregate every catalog event and the SKU-keyed read model are scoped to | Aggregate root |
| Sku | The globally unique identifier for a Variant, enforced via a PostgreSQL unique constraint independent of the read model's `category.id` shard key | Value object |
| VariantStatus | The `Active`/`Discontinued` soft-delete state of a Variant; discontinuation is one-directional, never reinstated | Value object |
| ProductAttributes | The hybrid EAV/JSONB attribute set for a Variant — first-class indexed `size`/`color` columns plus a schemaless `extendedAttributes` bag | Value object |
| ProductDiscontinued | Domain event (formalized at the DDD Agent stage from a requirement-spec/edge-cases proposal): fired when a Variant's status moves to Discontinued; unblocks `kart-search-service`'s and `kart-wishlist-service`'s own already-approved consumption plans | Domain event |

## Referenced (owned elsewhere — accessed via ACL, not redefined here)

| Term | Owning Context | How `kart-product-service` uses it |
|---|---|---|
| Category | kart-category-service | `Product.categoryId` is a caller-supplied reference only; never independently validated or refreshed against Category |
| Rating / `ReviewSubmitted` / `ReviewUpdated` | kart-review-service | Consumed only to maintain a denormalized `ratingSummary` projection (ADR-0014); Review owns the canonical rating aggregate |

## Owned by `kart-user-service`

| Term | Definition | Kind |
|---|---|---|
| UserProfile | A user's addresses, preferences, and a denormalized copy of Identity-owned contact fields; created only by consuming `UserRegistered` | Aggregate root |
| Address | One entry in a user's address book — identified by `AddressId`, scoped to exactly one `UserProfile`; at most one default per `AddressType` | Entity |
| AddressType | The `Shipping`/`Billing`/`Other` classification of an Address | Value object |
| Preferences | The `locale`/`currency`/`notificationOptIn`/`marketingConsent` set, stored as one additive-friendly JSONB value | Value object |
| ErasureStatus | The `Active`/`Erased` one-directional PII-tombstone state of a UserProfile (ADR-0016) | Value object |
| UserNotificationPreferenceUpdated | Domain event (formalized here from `kart-notification-service`'s own approved integration-contract resolution): fired when notification opt-in or the app-installed signal changes, translating User's coarse toggle into Notification's own send-time shape | Domain event |
| UserDataErased | Domain event (ADR-0016): fans the erasure tombstone out to every downstream service holding userId-linked PII | Domain event |

## Referenced (owned elsewhere — accessed via ACL, not redefined here)

| Term | Owning Context | How `kart-user-service` uses it |
|---|---|---|
| UserId | kart-identity-service | `UserProfile`'s own identity; never generated here, only consumed from `UserRegistered` |
| Email / DisplayName | kart-identity-service | Mirrored as a denormalized, eventually-consistent `contactCopy` (ADR-0006); never write-authoritative here |
| Admin (erasure-request caller) | kart-admin-service | Invokes the erasure-intake endpoint (ADR-0017); never modeled here |

## Owned by `kart-search-service`

| Term | Definition | Kind |
|---|---|---|
| SearchDocument | The per-SKU, query-side projection `/search` ranks and returns; a denormalized, foreign-fed copy of catalog/rating/category data with no write-side counterpart of its own | Aggregate root |
| RatingSignal | `{ avg, count, perReviewRatings }` — this service's own ranking-signal projection of Review's canonical rating aggregate, recomputed deterministically from a per-`reviewId` map for idempotency under at-least-once redelivery (`ddd-model.md`) | Value object |
| CategoryLookup | The `categoryId → categoryName` reference entry this service maintains independently by consuming `CategoryUpdated` directly from `kart-category-service`, rather than relaying a copy through Product (which has no such column) | Aggregate root |
| Availability | The `Active`/`Discontinued` soft-remove state a `SearchDocument` mirrors one-directionally from Product's `VariantStatus`; `Discontinued` excludes a document from default `/search` results without deleting it | Value object |
| FacetableAttributes | The `{ size, color, extendedAttributes }` shape mirrored unchanged from Product's `ProductAttributes`; `extendedAttributes.sponsored` is read here for ranking purposes only, never redefined as this service's own attribute | Value object |
| RankingProfile | The query-time scoring policy (weighted blend of normalized text relevance, rating, in-stock status, and a capped sponsored boost) applied identically to every `/search` request; not a per-document stored field | Value object |

## Referenced (owned elsewhere — accessed via ACL, not redefined here)

| Term | Owning Context | How `kart-search-service` uses it |
|---|---|---|
| Sku / Product / Variant / ProductAttributes | kart-product-service | Every catalog field on `SearchDocument` is sourced from Product's own events (`ProductCreated`/`ProductPriceChanged`/`ProductUpdated`/`ProductDiscontinued`, enriched by [ADR-0018](../adr/0018-search-catalog-signal-sourcing.md)); this service never models Product's own aggregate boundary or write-side schema |
| CategoryId | kart-category-service | `CategoryLookup.categoryId` references Category's own identifier; this service never models Category's taxonomy hierarchy |
| Rating / ReviewSubmitted / ReviewUpdated | kart-review-service | `RatingSignal` is a denormalized projection of Review's canonical rating aggregate (ADR-0014); this service never models Review's moderation workflow |

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
| UserId / UserDataErased | kart-identity-service / kart-user-service | `CartOwner` references a `UserId` issued by Identity (BRD §2.1 item 1); Cart never models authentication, token issuance, or session lifecycle itself. Consuming `UserDataErased` (ADR-0016, updated to name Cart) deletes every Cart owned by that `UserId` — Cart never models the erasure workflow itself, only reacts to it |
| Order | kart-order-service | `CartCheckedOut` is published for Analytics only; Cart never models Order's own Saga/state machine, and Order's creation trigger (`POST /orders`) bypasses Cart entirely |

## Owned by `kart-payment-service`

| Term | Definition | Kind |
|---|---|---|
| PaymentIntent | The authoritative record of a single charge's lifecycle (`Pending`/`Completed`/`Failed`/`Disputed`); never delegated to or duplicated inside the Order Saga's own state machine | Aggregate root |
| Refund | A (possibly partial) reversal against a `PaymentIntent`'s `CapturedAmount`; a child of `PaymentIntent`, not its own aggregate, since the refund-ceiling invariant must be checked atomically against the same row it belongs to | Entity |
| GatewayToken | The opaque, gateway-issued reference to tokenized card data a `PaymentIntent` holds; raw card data is never persisted | Value object |
| CapturedAmount | The `{ amount, currency }` ceiling every `Refund` under a `PaymentIntent` is checked against | Value object |
| PaymentIntentStatus | The `Pending`/`Completed`/`Failed`/`Disputed` state machine a `PaymentIntent` moves through; monotonic — once terminal, only the single `Completed → Disputed` escalation is accepted | Value object |
| ChargebackRecord | The single, overwritable `{ chargebackId, amount, reason, receivedAt }` record set on a `PaymentIntent` when a chargeback is ingested (ADR-0012's minimal "stop the bleeding" scope, not a full dispute-lifecycle history) | Value object |
| IdempotencyRecord | The reservation-then-confirmation ledger entry for one `(idempotencyKey, endpoint)` pair, bridging the non-transactional external gateway call between reserving a charge/refund attempt and confirming its outcome | Aggregate root |
| IdempotencyKeyScope | The `{ idempotencyKey, endpoint }` composite identity an `IdempotencyRecord` is uniquely keyed on — scoped so a charge-key and a refund-key can't collide on the same caller-supplied value | Value object |
| GatewayWebhookEvent | The idempotency ledger entry recognizing a duplicate or out-of-order asynchronous gateway confirmation (charge/refund settlement, chargeback notification) by the gateway's own event id; mirrors `kart-delivery-tracking-service`'s `WebhookDedupEntry` for the payment-gateway analogue | Aggregate root |
| PaymentCompleted | Domain event: fired exactly once when a `PaymentIntent` reaches `Completed` | Domain event |
| PaymentFailed | Domain event: fired exactly once when a `PaymentIntent` reaches `Failed`; never fired speculatively while the gateway outcome is still ambiguous | Domain event |
| RefundIssued | Domain event: fired once per successful `Refund`, carrying that `Refund`'s own id/amount — one event per partial refund | Domain event |
| ChargebackReceived | Domain event (ADR-0012, new — not previously named in the BRD): fired once a chargeback notification is ingested and `ChargebackRecord`/`Disputed` are set | Domain event |

## Referenced (owned elsewhere — accessed via ACL, not redefined here)

| Term | Owning Context | How `kart-payment-service` uses it |
|---|---|---|
| Order (`orderId`) | kart-order-service | Every `PaymentIntent`/event carries `orderId` as an opaque reference only; Payment never models Order's own Saga/state machine, only reacts to `OrderCreated` and accepts a direct compensating-refund call from Order as Saga orchestrator |

## Owned by `kart-wishlist-service`

| Term | Definition | Kind |
|---|---|---|
| WishlistEntry | A user's saved tracking of one product SKU for price-drop alerting; unique per `(userId, sku)` pair | Aggregate root |
| ReferencePrice | The price baseline a WishlistEntry's 5%-drop evaluation runs against; set at add-time, reset to the alerted price each time an alert fires | Value object |
| AlertCooldownState | The `lastAlertedAt` timestamp backing a WishlistEntry's 24-hour-per-pair alert cooldown | Value object |
| WishlistEntryStatus | The `Active`/`Stale` state of a WishlistEntry; set to `Stale` by a `ProductDiscontinued` event or the reconciliation job, never itself deleting the row | Value object |

## Referenced (owned elsewhere — accessed via ACL, not redefined here)

| Term | Owning Context | How `kart-wishlist-service` uses it |
|---|---|---|
| Sku / Variant / ProductDiscontinued | kart-product-service | `WishlistEntry.sku` is a reference only; `ProductDiscontinued` (consumed) transitions a WishlistEntry to `Stale`, never redefined locally |
| UserId / UserDataErased | kart-user-service / kart-identity-service | `WishlistEntry.userId` is an opaque reference; consuming `UserDataErased` (ADR-0016) deletes every WishlistEntry for that `userId` — Wishlist never models identity or erasure workflow beyond reacting to this event |
| InventoryReservationFailed | kart-inventory-service | Consumed only to flag a `CartLineItem`'s availability pre-checkout; Cart never models Inventory's own reservation aggregate |

## Owned by `kart-order-service`

| Term | Definition | Kind |
|---|---|---|
| Order | The single authoritative record of an order's lifecycle/Saga state — the platform's sole Saga orchestrator (BRD §5.1); no other service or in-memory process manager is ever more authoritative | Aggregate root |
| OrderLineItem | One `(sku, qty, unitPrice)` line within an Order, created and persisted only alongside its parent — no per-item shipment state (no split-shipment support, requirement-spec Open Question resolution #4) | Entity |
| OrderEvent | An append-only row per state transition, doubling as both the audit trail and the Outbox relay row (`order_events` doubles as the Outbox table, requirement-spec Open Question resolution #5); carries `OrderEventSequence` for per-order ordering | Entity |
| OrderStatus | The `Created \| Reserved \| Paid \| Shipped \| Delivered \| FulfillmentException \| Cancelled \| Refunded` lifecycle state machine; the compare-and-swap field for every transition (design-decisions.md) | Value object |
| FulfillmentException | The non-terminal, distinguishable hold state entered from `Paid` on consuming `ShipmentCreationFailed` (ADR-0015); resolved only by an explicit manual/ops action, back to `Paid` or on to `Cancelled` | Value (an `OrderStatus` value, not a separate type) |
| IdempotencyKey | The client-supplied `Idempotency-Key` header value on `POST /orders`, unique per Order; lives directly on the aggregate (no separate ledger, unlike Payment's `IdempotencyRecord`) since no external call sits between reserving it and committing the order | Value object |
| OrderCreated | Domain event: fired on `Created`, the initial commit of `POST /orders` | Domain event |
| OrderConfirmed | Domain event: fired on `Reserved → Paid`, as soon as `PaymentCompleted` is received (ADR-0002) — not gated on shipment creation | Domain event |
| OrderCancelled | Domain event: fired once the order reaches the terminal `Cancelled` state | Domain event |
| OrderCompensationTriggered | Domain event: fired at the start of any compensation sequence (pre-confirmation `PaymentFailed`, client-initiated cancel, `FulfillmentException`-to-`Cancelled`, or a `ChargebackReceived`-driven Inventory-release attempt) — one mechanism reused across all four triggers | Domain event |
| OrderDelivered | Domain event: fired on `Shipped → Delivered`, the sole terminal-delivery signal unifying the BRD's earlier `OrderCompleted`/`OrderDelivered` naming (ADR-0005) | Domain event |

## Referenced (owned elsewhere — accessed via ACL, not redefined here)

| Term | Owning Context | How `kart-order-service` uses it |
|---|---|---|
| Reservation / `reservationId` | kart-inventory-service | Referenced only via `POST /inventory/reserve`'s response and `InventoryReserved`/`InventoryReservationFailed`/`InventoryReleased` payloads; Order never models Inventory's own `WarehouseStock`/`Reservation` aggregate |
| PaymentIntent / `paymentIntentId` | kart-payment-service | Referenced only via `PaymentCompleted`/`PaymentFailed`/`ChargebackReceived` payloads and the `POST /payments/{id}/refund` call; Order never models Payment's own charge/refund/dispute state machine |
| Shipment / `ShipmentDispatched` / `ShipmentCreationFailed` | kart-shipping-service | Consumed only as status signals (dispatch confirmation, terminal fulfillment failure); Order never models Shipping's own carrier/label aggregate |
| TrackingRecord / `DeliveryStatusUpdated` | kart-delivery-tracking-service | Consumed only for its terminal "delivered" status value; Order never models Delivery Tracking's own tracking-history aggregate |

## Owned by `kart-shipping-service`

| Term | Definition | Kind |
|---|---|---|
| Shipment | The single authoritative record of one order's fulfillment attempt — carrier selection through label generation; created only by consuming `OrderConfirmed`, unique per `orderId` (at most one `Shipment` per `Order`) | Aggregate root |
| ShipmentStatus | The `Pending \| Dispatched \| Failed` state machine a `Shipment` moves through; `Pending` is the only non-terminal value, entered when the shipment-intent row commits, resolved out-of-band once the carrier interaction completes — monotonic, no transition out of either terminal value | Value object |
| Carrier | The carrier that actually produced a valid label for a `Shipment`; nullable until `Dispatched`, set exactly once by the carrier attempt that succeeds — the `carrier` field on `ShipmentDispatched`'s payload. Distinct from `kart-delivery-tracking-service`'s own `CarrierId` (a webhook-routing/adapter concern), not a re-owned or renamed version of it | Value object |
| CarrierSelectionPolicy | The ordered, externally-configured carrier priority list (primary, then secondary on the primary's circuit tripping) a shipment's carrier-selection attempt walks through; deliberately not a computed cheapest/fastest/contracted-rate business rule, since the BRD gives no such criteria (`ddd-model.md` Modeling Decision #2) | Value object |
| FailureReason | The nullable reason a `Shipment` reaches `Failed` — set once all configured carrier options are exhausted (address-validation failure or no carrier services the destination); the `reason` field on `ShipmentCreationFailed`'s payload | Value object |
| ShipmentDispatched | Domain event: fired exactly once when a `Shipment` reaches `Dispatched`, carrying `orderId, carrier, trackingId`; consumed by Order, Notification, Delivery Tracking, Analytics | Domain event |
| ShipmentCreationFailed | Domain event (ADR-0015, new — not previously named in the BRD): fired exactly once when a `Shipment` reaches `Failed`, carrying `orderId, reason`; consumed by Order, Notification, Analytics | Domain event |

## Referenced (owned elsewhere — accessed via ACL, not redefined here)

| Term | Owning Context | How `kart-shipping-service` uses it |
|---|---|---|
| Order / `OrderId` | kart-order-service | `Shipment.orderId` is a reference field only, and the natural unique business key `Shipment` is keyed on; Shipping never models Order's own Saga/state machine |
| OrderConfirmed | kart-order-service | Consumed as the sole shipment-creation trigger (payload `orderId, address`); Shipping never models Order's own confirmation logic, only reacts to it |
| TrackingId | kart-delivery-tracking-service | Shipping is the value's origin (captured from the carrier's label-generation response and first published on `ShipmentDispatched`), but does not re-claim the term's glossary ownership from Tracking's own existing, already-approved entry — flagged explicitly in `ddd-model.md` Modeling Decision #5 as a known naming/ownership asymmetry, not silently worked around |

## Owned by `kart-notification-service`

| Term | Definition | Kind |
|---|---|---|
| NotificationAttempt | One channel-specific send attempt derived from a single consumed triggering event; the `(eventId, channel)` idempotency/audit boundary — the DB unique constraint on this key *is* the idempotency mechanism, not a pre-check (ADR-0003's resolved consumed-event scope) | Aggregate root |
| NotificationAttemptKey | `{eventId, channel}` — the DB-unique-constraint-enforced idempotency key `NotificationAttempt` is identified by | Value object |
| Channel | `Email \| SMS \| Push` — the delivery channel a `NotificationAttempt` targets | Value object |
| TriggeringEventType | The name of the consumed event that caused a `NotificationAttempt` to exist (e.g. `OrderConfirmed`, `PaymentFailed`) — reference-only, never redefining the producing service's own event | Value object |
| CriticalityTier | `Tier1` (5 attempts + paged) / `Tier2` (3 attempts) / `Tier3` (2 attempts) retry budget, snapshotted onto a `NotificationAttempt` at creation from `TriggeringEventType`, inherited verbatim from the triggering event's own already-catalogued tier | Value object |
| NotificationCategory | The per-category classification (order-updates, payment, shipping, marketing/price-alerts, account) a `NotificationAttempt`'s opt-out check runs against | Value object |
| DeliveryOutcome | `Pending \| Sent \| Failed \| Suppressed` — the monotonic, terminal outcome state of a `NotificationAttempt` | Value object |
| AttemptCount | The number of physical delivery tries made against a `NotificationAttempt`'s `CriticalityTier` retry ceiling | Value object |
| NotificationPreference | The local, eventually-consistent per-user opt-out/reachability projection, populated solely by consuming `UserNotificationPreferenceUpdated` (owned by `kart-user-service`) | Aggregate root |
| OptOutMatrix | The full `{channel -> {category -> optedOut}}` map on a `NotificationPreference`, replaced wholesale on every consumed update, never partially patched | Value object |
| AppInstalled | The boolean push-reachability flag on a `NotificationPreference` | Value object |
| OrderUserIndex | Lookup projection (`orderId -> userId`), seeded solely from consuming `OrderCreated`; resolves `userId` for the seven consumed events that carry `orderId` but not `userId` (ADR-0020) — not an aggregate, no invariants beyond upsert-on-consume | Value object |
| TrackingOrderIndex | Lookup projection (`trackingId -> orderId`), seeded solely from consuming `ShipmentDispatched`; chains `DeliveryStatusUpdated`'s `trackingId` to `OrderUserIndex` for the one consumed event carrying neither `userId` nor `orderId` (ADR-0020) | Value object |
| NotificationSent | Domain event (existing BRD event, §10; previously unclaimed in the glossary, formally owned here): fired exactly once per terminal `NotificationAttempt`, carrying `userId, channel, status`; 1x fire-and-forget, consumed by Analytics only | Domain event |

## Referenced (owned elsewhere — accessed via ACL, not redefined here)

| Term | Owning Context | How `kart-notification-service` uses it |
|---|---|---|
| UserId | kart-identity-service | `NotificationAttempt.userId` and `NotificationPreference.userId` are reference fields only; Notification never models Identity's own account/credential aggregate |
| OrderCreated / OrderConfirmed / OrderCancelled / OrderCompensationTriggered / OrderDelivered | kart-order-service | Consumed only as `NotificationAttempt` creation triggers; `OrderCreated` additionally seeds `OrderUserIndex` (ADR-0020) — Notification never models Order's own Saga/state machine |
| PaymentCompleted / PaymentFailed / RefundIssued | kart-payment-service | Consumed only as `NotificationAttempt` creation triggers (Tier 1); Notification never models Payment's own charge/refund/dispute state machine |
| ShipmentDispatched | kart-shipping-service | Consumed as a `NotificationAttempt` creation trigger and, additionally, seeds `TrackingOrderIndex` (ADR-0020); Notification never models Shipping's own carrier/label aggregate |
| DeliveryStatusUpdated | kart-delivery-tracking-service | Consumed only as a `NotificationAttempt` creation trigger, resolved via `TrackingOrderIndex` -> `OrderUserIndex` (ADR-0020); Notification never models Tracking's own status-history/dedup aggregates |
| WishlistPriceAlertTriggered | kart-wishlist-service | Consumed only as a `NotificationAttempt` creation trigger (Tier 3); Notification never models Wishlist's own `WishlistEntry` aggregate |
| UserRegistered | kart-identity-service | Consumed only as a `NotificationAttempt` creation trigger (Tier 2, welcome email); independently also consumed by `kart-user-service`, no ordering dependency between the two consumers |
| UserNotificationPreferenceUpdated | kart-user-service | Consumed only as the sole `NotificationPreference` creation/update trigger; Notification never models User's own coarse `notificationOptIn` field or `UserProfile` aggregate |
