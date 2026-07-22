---
doc_type: edge-cases
service: kart-product-service
status: approved
generated_by: edge-case-analyzer-agent
source: docs/services/kart-product-service/requirement-spec.md
---

# Edge Cases: kart-product-service

## Edge Case: Variant/attribute schema drift breaks downstream consumers

- **What happens:** A change to the variant/attribute shape (new attribute type, restructured variant-to-SKU linkage) silently breaks Search's indexing, Recommendation's feature extraction, or Wishlist's stored snapshot.
- **Why it happens:** requirement-spec.md now defines a concrete hybrid EAV/JSONB schema (formerly Open Questions #3, resolved), but having a concrete baseline schema doesn't prevent it from *evolving* later — a category needing a new first-class indexed attribute, or a restructured variant-to-SKU linkage, still fans out to Search and Recommendation (requirement-spec §5) with no stated contract test.
- **Solutions available (3):** Schema registry with versioned/compat-checked payloads · Additive-only schema evolution convention enforced by consumer contract tests · Per-consumer projection/adapter layer translating the canonical schema per consumer.
- **Decision (3-5 bullets max):**
  - Chosen: Additive-only evolution + consumer contract tests.
  - Why: matches the platform NFR "Maintainability: contract-tested APIs, versioned events" (BRD §3) and protects the now-concrete variant/attribute schema (requirement-spec's "Variant & Attribute Data Model") from silently breaking consumers as it evolves.
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

- **What happens:** A single `ProductCreated`/`ProductPriceChanged` publish must reach Search, Recommendation, Wishlist, Offer/Pricing, and Analytics (requirement-spec §2, §5 — Analytics per ADR-0004's full fan-in default); during a catalog bulk-load or price sweep, one slow consumer (e.g. Search re-indexing) backs up without affecting others — but BRD §10 gives both events one shared `catalog.dlq`.
- **Why it happens:** BRD §14 names this exact failure mode generally ("Throughput ceiling under heavy fan-out... 10+ consumer groups per event multiplies effective message rate").
- **Solutions available (3):** Per-consumer-group queue and DLQ under the shared topic exchange (BRD §8's stated default topology) · Single shared queue fanned to all consumers · Move high-fan-out catalog events to Kafka ahead of the general Analytics-first migration order (BRD §15).
- **Decision (3-5 bullets max):**
  - Chosen: Per-consumer-group queue/DLQ under `ecommerce.events`.
  - Why: this is already the platform's stated default (BRD §8: "Queue per Consumer Group... Each service owns its own queue"; §8.3 explicitly rejects the shared-queue option: "one slow consumer blocks all others").
  - Trade-off accepted: still bounded by RabbitMQ's overall fan-out throughput ceiling (BRD §14) — only defers, doesn't eliminate, an eventual Kafka move for catalog events if volume grows enough.

## Edge Case: Concurrent read-model writes clobber the denormalized document

- **What happens:** A `ProductPriceChanged` projection and a rating-recalc write (Product consumes `ReviewSubmitted` and `ReviewUpdated` — requirement-spec Open Questions #2, resolved via ADR-0014 (`docs/adr/0014-review-rating-aggregate-ownership.md`)) can target the same `product_read_model` document concurrently; a naive full-document overwrite from one projector can clobber the other's fields.
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

## Edge Case: Discontinued/orphaned variant leaves no read-model transition or event signal

- **What happens:** A variant (or an entire SKU) is discontinued or removed from active sale while it is still referenced by outstanding `product_read_model` documents, in-flight carts/orders, or downstream caches (Search index, Redis) — and Product has no defined write path or event to signal that transition at all.
- **Why it happens:** requirement-spec's API Surface / Event Catalog (§5) originally defined only `ProductCreated`/`ProductPriceChanged`, with no discontinuation/removal event — resolved: `ProductUpdated` is now a defined event (formerly Open Questions #6) and the variant/attribute schema now concretely places a `status` field (`active`/`discontinued`) on the variant row (formerly Open Questions #3, see requirement-spec's "Variant & Attribute Data Model"). A hard delete would still violate the domain invariant that "the MongoDB read model must always be rebuildable from the PostgreSQL write side plus replayed events" (§4), since a `ProductCreated`/`ProductPriceChanged` history can't be replayed for a variant that no longer exists anywhere — that reasoning holds regardless of the schema ambiguity now being closed.
- **Solutions available (3):** Soft-delete via a `status` field on the variant at the write side (never hard-deleted) plus a new `ProductDiscontinued` event, projected into the read model as a status flag rather than a document removal · Hard-delete at the write side with no new event, leaving every downstream consumer to independently discover the absence · Leave the write side and read model untouched indefinitely and push all "still sellable" filtering upstream into Search/Category with no signal from Product at all.
- **Decision (3-5 bullets max):**
  - Chosen: Soft-delete via the variant row's `status` field + a new `ProductDiscontinued` event — a proposed addition, not in the BRD's Event Catalog, flagged per this platform's existing precedent for proposing new events (kart-offer-service ddd-model.md's `CouponRedemptionVoided`/`PromotionDeactivated`), not silently invented.
  - Why: a hard delete directly breaks the stated CQRS rebuildability invariant (§4); a status flag is the only one of the three options that keeps history replayable while still giving downstream consumers something concrete to react to instead of silence — and two independent downstream specs are already blocked on exactly this signal: kart-wishlist-service's requirement-spec (Open Question #8, "no product-removal/discontinuation event feed") and kart-search-service's requirement-spec (Open Question #4, "no product-removal/delisting event is named").
  - Trade-off accepted: this is a proposed new event, not a BRD-stated one, so it needs the same review Offer's proposed events got before being treated as final. Its field shape is now settled (the variant row's `status` column, per requirement-spec's "Variant & Attribute Data Model") — the remaining open item is formal DDD Agent sign-off on `ProductDiscontinued` itself as a first-class domain event, the same formalization step ADR-0008 later gave Offer's proposed events.
  - Cross-service note: this is the missing input both kart-wishlist-service's edge-cases.md ("Stale Wishlist Entry for a Discontinued Product," currently unresolved there) and kart-search-service's requirement-spec Q4 are waiting on — publishing `ProductDiscontinued` unblocks them, but each of those docs still needs its own follow-up pass to actually consume it; not resolved by this document.

## Edge Case: Price change races an in-progress cart/checkout

- **What happens:** A customer adds an item to a cart, or begins checkout, while a SKU's price is P; `ProductPriceChanged` fires (price moves to P′) before checkout completes — raising the question of whether the customer is ultimately charged P or P′.
- **Why it happens:** Domain Invariant §4 states "Product owns the canonical/base list price; Pricing only computes derived quotes... and never announces base price changes," and Product's write path commits/propagates price changes immediately (NFR §3, Consistency: "Strong (PostgreSQL write path)") with zero visibility into carts or checkouts — requirement-spec's API Surface (§5) names no Cart/Checkout-facing endpoint or consumed event for Product at all — so nothing in this service is positioned to decide whose price a checkout should honor.
- **Solutions available (3):** Product delays/withholds publishing `ProductPriceChanged` or updating its own read model until in-flight carts referencing the SKU clear · Product always reflects/publishes the committed canonical price immediately — exactly the write-through decision already made above in "Read-model staleness after a price change" — and leaves the honor-old-or-new-price decision entirely to whichever layer snapshots price at commitment time · Product exposes a price-history/versioned lookup so a downstream service could reconstruct "price as of time T" itself.
- **Decision (3-5 bullets max):**
  - Chosen: Product always publishes/reflects the new canonical price immediately — no new behavior beyond the write-through decision already made above. The checkout-honoring question itself is out of scope for this document.
  - Why: this race is already resolved one layer up. kart-offer-service's approved `ddd-model.md` models `PricingQuote` as an immutable snapshot with a 15-minute TTL ("a quote reflects the product price... at the moment of quoting — never recomputed retroactively"), and its own `edge-cases.md` explicitly treats a quote issued moments before a `ProductPriceChanged` lands as "correct by definition, not a defect." Re-deciding it inside Product would duplicate an already-approved decision with a worse tool: Product has no visibility into which carts/checkouts reference a given SKU, so delaying or gating its own canonical-price write on their behalf has no defined stop condition.
  - Trade-off accepted: Product's only real obligation in this race is what it already commits to elsewhere in this document — immediate, consistent canonical-price propagation (write-through cache; versioned/timestamped event payload per the out-of-order edge case above). Whether the customer is ultimately charged P or P′ is decided by `PricingQuote`'s snapshot-and-TTL semantics at the Offer layer, not here.
  - Not escalating further: unlike the previous edge case, this isn't a gap needing a human decision — it's a scope boundary, confirmed by an already-approved upstream design (kart-offer-service's `ddd-model.md`/`edge-cases.md`), that this document is stating explicitly rather than silently assuming.
