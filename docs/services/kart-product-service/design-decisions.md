---
doc_type: design-decisions
service: kart-product-service
status: draft
generated_by: design-decision-agent
sources:
  - docs/services/kart-product-service/requirement-spec.md
  - docs/services/kart-product-service/edge-cases.md
---

# Design Decisions: kart-product-service

Cross-cutting technology/design-pattern choices this service's requirement-spec.md and edge-cases.md force. Several decisions here generalize a fix already chosen in edge-cases.md into a named pattern — those are cited, not re-derived. Boundary/aggregate/schema decisions are explicitly left to the Architecture, DDD, and Database Design Agents that follow this stage.

## Decision: Communication Style for Catalog Writes and Downstream Propagation

- **Requirement driving this:** requirement-spec §5 (API Surface) resolves the previously-missing write API as synchronous `POST /products` / `PUT`/`PATCH /products/{id}` endpoints, called by Admin's `/admin/*` surface and the Partner API (BRD §24.1); the same catalog changes fan out asynchronously to Search, Recommendation, Wishlist, Offer/Pricing, and Analytics via `ProductCreated`/`ProductPriceChanged`/`ProductUpdated`/`ProductDiscontinued` (§2, §5).
- **Options considered (3):** Fully synchronous REST/gRPC for both the write path and every downstream consumer update · Fully asynchronous command-bus for the write path itself (no synchronous response to the caller) · Hybrid — synchronous REST for the write request/response, asynchronous RabbitMQ events for downstream fan-out (the shape requirement-spec §2/§5 already assumes).
- **Decision:**
  - Chosen: Hybrid — synchronous REST for `POST`/`PUT`/`PATCH /products/{id}` (Admin/Partner API get an immediate response), asynchronous events for every downstream consumer.
  - Why: BRD §24.1's Admin/Partner role grants require a synchronous create/update response; blocking that response on all five downstream consumers would tie write-path latency to the slowest fan-out consumer, contradicting the read-heavy/write-independent Throughput NFR (§3) and the platform's standing CQRS eventual-consistency default (BRD §7).
  - Trade-off accepted: a caller's success response precedes full downstream consistency — the same eventual-consistency window the platform already accepts everywhere else, not a new instance of it.

## Decision: Schema Evolution & Contract Testing for Variant/Attribute Payloads

- **Requirement driving this:** BRD §3 Maintainability NFR ("contract-tested APIs, versioned events"); edge-cases.md "Variant/attribute schema drift breaks downstream consumers" (a change to the hybrid EAV/JSONB variant/attribute shape — a new attribute type, or a restructured variant-to-SKU linkage — can silently break Search's indexing, Recommendation's feature extraction, or Wishlist's stored snapshot).
- **Options considered (3):** Schema registry with versioned/compatibility-checked payloads (Avro/Protobuf-style) · Additive-only schema evolution convention enforced by consumer contract tests · Per-consumer projection/adapter layer translating the canonical schema per consumer.
- **Decision:**
  - Chosen: Additive-only schema evolution + consumer contract tests — generalizes the fix already made in edge-cases.md.
  - Why: satisfies the platform's Maintainability NFR (§3) without the heavier schema-registry machinery a service at Product's current event volume/volatility doesn't yet need; a CI-time contract test between Product and each of Search/Recommendation/Wishlist catches a breaking payload change before it reaches production instead of failing silently at runtime.
  - Trade-off accepted: doesn't prevent a genuinely breaking change (e.g. removing or repurposing a field) — only converts a silent runtime break into a caught contract-test failure; a full schema-registry approach (the heavier option Analytics chose for its own higher fan-in volume) would need revisiting if catalog event volume/volatility grows enough to justify it.

## Decision: Caching Strategy for Product Reads

- **Requirement driving this:** NFR §3 Latency (P95 < 150ms, P99 < 400ms read path); requirement-spec's "Read-model / caching integration" section (Redis cache-aside + explicit price-change invalidation, BRD §16); edge-cases.md "Read-model staleness after a price change, compounded by the Redis cache."
- **Options considered (3):** Pure cache-aside with TTL for every field, including price · Pure write-through for the entire product document · Hybrid — cache-aside with TTL for general product fields, write-through (synchronous with the DB write) for price-bearing fields only.
- **Decision:**
  - Chosen: Hybrid cache-aside (general fields) + write-through (price fields) — generalizes the fix already made in edge-cases.md ("Read-model staleness after a price change").
  - Why: mirrors BRD §16's own distinction between cache-aside (general reads) and write-through (promotion/pricing-sensitive flags) on exactly the staleness-intolerance basis price falls into; a TTL-only approach can't bound the price-staleness window the checkout-price-race edge case depends on Product having already closed.
  - Trade-off accepted: added write latency on every price-changing write versus the lower-latency fire-and-forget cache-aside used for every other field (already accepted in edge-cases.md).

## Decision: Concurrency Control for Concurrent Read-Model Projection Writes

- **Requirement driving this:** edge-cases.md "Concurrent read-model writes clobber the denormalized document" (a `ProductPriceChanged` projection and a `ReviewSubmitted`-driven rating recalc can target the same `product_read_model` document concurrently); domain invariant §4 that the read model must remain rebuildable from replayed events without data loss.
- **Options considered (3):** Field-scoped partial updates (`$set` only the fields each projector owns) · Optimistic concurrency via a document version field with retry-on-conflict · Split rating summary into its own document/collection, joined at read time.
- **Decision:**
  - Chosen: Field-scoped partial updates, each projector touching only the fields its event owns — generalizes the fix already made in edge-cases.md.
  - Why: cheapest option that avoids reintroducing the cross-shard join BRD §6.2 denormalized specifically to avoid, and matches the platform's idempotent-consumers NFR (§3); price and rating are written by disjoint event types, not the same field, so full optimistic-locking machinery isn't forced here.
  - Trade-off accepted: doesn't solve a genuine same-field concurrent write (two writers to the identical field) — acceptable since no such case exists in this service's current event model; would need revisiting if a future projector shares a field with an existing one.

## Decision: Concurrency Control for SKU Uniqueness at Write Time

- **Requirement driving this:** domain invariant §4 ("every SKU is presumed unique across the catalog"); edge-cases.md "SKU uniqueness enforcement at 100M-SKU scale with category-based sharding" (the MongoDB read model's `category.id` shard key can't arbitrate uniqueness the way a SKU-based shard key could).
- **Options considered (3):** Unique constraint on the PostgreSQL write-side table, enforced before any Mongo projection · Separate SKU-keyed lookup collection dedicated to uniqueness checks · Accept eventual detection via a reconciliation job.
- **Decision:**
  - Chosen: Synchronous PostgreSQL unique constraint on the variant/SKU write-side table — generalizes the fix already made in edge-cases.md.
  - Why: PostgreSQL is the stated source of truth for writes (BRD §6.1); a single-node ACID constraint enforces uniqueness synchronously at `POST /products` / `PUT`/`PATCH /products/{id}` time without touching the read model's `category.id` sharding strategy at all.
  - Trade-off accepted: doesn't protect against SKU reuse/rename after the fact or cross-region write conflicts — accepted, since the BRD states no multi-region write requirement for Product.

## Decision: Idempotency & Ordering Mechanism for Price-Change Event Consumption

- **Requirement driving this:** NFR §3 Reliability ("at-least-once delivery + idempotent consumers"); edge-cases.md "Out-of-order `ProductPriceChanged` delivery under concurrent price edits" (BRD §14: RabbitMQ has no per-key ordering guarantee at scale).
- **Options considered (3):** Monotonic version/timestamp on the payload, consumers reject stale versions · Move the event to a Kafka topic partitioned by SKU for per-key ordering (BRD §15) · Force serial processing per SKU via a single dedicated queue/consumer thread.
- **Decision:**
  - Chosen: Version/timestamp on the `ProductPriceChanged` payload + consumer-side stale-version rejection — generalizes the fix already made in edge-cases.md.
  - Why: works immediately on the platform's current RabbitMQ topology; BRD §15's Kafka migration is explicitly scoped to Analytics/Recommendation first, not catalog events, so gating this decision on that migration would block it indefinitely.
  - Trade-off accepted: no strict global ordering guarantee across consumers — a consumer can transiently act on a stale price until the newer event lands, only guaranteed to never regress once it has processed the newest version.

## Decision: Resilience Pattern — Bulkhead Isolation for High-Fan-Out Catalog Events

- **Requirement driving this:** BRD §14's named failure mode ("throughput ceiling under heavy fan-out... 10+ consumer groups per event multiplies effective message rate"); edge-cases.md "High fan-out on every publish risks one slow consumer blocking others" (`ProductCreated`/`ProductPriceChanged` reach five consumer groups — Search, Recommendation, Wishlist, Offer/Pricing, Analytics). This also reconciles requirement-spec's NFR table row ("3x retry, `catalog.dlq`") with the more specific topology below: the NFR row states the retry-count/DLQ *tier*, this decision states how that tier is topologically realized per consumer group, not as one literal shared queue.
- **Options considered (3):** Per-consumer-group queue and DLQ under the shared topic exchange (BRD §8's stated platform default) · Single shared queue fanned out to all consumers, with one shared `catalog.dlq` · Move high-fan-out catalog events to Kafka ahead of the general Analytics-first migration order (BRD §15).
- **Decision:**
  - Chosen: Per-consumer-group queue + DLQ under `ecommerce.events` (bulkhead isolation) — generalizes the fix already made in edge-cases.md.
  - Why: already the platform's stated default (BRD §8: "Queue per Consumer Group... each service owns its own queue"; §8.3 explicitly rejects the shared-queue option because "one slow consumer blocks all others").
  - Trade-off accepted: still bounded by RabbitMQ's overall fan-out throughput ceiling (BRD §14) — this only defers, not eliminates, an eventual Kafka move for catalog events if volume grows enough.

## Not Decided Here

- **Serialization format for events/payloads** — neither requirement-spec.md nor edge-cases.md states a service-specific forcing requirement beyond the platform's existing event-schema-versioning default (`agent-reusables/docs/standards/event-standards.md`, resolved via this repo's `reusables.config.json`); no divergence reason exists, so nothing to add here.
- **Aggregate boundary for Variant vs. Product**, the concrete hybrid EAV/JSONB table/column shapes, and `ProductDiscontinued`'s formal domain-event status — explicitly left to the DDD Agent per requirement-spec §2/§6, not re-decided here.
- **Rating-projection staleness bound** and **audit/rollback depth beyond the replayable event stream** — carried-forward, non-blocking items per requirement-spec §6 (items 7–8), owned by the Architecture Agent, not a design-pattern choice this stage can ground.

## Sign-off

- [ ] Reviewed by: _pending human review_
- [ ] Approved to proceed to Architecture Agent
