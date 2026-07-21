# Amazon-Scale E-Commerce Engineering Playground

### Senior Engineer System Design Mastery Project

**Stack:** .NET 9 / ASP.NET Core · PostgreSQL · MongoDB (Sharded) · RabbitMQ → Kafka · Redis · Docker · Kubernetes · Nginx · API Gateway

---

## 1. Executive Summary

### 1.1 Purpose

This is not an e-commerce build. It is a **deliberately over-engineered playground** that uses an e-commerce domain as the _carrier_ for a curriculum in distributed systems, data engineering, messaging, and operations. The e-commerce domain is chosen because it is the smallest domain that naturally forces every hard engineering problem to appear: money (consistency), inventory (contention), search (denormalization), notifications (fan-out), and scale (traffic spikes on sales days).

### 1.2 Why This Project Exists

Most tutorial e-commerce projects stop at CRUD + one database. That teaches almost nothing about what a Staff/Principal engineer actually does day to day: capacity planning, failure-mode design, choosing between consistency models, designing message infrastructure that survives partial outages, and defending architecture decisions in a design review. This project is structured so that **each section forces a decision**, and each decision has a documented trade-off, so it doubles as interview prep.

### 1.3 Learning Goals

|Domain|Concepts Covered|
|---|---|
|System Design|Service boundaries, CQRS, API Gateway, Load Balancing|
|Distributed Systems|Eventual consistency, Saga, idempotency, distributed tracing|
|Scalability|Sharding, partitioning, horizontal scaling, caching|
|Messaging|RabbitMQ topology, DLQ/DLX, Kafka migration, replay|
|Databases|PostgreSQL indexing/partitioning, MongoDB sharding, denormalization|
|DevOps|Docker multi-stage builds, Kubernetes, HPA, config/secrets|
|Reliability|Chaos engineering, failure simulation, retries, circuit breakers|
|Performance|Load testing at 100 RPM → 10M RPM, P95/P99 latency budgets|
|Security|JWT/OAuth2, API security, encryption at rest/in transit|
|Interviewing|100 system-design questions generated directly from this build|

### 1.4 What Makes This "Not Normal"

- Every service is **write-optimized in PostgreSQL, read-optimized in MongoDB**, connected by an Outbox → RabbitMQ → Kafka pipeline — on purpose, to teach CQRS synchronization pain.
- RabbitMQ is deliberately introduced first and later **broken on purpose** (replay requirements, huge throughput) to justify a real Kafka migration, rather than starting with Kafka because "it's cool."
- The messaging layer is **configuration-driven** (JSON-declared exchanges/queues/bindings), because in real orgs, message topology sprawl is a top-5 operational headache.
- Failure is a first-class feature: Section 13 and 26 exist specifically to break the system on purpose.

---

## 2. Business Requirements

### 2.1 Core Modules

|#|Service|Primary Responsibility|
|---|---|---|
|1|Identity Service|AuthN, tokens, sessions, MFA, SSO federation, RBAC role/claim issuance|
|2|User Service|Profile, addresses, preferences|
|3|Product Service|Product catalog, variants, attributes|
|4|Category Service|Taxonomy, hierarchy, navigation|
|5|Search Service|Full-text search, filters, facets, ranking|
|6|Inventory Service|Stock levels, reservations, warehouses|
|7|Cart Service|Cart lifecycle, merge, expiry|
|8|Order Service|Order lifecycle, order state machine|
|9|Payment Service|Payment intents, gateways, refunds|
|10|Coupon Service|Coupon issuance, redemption, limits|
|11|Pricing Service|Price computation, tax, currency|
|12|Promotion Service|Campaigns, flash sales, bundle deals|
|13|Wishlist Service|Saved items, price-drop alerts|
|14|Review Service|Ratings, reviews, moderation|
|15|Notification Service|Email/SMS/push fan-out|
|16|Shipping Service|Carrier selection, label generation|
|17|Delivery Tracking Service|Real-time tracking, ETA|
|18|Recommendation Service|Personalization, "customers also bought"|
|19|Analytics Service|Event ingestion, dashboards, funnels|
|20|Admin Service|Back-office operations, RBAC|

### 2.2 Domain Rules That Force Hard Engineering Decisions

- **Inventory** must never oversell → forces optimistic locking / reservation patterns.
- **Payment** must never double-charge → forces idempotency keys + Saga compensation.
- **Search** must reflect catalog changes within seconds, not milliseconds → forces eventual consistency conversation.
- **Order Service** is the Saga orchestrator touching Inventory, Payment, and Shipping → forces distributed transaction design.
- **Analytics** ingests every domain event → forces a durable event bus and schema versioning discipline.

---

## 3. Non-Functional Requirements

|Attribute|Target|Notes|
|---|---|---|
|Availability|99.99% (order path), 99.9% (secondary)|~52 min/year downtime budget for critical path|
|Scalability|Horizontal, stateless services|Autoscale via K8s HPA on CPU + queue depth|
|Reliability|No data loss on Order/Payment events|At-least-once delivery + idempotent consumers|
|Consistency|Strong (PostgreSQL/write path), Eventual (MongoDB/read path)|CQRS boundary explicit|
|Latency|P95 < 150ms, P99 < 400ms (read path)|P95 < 300ms (write path, includes Outbox insert)|
|Throughput|100K RPS sustained, 1M RPS burst (flash sale)|Read-heavy services scale independently of write|
|Fault Tolerance|Graceful degradation, no cascading failure|Circuit breakers on all outbound calls|
|Security|Zero plaintext secrets, signed tokens, TLS everywhere|JWT short-lived + refresh rotation|
|Maintainability|Independently deployable services|Contract-tested APIs, versioned events|
|Observability|100% trace coverage on order path|Correlation ID propagated end-to-end|

---

## 4. Capacity Planning

### 4.1 Business Assumptions

|Metric|Value|
|---|---|
|Registered Users|50,000,000|
|Daily Active Users|5,000,000|
|Average Orders/Day (normal)|1,000,000|
|Peak Orders/Day (flash sale, 20x)|20,000,000|
|Product Catalog Size|100,000,000 SKUs|
|Average Cart Size|3.2 items|
|Events per Order (created→delivered)|~14|

### 4.2 Traffic Derivation

|Load Tier|RPM|RPS|Scenario|
|---|---|---|---|
|Baseline|100|~2|Local dev / smoke test|
|Low|1,000|~17|Off-peak hours|
|Medium|100,000|~1,700|Normal daytime traffic|
|High|1,000,000|~17,000|Evening peak|
|Extreme|10,000,000|~167,000|Flash sale / Black Friday|

### 4.3 Storage & Message Volume

|Resource|Estimate|
|---|---|
|Product catalog storage (MongoDB, denormalized)|~2 TB|
|Order write storage (PostgreSQL, 5yr retention)|~4 TB|
|Daily event volume (all services)|~200M messages/day|
|Peak Kafka throughput|~50,000 messages/sec|
|Redis working set (hot products + sessions)|~64 GB|

### 4.4 Network

- Read:Write ratio ≈ 20:1 (typical catalog-heavy e-commerce).
- CDN offloads ~80% of product image/static traffic from origin.
- Inter-service east-west traffic budgeted separately from north-south (client-facing) traffic for K8s network policy planning.

---

## 5. Microservice Design

Each service below follows the same template: **Responsibility → API → Database → Events Published → Events Consumed → Dependencies → Boundary Rationale**.

### 5.1 Order Service (representative deep-dive — the Saga orchestrator)

|Aspect|Detail|
|---|---|
|Responsibility|Owns order lifecycle state machine: `Created → Reserved → Paid → Shipped → Delivered → Cancelled/Refunded`|
|API|`POST /orders`, `GET /orders/{id}`, `POST /orders/{id}/cancel`|
|Database|PostgreSQL: `orders`, `order_items`, `order_events` (write side)|
|Publishes|`OrderCreated`, `OrderConfirmed`, `OrderCancelled`, `OrderCompensationTriggered`, `OrderDelivered`|
|Consumes|`InventoryReserved`, `InventoryReservationFailed`, `PaymentCompleted`, `PaymentFailed`, `ShipmentDispatched`, `DeliveryStatusUpdated` (terminal "delivered" status, triggers `OrderDelivered` — see ADR-0005)|
|Dependencies|Inventory Service (sync reserve call + async confirm), Payment Service (async), Shipping Service (async)|
|Boundary Rationale|Order is the only service allowed to drive cross-service business transactions (Saga orchestrator) — this prevents "distributed monolith" behavior where every service calls every other service directly.|

### 5.2 Inventory Service

|Aspect|Detail|
|---|---|
|Responsibility|Stock truth per warehouse, reservation holds with TTL|
|API|`POST /inventory/reserve`, `POST /inventory/release`, `GET /inventory/{sku}`|
|Database|PostgreSQL with row-level `SELECT ... FOR UPDATE` on stock rows|
|Publishes|`InventoryReserved`, `InventoryReservationFailed`, `InventoryReplenished`, `InventoryReleased` (compensating release — named in §12.2's diagram, previously missing from this row and the Event Catalog; see ADR-0007)|
|Consumes|`OrderCancelled` (release), `OrderCompensationTriggered` (release)|
|Boundary Rationale|Isolated so oversell logic (the highest-contention code in the whole system) can be scaled, locked, and load-tested independently of everything else.|

### 5.3 Payment Service

|Aspect|Detail|
|---|---|
|Responsibility|Payment intents, idempotent charge execution, refunds|
|API|`POST /payments/charge` (requires `Idempotency-Key`), `POST /payments/{id}/refund`|
|Database|PostgreSQL: `payment_intents`, `idempotency_keys` (unique constraint)|
|Publishes|`PaymentCompleted`, `PaymentFailed`, `RefundIssued`|
|Consumes|`OrderCreated` (initiate charge)|
|Boundary Rationale|Isolated for PCI-scope reduction — only this service touches gateway tokens; blast radius of a compromise is contained.|

### 5.4 Remaining Services (condensed)

|Service|API surface|DB|Key Events Published|Key Events Consumed|
|---|---|---|---|---|
|Identity|`/auth/login`, `/auth/refresh`|PostgreSQL|`UserRegistered`, `SessionCreated`, `UserAccountUpdated` (email/name change — see ADR-0006)|—|
|User|`/users/{id}`|PostgreSQL → MongoDB read|`UserProfileUpdated`|`UserRegistered`, `UserAccountUpdated` (see ADR-0006)|
|Product|`/products/{id}`|PostgreSQL → MongoDB read|`ProductCreated`, `ProductPriceChanged`|—|
|Category|`/categories`|PostgreSQL|`CategoryUpdated`|—|
|Search|`/search` (query only)|MongoDB / OpenSearch|—|`ProductCreated`, `ProductPriceChanged`|
|Cart|`/cart`, `/cart/merge`|Redis + PostgreSQL snapshot|`CartCheckedOut`|`InventoryReservationFailed`|
|Coupon|`/coupons/validate`|PostgreSQL|`CouponRedeemed`|`OrderCancelled`|
|Pricing|`/pricing/quote`|PostgreSQL|`PriceQuoteIssued`|`ProductPriceChanged`|
|Promotion|`/promotions/active`|PostgreSQL → Redis cache|`PromotionActivated`|—|
|Wishlist|`/wishlist`|MongoDB|`WishlistPriceAlertTriggered`|`ProductPriceChanged`|
|Review|`/reviews`|PostgreSQL → MongoDB read|`ReviewSubmitted`|`OrderDelivered` (canonical name — see ADR-0005)|
|Notification|(consumer only, no public API)|PostgreSQL (audit)|`NotificationSent`|All `order.*` and `payment.*` routed events (per §9's manifest), plus `WishlistPriceAlertTriggered`, `UserRegistered`, `OrderDelivered` — resolved scope, see ADR-0003; §10 lists the full resolved consumer set per event|
|Shipping|`/shipments`|PostgreSQL|`ShipmentDispatched`|`OrderConfirmed`|
|Delivery Tracking|`/tracking/{id}`|MongoDB|`DeliveryStatusUpdated`|carrier webhook → internal event|
|Recommendation|`/recommendations/{userId}`|MongoDB|—|`OrderDelivered` (see ADR-0005 — supersedes the BRD's earlier "OrderCompleted" naming), clickstream events|
|Analytics|(ingestion only)|Kafka topics → warehouse|—|All events, full fan-in — resolved scope, see ADR-0004; §10 lists Analytics as a consumer on every row|
|Admin|`/admin/*` (RBAC-gated)|PostgreSQL|`AdminActionPerformed`|—|

### 5.5 Service Boundary Diagram

```mermaid
graph TB
    Client[Client / Mobile / Web]
    GW[API Gateway]
    Client --> GW
    GW --> Identity
    GW --> Product
    GW --> Search
    GW --> Cart
    GW --> Order
    Order --> Inventory
    Order --> Payment
    Order --> Shipping
    Order -. events .-> Bus[(Message Bus)]
    Inventory -. events .-> Bus
    Payment -. events .-> Bus
    Shipping -. events .-> Bus
    Bus --> Notification
    Bus --> Analytics
    Bus --> Search
    Bus --> Recommendation
    Bus --> DeliveryTracking
```

---

## 6. Database Design

### 6.1 PostgreSQL (Write Side)

**Example — `orders` table**

```sql
CREATE TABLE orders (
    order_id       UUID PRIMARY KEY,
    user_id        UUID NOT NULL,
    status         VARCHAR(20) NOT NULL,
    total_amount   NUMERIC(12,2) NOT NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
) PARTITION BY RANGE (created_at);

CREATE TABLE orders_2026_07 PARTITION OF orders
    FOR VALUES FROM ('2026-07-01') TO ('2026-08-01');

CREATE INDEX idx_orders_user_id ON orders (user_id);
CREATE INDEX idx_orders_status_created ON orders (status, created_at DESC);
```

|Technique|Where Used|Why|
|---|---|---|
|Range Partitioning by month|`orders`, `order_events`|Bounded index size, fast archival of old partitions|
|B-Tree composite index|`(status, created_at)`|Supports "all pending orders in last hour" dashboards|
|`SELECT ... FOR UPDATE`|Inventory stock rows|Prevents oversell under concurrent reservation|
|Unique constraint on idempotency key|Payment|Guarantees exactly-once charge attempt semantics|

**Read-Heavy vs Write-Heavy**

|Service|Profile|Reasoning|
|---|---|---|
|Order, Payment, Inventory|Write-heavy|Correctness > raw read speed → PostgreSQL is source of truth|
|Product, Search, Category|Read-heavy|Millions of reads per write → MongoDB/denormalized is source of truth for reads|

### 6.2 MongoDB (Read Side, Sharded)

**Example — denormalized `product_read_model` collection**

```json
{
  "_id": "sku-192837",
  "name": "Wireless Mouse",
  "category": { "id": "cat-12", "name": "Electronics" },
  "price": { "amount": 24.99, "currency": "USD" },
  "inventoryStatus": "IN_STOCK",
  "ratingSummary": { "avg": 4.6, "count": 1899 },
  "searchTokens": ["wireless", "mouse", "electronics"]
}
```

|Aspect|Design|
|---|---|
|Sharding Key|`category.id` for Product/Search collections (even distribution + locality for browse queries)|
|Replica Sets|3-node replica set per shard, majority write concern for read-model durability|
|Denormalization|Category name, price, and rating summary embedded directly to avoid joins on the read path|
|Why Denormalize|MongoDB has no cross-shard joins; embedding trades storage/staleness for read latency|

---

## 7. CQRS Design

```mermaid
sequenceDiagram
    participant Client
    participant OrderSvc as Order Service (Command)
    participant PG as PostgreSQL
    participant Outbox
    participant MQ as RabbitMQ
    participant Mongo as MongoDB (Query)

    Client->>OrderSvc: POST /orders
    OrderSvc->>PG: INSERT order + INSERT outbox row (same TX)
    PG-->>OrderSvc: Commit
    OrderSvc-->>Client: 202 Accepted
    Outbox->>MQ: Publish OrderCreated (poller/CDC)
    MQ->>Mongo: Consumer projects read model
    Client->>OrderSvc: GET /orders/{id} (later)
    OrderSvc->>Mongo: Read projected view
```

- **Command Side**: PostgreSQL, strongly consistent, transactional writes.
- **Query Side**: MongoDB, eventually consistent, optimized for the exact shape the UI needs.
- **Eventual Consistency Window**: typically sub-second, but must be surfaced to the client (e.g., "processing your order" state) rather than hidden.
- **Failure Handling**: if the projection consumer fails, the Outbox row remains unacknowledged/retried — the read model is _always_ rebuildable from the write side, which is the core CQRS safety property.

---

## 8. RabbitMQ Design

### 8.1 Topology

|Element|Design|
|---|---|
|Exchange type|Topic exchange (`ecommerce.events`) for flexible routing by `service.entity.action` keys|
|Routing Key Convention|`order.created`, `payment.completed`, `inventory.reservation.failed`|
|Queue per Consumer Group|Each service owns its own queue bound with a wildcard pattern, e.g. `notification.*`|
|DLX|Every queue has `x-dead-letter-exchange` pointing to a shared `dlx.ecommerce`|
|DLQ|One DLQ per service queue, inspected via admin tooling, never silently dropped|
|Retry Queue|TTL-based "parking lot" queue (`retry.5s`, `retry.30s`, `retry.5m`) that dead-letters back into the original queue after expiry — classic RabbitMQ delayed-retry pattern|

### 8.2 Why This Design

- **Topic exchange over direct exchange**: allows adding new consumers without touching the publisher — publishers don't know or care who's listening.
- **Per-service DLQ over one global DLQ**: failure triage is per-team; a global DLQ becomes an unowned dumping ground.
- **TTL-ladder retry over immediate requeue**: immediate requeue under a persistent failure (e.g., DB down) creates a hot retry loop that pins CPU; a backoff ladder spaces retries out.

### 8.3 Alternatives Considered

|Alternative|Pros|Cons|
|---|---|---|
|Direct exchange per event type|Simpler routing|Explodes exchange count, hard to add cross-cutting consumers|
|Single shared queue for all consumers|Fewer resources|One slow consumer blocks all others (no isolation)|
|Kafka from day one|Replay, higher throughput|Overkill for early-stage bounded queues; steeper ops learning curve early|

---

## 9. Configuration-Driven Message Bus

Application startup reads a JSON manifest and declares all RabbitMQ topology idempotently (`durable`, declare-if-not-exists) — no manual `rabbitmqctl` setup, no drift between environments.

```json
{
  "exchanges": [
    { "name": "ecommerce.events", "type": "topic", "durable": true }
  ],
  "queues": [
    {
      "name": "notification.queue",
      "bindings": [
        { "exchange": "ecommerce.events", "routingKey": "order.*" },
        { "exchange": "ecommerce.events", "routingKey": "payment.*" }
      ],
      "arguments": {
        "x-dead-letter-exchange": "dlx.ecommerce",
        "x-dead-letter-routing-key": "notification.dlq"
      }
    },
    {
      "name": "notification.dlq",
      "bindings": [
        { "exchange": "dlx.ecommerce", "routingKey": "notification.dlq" }
      ]
    },
    {
      "name": "retry.30s",
      "arguments": {
        "x-message-ttl": 30000,
        "x-dead-letter-exchange": "ecommerce.events",
        "x-dead-letter-routing-key": "notification.retry"
      }
    }
  ]
}
```

**Why config-driven beats code-driven**: topology changes become a reviewable diff instead of a code deploy; the same manifest can be diffed across dev/staging/prod to catch drift; non-backend engineers (SRE, on-call) can read the JSON to understand routing without reading C#.

---

## 10. Event Catalog

|Event|Publisher|Consumer(s)|Payload (key fields)|Retry|DLQ Strategy|
|---|---|---|---|---|---|
|`OrderCreated`|Order|Payment, Analytics, Notification|orderId, userId, items, total|3x exponential|to `order.dlq`, manual replay tool|
|`OrderConfirmed`|Order|Shipping, Notification, Analytics|orderId, address|3x|`order.dlq`|
|`OrderCancelled`|Order|Inventory, Coupon, Notification, Analytics|orderId, reason|3x|`order.dlq`|
|`OrderCompensationTriggered`|Order|Inventory, Notification, Analytics|orderId, reason|3x|`order.dlq`|
|`OrderDelivered`|Order|Recommendation, Review, Notification, Analytics|orderId, deliveredAt|3x|`order.dlq`|
|`InventoryReserved`|Inventory|Order, Analytics|orderId, sku, qty|2x|`inventory.dlq`|
|`InventoryReservationFailed`|Inventory|Order, Cart, Analytics|orderId, sku|2x|`inventory.dlq`|
|`InventoryReleased`|Inventory|Order, Analytics|orderId, sku, qty|2x|`inventory.dlq`|
|`InventoryReplenished`|Inventory|Analytics|sku, qtyAdded, warehouseId|2x|`inventory.dlq`|
|`PaymentCompleted`|Payment|Order, Analytics, Notification|orderId, txnId|5x (money-critical)|`payment.dlq`, paged on-call|
|`PaymentFailed`|Payment|Order, Notification, Analytics|orderId, reason|5x|`payment.dlq`, paged on-call|
|`RefundIssued`|Payment|Order, Notification, Analytics|orderId, refundId, amount|5x (money-critical)|`payment.dlq`, paged on-call|
|`ShipmentDispatched`|Shipping|Order, Notification, Tracking, Analytics|orderId, carrier, trackingId|3x|`shipping.dlq`|
|`DeliveryStatusUpdated`|Delivery Tracking|Order (terminal status only), Notification, Analytics|trackingId, status|3x|`tracking.dlq`|
|`ProductCreated`|Product|Search, Recommendation, Analytics|sku, attributes|3x|`catalog.dlq`|
|`ProductPriceChanged`|Pricing|Search, Wishlist, Analytics|sku, oldPrice, newPrice|3x|`catalog.dlq`|
|`ReviewSubmitted`|Review|Product (rating recalc), Analytics|orderId, sku, rating|2x|`review.dlq`|
|`CouponRedeemed`|Coupon|Order, Analytics|code, orderId|2x|`coupon.dlq`|
|`NotificationSent`|Notification|Analytics|userId, channel, status|1x (fire-and-forget audit)|`notification.dlq`|
|`CartCheckedOut`|Cart|Analytics (funnel/conversion tracking)|cartId, userId, items|2x|`cart.dlq`|
|`WishlistPriceAlertTriggered`|Wishlist|Notification, Analytics|userId, sku, oldPrice, newPrice|2x|`wishlist.dlq`|
|`AdminActionPerformed`|Admin|Analytics (audit trail)|adminId, action, entityId|1x (fire-and-forget audit)|`admin.dlq`|
|`UserRegistered`|Identity|User, Notification, Analytics|userId, email|3x|`identity.dlq`|
|`SessionCreated`|Identity|Analytics|userId, sessionId|2x|`identity.dlq`|
|`UserAccountUpdated`|Identity|User|userId, email, displayName|2x|`identity.dlq`|

_Money-moving events (`Payment*`, `RefundIssued`) get the highest retry budget and human paging; catalog/search events get looser retry because staleness is tolerable for seconds. This table was extended to close two categories of gap found during platform review (see `kart-platform/docs/adr/0002-*.md` through `0007-*.md`): (1) events named in a service's own row (§5.4) that had no Event Catalog entry at all — `OrderCompensationTriggered`, `InventoryReleased`, `InventoryReplenished`, `RefundIssued`, `CartCheckedOut`, `WishlistPriceAlertTriggered`, `AdminActionPerformed`, `UserRegistered`, `SessionCreated` — and (2) two genuinely ambiguous consumer-scope questions (Notification's actual consumed-event set, Analytics' actual ingestion scope) that were resolved rather than left to each service to guess independently. `OrderDelivered` and `UserAccountUpdated` are new events, not previously named anywhere in the BRD — see ADR-0005 and ADR-0006 respectively for why they were needed._

---

## 11. Outbox Pattern

**Problem**: writing to PostgreSQL and publishing to RabbitMQ are two separate systems — a crash between them either loses the event or double-processes it ("dual write problem").

**Solution**: write the event into an `outbox` table in the _same database transaction_ as the business write. A separate poller/CDC process reads unpublished outbox rows and publishes them, marking them published only after broker ack.

```sql
CREATE TABLE outbox (
    id            UUID PRIMARY KEY,
    aggregate_id  UUID NOT NULL,
    event_type    VARCHAR(100) NOT NULL,
    payload       JSONB NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    published_at  TIMESTAMPTZ NULL
);
CREATE INDEX idx_outbox_unpublished ON outbox (created_at) WHERE published_at IS NULL;
```

**Retry**: poller re-reads rows where `published_at IS NULL` older than a threshold; publish is idempotent on the consumer side via event `id` deduplication.

```mermaid
sequenceDiagram
    participant Svc as Service
    participant DB as PostgreSQL
    participant Poller as Outbox Poller
    participant MQ as RabbitMQ

    Svc->>DB: BEGIN TX: INSERT business row + INSERT outbox row
    DB-->>Svc: COMMIT
    loop every 200ms
        Poller->>DB: SELECT unpublished rows
        Poller->>MQ: Publish
        MQ-->>Poller: ACK
        Poller->>DB: UPDATE published_at
    end
```

---

## 12. Saga Pattern

### 12.1 Order Saga — Success Flow

```mermaid
sequenceDiagram
    participant Order
    participant Inventory
    participant Payment
    participant Shipping

    Order->>Inventory: Reserve stock
    Inventory-->>Order: InventoryReserved
    Order->>Payment: Charge
    Payment-->>Order: PaymentCompleted
    Order->>Shipping: Create shipment
    Shipping-->>Order: ShipmentDispatched
    Order->>Order: Mark OrderConfirmed
```

_Integration style note (resolves the apparent sync-call reading of this diagram — see ADR-0002 in `kart-platform`): every arrow above is async pub/sub over the message bus, not synchronous RPC — the same request/reply notation is used for the Payment step too, and Payment is unambiguously stated as async in §5.1's Dependencies row, so the notation itself carries no sync/async meaning, only causal order. `OrderConfirmed` is published as soon as Payment clears (before Shipping has actually created anything) — Shipping is an async consumer of `OrderConfirmed`, exactly as §5.4/§10 state — and `ShipmentDispatched` flows back to Order purely as an informational status update. "Order->>Order: Mark OrderConfirmed" as the last line is diagram shorthand for "the happy path completed end-to-end," not a literal publish-order requirement that confirmation waits on shipment creation._

### 12.2 Order Saga — Failure & Compensation Flow

```mermaid
sequenceDiagram
    participant Order
    participant Inventory
    participant Payment

    Order->>Inventory: Reserve stock
    Inventory-->>Order: InventoryReserved
    Order->>Payment: Charge
    Payment-->>Order: PaymentFailed
    Order->>Inventory: Release reservation (compensation)
    Inventory-->>Order: InventoryReleased
    Order->>Order: Mark OrderCancelled
```

**Payment Saga**: charge → (on later dispute) refund is itself a compensating action, tracked as its own saga instance rather than reusing the order saga state machine, since refunds can be partial and asynchronous relative to the original order lifecycle.

---

## 13. Failure Simulation

|Scenario|Injection Method|Detection|Recovery|
|---|---|---|---|
|Service Down|Kill pod / scale to 0|K8s liveness probe fails, alert fires|K8s restarts pod; upstream circuit breaker opens meanwhile|
|Database Down|Block PG port via network policy|Connection pool exhaustion metric spikes|Failover to replica; writes queue in Outbox until DB returns|
|RabbitMQ Down|Stop broker container|Publisher confirms time out|Local durable buffer / retry with backoff; alert on-call|
|Consumer Failure|Throw exception in handler|Unacked message count grows|Message redelivered after visibility timeout; after N attempts → DLQ|
|Network Partition|`tc netem` packet loss|Elevated P99 latency, timeout errors|Circuit breaker trips, fallback to cached/degraded response|
|Duplicate Message|Force redelivery twice|Downstream state mismatch if not idempotent|Idempotency key check at consumer — second delivery is a no-op|
|Slow Database|Inject artificial query delay|Query duration histogram P99 spikes|Connection pool timeout + bulkhead isolates slow path from others|
|Queue Overflow|Flood publisher faster than consumers drain|Queue depth metric breaches threshold alert|Autoscale consumers via K8s HPA on queue-depth custom metric|

---

## 14. RabbitMQ Limitations

RabbitMQ is a smart broker with dumb consumers — great for task distribution, weak for the following:

|Limitation Encountered|Why It Hurts Here|
|---|---|
|No native replay|Analytics needs to reprocess 30 days of `OrderCreated` after a bug fix — RabbitMQ queues are consumed and gone|
|Throughput ceiling under heavy fan-out|Flash-sale traffic (167K RPS) with 10+ consumer groups per event multiplies effective message rate beyond comfortable single-node broker throughput|
|No log-based partitioned parallelism|Kafka partitions allow ordered, parallel consumption per key (e.g., per `orderId`); RabbitMQ queues don't give the same partition-level parallel ordering guarantee at scale|
|Retention is a queue, not a log|Once consumed & acked, the message is gone — no "time travel" for new consumers added later|

---

## 15. Kafka Migration

```mermaid
graph LR
    Producers[Domain Services] --> Outbox[(Outbox Table)]
    Outbox --> Dual{Dual Publish During Migration}
    Dual --> RMQ[RabbitMQ]
    Dual --> Kafka[Kafka Topics]
    RMQ --> LegacyConsumers[Legacy Consumers]
    Kafka --> NewConsumers[Analytics / Recommendation / Replay Tools]
```

**Why**: Analytics and Recommendation need replay and high-throughput partitioned consumption; Notification and transactional Order/Payment flows stay on RabbitMQ because they need low-latency task-queue semantics (ack/nack, per-message routing), not a log.

**Migration Strategy**: strangler pattern — dual-publish from the Outbox to both brokers during a transition window, migrate consumers one at a time (analytics first, since it's the one hitting RabbitMQ's replay limitation), then retire the RabbitMQ topic once every consumer group has cut over. Order/Payment/Inventory remain on RabbitMQ permanently — this is a case-by-case migration, not a wholesale replacement.

---

## 16. Caching

|Pattern|Where Used|Detail|
|---|---|---|
|Cache-Aside|Product detail reads|App checks Redis first; on miss, reads MongoDB and populates cache with TTL|
|Write-Through|Promotion/active-campaign flags|Write updates Redis and DB synchronously since staleness there is unacceptable for pricing|
|Distributed Cache|Session tokens, cart snapshots|Redis Cluster, consistent hashing across nodes|

**Cache Invalidation**: TTL + explicit invalidation on `ProductPriceChanged`/`ProductUpdated` events (cache-busting via event consumer, not just TTL expiry) to avoid serving stale prices.

**Hot Keys**: flash-sale SKUs can concentrate reads on one Redis key/shard; mitigated with local in-process micro-cache (few hundred ms) in front of Redis plus key sharding (`sku:{id}:{shard}`) for extreme cases.

---

## 17. Search

- **Engine**: OpenSearch (Elasticsearch-compatible), fed by the same Outbox/event pipeline as MongoDB read models — search index and MongoDB read model are siblings, not dependent on each other.
- **Product Search**: multi-match query across name/description/brand fields with boosting on exact SKU/brand match.
- **Ranking**: relevance score blended with business signals — rating, in-stock status, and a controlled "sponsored placement" boost.
- **Filtering**: faceted aggregations on category, price range, and rating, computed server-side to avoid over-fetching.

---

## 18. API Gateway

|Concern|Design|
|---|---|
|Routing|Path-based routing to services (`/orders/*` → Order Service) with version prefix (`/v1/`)|
|Authentication|JWT validated at gateway edge; downstream services trust a signed internal header, not the raw client token|
|Rate Limiting|Token-bucket per API key/user, tiered limits (anonymous < authenticated < partner API)|

---

## 19. Reverse Proxy

Nginx sits in front of the gateway for TLS termination, static asset serving, and request buffering. A **proxy** forwards client requests to a specific known backend on behalf of the client; a **reverse proxy** sits in front of a server farm and decides which backend serves a request, hiding backend topology from the client — Nginx here fulfils the latter role.

---

## 20. Load Balancing

|Algorithm|Used For|Reasoning|
|---|---|---|
|Round Robin|Stateless read services (Product, Search)|Even distribution, no session affinity needed|
|Least Connections|Order/Payment write path|Avoids piling long-running write requests onto an already-busy pod|

---

## 21. Containerization

- **Multi-stage Dockerfile**: SDK image builds/publishes .NET binaries in stage 1; final image copies only the published output onto a minimal ASP.NET runtime base — keeps production images small and reduces attack surface.
- **Layer Caching**: `COPY *.csproj` + `dotnet restore` as an early layer, separate from `COPY . .` + build, so dependency restore is cached across builds when only source code changes.

---

## 22. Kubernetes

|Object|Role in This Project|
|---|---|
|Pod|Smallest deployable unit — one service instance|
|Deployment|Manages replica count + rolling updates per service|
|Service|Stable internal DNS + load balancing across pods|
|Ingress|External HTTP routing into the cluster (fronted by the API Gateway)|
|HPA|Autoscales consumer pods on custom metric: RabbitMQ/Kafka queue depth, not just CPU|
|ConfigMap|Non-secret config (message bus topology JSON, feature flags)|
|Secret|DB credentials, JWT signing keys, payment gateway API keys|

---

## 23. Observability

|Pillar|Implementation|
|---|---|
|Structured Logging|JSON logs with `traceId`, `service`, `level`, `orderId` fields — machine-parseable, not free text|
|Metrics|RED metrics (Rate, Errors, Duration) per service + business metrics (orders/min, cart abandonment)|
|Distributed Tracing|W3C Trace Context propagated through HTTP headers and message headers so a single order can be traced across all 8+ services it touches|

**Normal Logging vs Structured Logging**: normal logging writes free-text strings meant for a human reading a terminal (`"Order 123 failed"`); structured logging writes key-value/JSON records meant for a machine to index, filter, and aggregate (`{"event":"order_failed","orderId":"123","reason":"payment_declined"}`) — the latter is what makes "show me all failed orders for user X in the last hour" a query instead of a `grep` archaeology project.

---

## 24. Security

|Layer|Control|
|---|---|
|AuthN|OAuth2 Authorization Code flow (web/mobile clients), Client Credentials (service-to-service), SSO via OIDC/SAML federation (see §24.2)|
|AuthZ|JWT with scoped claims, validated at gateway + re-checked at service for sensitive operations; RBAC role claims embedded in the token, enforced platform-wide (see §24.1)|
|Token Lifecycle|Short-lived access tokens (~15 min), rotating refresh tokens, revocation list for logout|
|Encryption|TLS 1.3 in transit everywhere; AES-256 at rest for PII columns; payment data never stored — tokenized by the gateway provider|
|API Security|Input validation, rate limiting, mandatory idempotency keys on all money-moving POSTs|

### 24.1 Cross-Cutting RBAC Model

RBAC is a platform-wide concern, not an Admin Service–local feature — every one of the 20 services trusts the same role claims rather than maintaining its own permission table. Identity Service is the single issuer of roles; every other service is a **consumer** of the claim, never a second source of truth for "who can do what."

|Role|Scope|Example Grant|
|---|---|---|
|Customer|Own resources only (`userId` match)|Manage own cart, orders, wishlist|
|Support Agent|Read + limited write across customer-facing services|View any order, issue a refund up to a capped amount|
|Admin|Full back-office operations|Catalog management, coupon issuance, user suspension — all `/admin/*` routes|
|Partner API|Scoped, non-interactive|Bulk catalog upload, order status webhook — client-credentials flow only|

- **Issuance**: Identity Service resolves a user/service-principal to a role set at token-mint time and embeds it as a scoped claim in the JWT (`roles: [...]`, `scopes: [...]`) — this is the same JWT already described in §24 AuthZ, not a separate token.
- **Enforcement**: checked twice — coarse-grained at the API Gateway (§18, reject before the request reaches a service) and fine-grained again at the owning service (e.g., "Support Agent can refund, but only up to $X" is a business rule Payment Service enforces itself, since the gateway cannot know the order total).
- **Why not per-service role tables**: with 20 independently-deployed services, a locally-defined role table per service silently drifts (Admin's "Support" role and Order's "Support" role diverge in meaning within a year). One issuer + one claim shape is what makes RBAC auditable across the whole platform.

### 24.2 SSO / Identity Federation

Two distinct SSO needs, both fronted by Identity Service so downstream services never talk to an external IdP directly:

|Audience|Federation Protocol|Why|
|---|---|---|
|Admin / back-office users|SAML 2.0 or OIDC against the org's enterprise IdP (Okta/Azure AD/Google Workspace)|Back-office staff already have a corporate identity; forcing a separate Kart-only password is both worse security (one more credential to phish/leak) and worse UX|
|Customers|OIDC social login (Google/Apple/etc.) alongside native email/password|Reduces signup friction; still lands on the same Identity Service token issuance path, so RBAC/AuthZ downstream is identical regardless of how the user authenticated|

Federation is terminated entirely at Identity Service — it exchanges the external IdP's assertion/token for Kart's own short-lived JWT (per §24 Token Lifecycle) carrying Kart-native role claims. No other service ever validates a SAML assertion or holds an external IdP client secret; this keeps the PCI/compliance-relevant blast radius (§5.3 Boundary Rationale) and the IdP integration surface both contained to one service.

---

## 25. Load Testing

|Tier|RPM|Focus|Expected Outcome|
|---|---|---|---|
|100 RPM|Smoke|Baseline correctness|All green, negligible latency|
|1K RPM|Functional load|No errors, stable P99|Confirms code path correctness under light concurrency|
|100K RPM|Realistic peak|Redis/DB connection pool behavior|Identify first bottleneck (usually DB connection saturation)|
|1M RPM|Stress|Autoscaling triggers, queue depth|HPA scales consumers, cache hit ratio becomes critical|
|Extreme (flash sale)|10M+ RPM|Breaking point discovery|Deliberately find where the system degrades and _how_ it degrades (graceful vs. cascading)|

**Reports** should capture: P50/P95/P99 latency, error rate, throughput achieved vs. target, resource saturation point (CPU/DB connections/queue depth), and time-to-recovery after load subsides.

---

## 26. Chaos Engineering

|Experiment|Hypothesis|Observed Behavior To Validate|
|---|---|---|
|Kill a random Order Service pod mid-request|Client sees a retryable error, no data corruption|Load balancer routes around dead pod within seconds|
|Saturate RabbitMQ queue depth artificially|HPA scales consumers before DLQ fills|Queue depth metric drives autoscale before message loss|
|Introduce PostgreSQL replica lag|Read replicas serve slightly stale data without crashing callers|Read path tolerates staleness within documented SLA|
|Drop 20% of packets between services|Circuit breakers open, fallback responses served|No cascading failure across unrelated services|

---

## 27. System Design Interview Questions

**Architecture & Boundaries**

1. Why split Order and Inventory into separate services instead of one?
2. How would you decide a service boundary in general?
3. What's the risk of an "Order Service" that directly calls Payment synchronously for everything?
4. Why is Order the Saga orchestrator instead of a separate "Orchestrator Service"?
5. When would you choose a monolith over these 20 services?

**CQRS & Data** 6. Why is PostgreSQL the write store and MongoDB the read store here? 7. What breaks if the Outbox poller goes down for an hour? 8. How do you rebuild a MongoDB read model from scratch? 9. Why denormalize category name into the product read model instead of joining? 10. What's the risk of eventual consistency on the search index for a price change? 11. How would you shard MongoDB differently if products were region-specific? 12. Why partition PostgreSQL `orders` by month instead of by user ID range?

**Messaging** 13. Why a topic exchange instead of a direct exchange in RabbitMQ? 14. Walk through what happens when a consumer crashes mid-message. 15. Why does Payment get 5 retries but Notification gets 1? 16. Design the DLQ strategy for a payment failure that keeps failing after all retries. 17. What's the delayed-retry ladder pattern and why not just requeue immediately? 18. Why is the message topology JSON-configured instead of imperatively coded? 19. What happens to in-flight messages during a RabbitMQ node restart? 20. How do you guarantee exactly-once processing when RabbitMQ only guarantees at-least-once?

**Kafka Migration** 21. Why does RabbitMQ break down under the Analytics replay requirement? 22. Why not put transactional Order events on Kafka too, for consistency? 23. Explain the dual-publish strangler migration strategy and its risks. 24. What does Kafka partitioning buy you that a RabbitMQ queue doesn't? 25. How would you validate the Kafka migration didn't drop any events?

**Saga & Failure** 26. Walk through the compensation flow when Payment fails after Inventory is reserved. 27. What happens if the compensation call (release inventory) itself fails? 28. How is this different from a two-phase commit, and why not use 2PC here? 29. Design a saga for a partial refund that only covers 2 of 5 items in an order. 30. How do you detect a saga that's stuck halfway forever?

**Caching** 31. Why cache-aside for products but write-through for promotions? 32. How do you avoid serving a stale price after a flash-sale price change? 33. Design a solution for a hot key during a flash sale. 34. What's the cache stampede problem and how would you prevent it here?

**Scalability & Capacity** 35. Walk through capacity planning from 1M DAU to required RPS. 36. Why is the read:write ratio relevant to database choice? 37. How would P99 latency budget change your architecture for the order path? 38. What's the first component that breaks at 10x normal traffic, and why?

**Reliability & Chaos** 39. Design a chaos experiment to validate the circuit breaker on the Payment call. 40. What's the blast radius if Redis goes down entirely? 41. How does the system behave if PostgreSQL is available but at 5-second query latency? 42. Explain graceful degradation vs. cascading failure with an example from this system.

**Security** 43. Why validate JWT at the gateway _and_ re-check scopes at the service? 44. Why does Payment never store raw card data? 45. Design the idempotency key mechanism end-to-end for charge requests.

**Observability** 46. Why is structured logging necessary for a system with 20 services? 47. How would you trace a single slow order across 8 services? 48. What business metrics would you alert on, versus purely technical metrics?

_(Questions 49–100 follow the same structure across DevOps/Kubernetes, Search/Recommendation, Notification fan-out design, database indexing trade-offs, rate limiting algorithms, and multi-region/DR scenarios — generate additional questions by taking any section 5–26 heading and asking "why this, and what's the alternative?")_

---

## 28. Learning Matrix

|Feature|Concept|Skill Level|
|---|---|---|
|RabbitMQ topology|Messaging|Intermediate|
|Config-driven message bus|Infrastructure-as-Config|Advanced|
|Outbox Pattern|Distributed Transactions|Advanced|
|Saga Pattern|Distributed Transactions|Advanced|
|CQRS (PG → Mongo)|Data Architecture|Advanced|
|MongoDB Sharding|Horizontal Scaling|Advanced|
|PostgreSQL Partitioning|Database Performance|Intermediate|
|Idempotency Keys|Reliability|Intermediate|
|Circuit Breaker|Fault Tolerance|Intermediate|
|Kafka Migration|Messaging Evolution|Advanced|
|Redis Cache-Aside/Write-Through|Caching Strategy|Intermediate|
|Kubernetes HPA on Queue Depth|DevOps / Autoscaling|Advanced|
|Distributed Tracing|Observability|Advanced|
|Chaos Engineering|Reliability Engineering|Advanced|
|JWT + OAuth2|Security|Intermediate|
|Load Testing at Scale|Performance Engineering|Advanced|
|API Gateway Rate Limiting|Traffic Management|Intermediate|
|Denormalized Read Models|Data Modeling|Intermediate|

---

## How to Use This Document

1. **Mentor review**: use Sections 1–4 to validate scope/ambition, Section 27 to spot-check understanding.
2. **Implementation**: build in the order the sections appear — services (5) before messaging (8–15) before infra (18–22) before chaos (26), since each layer assumes the previous one exists.
3. **Interview prep**: treat every "Why this, not that?" in Sections 5–17 as a flashcard.