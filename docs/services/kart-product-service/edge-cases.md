---
doc_type: edge-cases
service: kart-product-service
status: pending-approval
generated_by: edge-case-analyzer-agent
source: docs/services/kart-product-service/requirement-spec.md
---

# Edge Cases: kart-product-service

## Edge Case: Variant/attribute schema drift breaks downstream consumers

- **What happens:** A change to the variant/attribute shape (new attribute type, restructured variant-to-SKU linkage) silently breaks Search's indexing, Recommendation's feature extraction, or Wishlist's stored snapshot.
- **Why it happens:** requirement-spec.md Open Questions #3 — the BRD gives zero schema detail for variants/attributes, yet `ProductCreated` fans out to Search and Recommendation (requirement-spec §5) with no stated contract test.
- **Solutions available (3):** Schema registry with versioned/compat-checked payloads · Additive-only schema evolution convention enforced by consumer contract tests · Per-consumer projection/adapter layer translating the canonical schema per consumer.
- **Decision (3-5 bullets max):**
  - Chosen: Additive-only evolution + consumer contract tests.
  - Why: matches the platform NFR "Maintainability: contract-tested APIs, versioned events" (BRD §3) without waiting on the still-unresolved variant/attribute schema itself.
  - Trade-off accepted: doesn't prevent a genuinely breaking model change (e.g. removing a field) — only makes it a caught contract-test failure instead of a silent runtime break.

## Edge Case: Out-of-order `ProductPriceChanged` delivery under concurrent price edits

- **What happens:** Two price updates to the same SKU in quick succession publish two `ProductPriceChanged` events; a consumer (Search, Wishlist, Pricing) processes them out of order and ends up acting on the older price as if it were current.
- **Why it happens:** BRD §14 states RabbitMQ has no per-key ordering guarantee at scale ("No log-based partitioned parallelism"); requirement-spec's invariant that read models must reflect the canonical price has nothing enforcing delivery order.
- **Solutions available (3):** Monotonic version/timestamp on the payload, consumers reject stale versions · Move the event to a Kafka topic partitioned by SKU for per-key ordering (per BRD §15) · Force serial processing per SKU via a single dedicated queue/consumer thread.
- **Decision (3-5 bullets max):**
  - Chosen: Version/timestamp on payload + consumer-side stale-version check.
  - Why: works immediately on RabbitMQ; BRD §15's Kafka migration is explicitly scoped to Analytics/Recommendation first, not catalog events, so waiting on it would block this indefinitely.
  - Trade-off accepted: no strict global ordering guarantee — a consumer can transiently show a stale price until the newer event lands, only guaranteed to never regress once it has the newest.

## Edge Case: Read-model staleness after a price change, compounded by the Redis cache

- **What happens:** Between a price-change committing in PostgreSQL and the Outbox → RabbitMQ → MongoDB projection completing, a customer can still see a stale price on `GET /products/{id}`, because cache invalidation itself rides the same event pipeline it's supposed to protect against.
- **Why it happens:** CQRS's stated eventual-consistency window (BRD §7) stacks with the cache-aside + explicit-invalidation pattern (BRD §16) — invalidation is event-driven, so it races the same projection lag rather than being synchronous with the DB commit.
- **Solutions available (3):** Write-through cache for price fields specifically, synchronous with the DB write · Short TTL on price-bearing cache entries as a hard staleness bound · Accept eventual consistency, surface a "price as of" timestamp to the client.
- **Decision (3-5 bullets max):**
  - Chosen: Write-through for price fields, mirroring BRD's own Promotion caching pattern (§16).
  - Why: BRD explicitly distinguishes cache-aside (general product reads) from write-through (promotion/pricing-sensitive flags) on exactly this staleness-intolerance basis — price falls in the latter bucket by the BRD's own logic.
  - Trade-off accepted: added write latency on every price-changing write path versus fire-and-forget cache-aside.

## Edge Case: High fan-out on every publish risks one slow consumer blocking others

- **What happens:** A single `ProductCreated`/`ProductPriceChanged` publish must reach Search, Recommendation, Wishlist, and Pricing (requirement-spec §2, §5); during a catalog bulk-load or price sweep, one slow consumer (e.g. Search re-indexing) backs up without affecting others — but BRD §10 gives both events one shared `catalog.dlq`.
- **Why it happens:** BRD §14 names this exact failure mode generally ("Throughput ceiling under heavy fan-out... 10+ consumer groups per event multiplies effective message rate").
- **Solutions available (3):** Per-consumer-group queue and DLQ under the shared topic exchange (BRD §8's stated default topology) · Single shared queue fanned to all consumers · Move high-fan-out catalog events to Kafka ahead of the general Analytics-first migration order (BRD §15).
- **Decision (3-5 bullets max):**
  - Chosen: Per-consumer-group queue/DLQ under `ecommerce.events`.
  - Why: this is already the platform's stated default (BRD §8: "Queue per Consumer Group... Each service owns its own queue"; §8.3 explicitly rejects the shared-queue option: "one slow consumer blocks all others").
  - Trade-off accepted: still bounded by RabbitMQ's overall fan-out throughput ceiling (BRD §14) — only defers, doesn't eliminate, an eventual Kafka move for catalog events if volume grows enough.

## Edge Case: Concurrent read-model writes clobber the denormalized document

- **What happens:** A `ProductPriceChanged` projection and a rating-recalc write (if requirement-spec Open Questions #2 resolves to "Product consumes `ReviewSubmitted`") can target the same `product_read_model` document concurrently; a naive full-document overwrite from one projector can clobber the other's fields.
- **Why it happens:** BRD §6.2's denormalized document embeds price and `ratingSummary` together with no stated concurrency control, and the two fields are written by two independently-triggered projections.
- **Solutions available (3):** Field-scoped partial updates per projector (`$set` only owned fields) · Optimistic concurrency via a document version field with retry-on-conflict · Split rating summary into its own document/collection, joined at read time.
- **Decision (3-5 bullets max):**
  - Chosen: Field-scoped partial updates, each projector touching only the fields its event owns.
  - Why: cheapest option; avoids reintroducing the cross-shard join BRD §6.2 denormalized specifically to avoid, and matches the platform's "idempotent consumers" NFR (BRD §3).
  - Trade-off accepted: doesn't solve a true same-field race (two writers to the identical field) — acceptable here since price and rating are written by disjoint event types, not the same one.

## Edge Case: SKU uniqueness enforcement at 100M-SKU scale with category-based sharding

- **What happens:** A duplicate SKU can be created (concurrent creation requests, or a migration collision) without being caught, because the read model's Mongo shard key is `category.id` (BRD §6.2), not SKU — so a single-shard unique index can't arbitrate uniqueness the way it could under a SKU-based shard key.
- **Why it happens:** requirement-spec's SKU-uniqueness invariant is inferred, not BRD-stated; the BRD's shard key choice optimizes browse-query locality, not write-side uniqueness enforcement.
- **Solutions available (3):** Unique constraint on the PostgreSQL write-side table, enforced before any Mongo projection · Separate SKU-keyed lookup collection dedicated to uniqueness checks · Accept eventual detection via a reconciliation job.
- **Decision (3-5 bullets max):**
  - Chosen: Unique constraint on the PostgreSQL write side.
  - Why: PostgreSQL is the stated source of truth for writes (BRD §6.1); a single-node ACID constraint enforces this without touching the read model's sharding strategy at all.
  - Trade-off accepted: doesn't protect against SKU reuse/rename after the fact or cross-region write conflicts — out of scope, since the BRD states no multi-region write requirement for Product.
