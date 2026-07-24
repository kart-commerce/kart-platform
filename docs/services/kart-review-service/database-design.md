---
doc_type: database-design
service: kart-review-service
status: approved
generated_by: database-design-agent
source: docs/services/kart-review-service/ddd-model.md, docs/services/kart-review-service/architecture.md, docs/services/kart-review-service/design-decisions.md, docs/adr/0021-review-verified-purchase-order-created-dependency.md, docs/adr/0016-user-gdpr-erasure-policy.md
---

# Database Design: kart-review-service

Write model is PostgreSQL, the source of truth for all three of ddd-model.md's write boundaries (`Review`, `ProductRating`, `VerifiedPurchaseRecord`) — none of the three is ever required to commit atomically with another (ddd-model.md's transaction-boundary test), so each gets its own table(s), not one merged schema. Read model is MongoDB for `Review` only (BRD §5.4: "PostgreSQL → MongoDB read"; `GET /reviews?sku=...` per requirement-spec §5 is served exclusively from there, never from PostgreSQL directly). `ProductRating` gets **no** MongoDB projection — see Read Model below for why a direct PostgreSQL read already clears the read-path budget. `VerifiedPurchaseRecord` is a synchronous-read-only local projection with no API surface of its own at all; nothing ever reads it except `POST /reviews`'s own gate check.

## Write Model (PostgreSQL)

```sql
-- Review aggregate root (ddd-model.md)
CREATE TABLE reviews (
    review_id           UUID PRIMARY KEY,
    order_id             UUID NOT NULL,             -- reference, kart-order-service
    sku                  TEXT NOT NULL,              -- reference, kart-product-service
    user_id              UUID NOT NULL,              -- reference, kart-identity-service (the author)
    rating               SMALLINT NOT NULL CHECK (rating BETWEEN 1 AND 5),   -- Rating value object (1..5, engineering default, ddd-model.md)
    body_text            TEXT NOT NULL,
    status               VARCHAR(20) NOT NULL
                             CHECK (status IN ('PendingModeration', 'Published', 'Rejected', 'Retracted')),
    pending_revision     JSONB NULL,                 -- PendingRevision value object: { newBodyText, newRating, submittedAt } — at most one at a time, overwritten in place, never a queue (ddd-model.md Invariant)
    first_published_at   TIMESTAMPTZ NULL,           -- set exactly once; drives every ReviewSubmitted/ReviewUpdated/ReviewUnpublished firing decision (ddd-model.md Modeling Decision 6)
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_edited_at        TIMESTAMPTZ NOT NULL DEFAULT now(),  -- this table's updated_at under BRD §24.3, in the domain's own vocabulary
    retracted_at          TIMESTAMPTZ NULL,
    idempotency_key       TEXT NOT NULL,             -- creation-request dedup only, see Idempotency-Key Replay Window below
    created_by            TEXT NOT NULL,             -- BRD §24.3 -- always the owning userId; every insert is the author's own POST /reviews submission
    updated_by            TEXT NOT NULL,             -- BRD §24.3 -- the owning userId for a self-service edit/retraction, or the moderating Support Agent's/Admin's own userId for an accept/reject/takedown via PATCH /reviews/{id}/moderate (ddd-model.md's audit-actor invariant)
    UNIQUE (order_id, sku),                          -- one Review per (order, sku), PERMANENT — never released even in a terminal state
                                                       -- (requirement-spec §4/§6 Q6; ddd-model.md Modeling Decision 8's occupancy consequence)
    UNIQUE (idempotency_key)                          -- mirrors kart-order-service's simpler global-unique pattern, not Payment's
                                                       -- reserve/confirm ledger (ddd-model.md Modeling Decision 2) — PATCH retries need
                                                       -- no separate dedup record, since re-applying identical content or re-invoking the
                                                       -- classifier has no harmful side effect to guard against
);

-- Backstops the Monotonic terminal states invariant (ddd-model.md): no transition of any kind is
-- legal out of Rejected or Retracted, in either direction between them. Mirrors
-- kart-payment-service's own PaymentIntentStatus trigger-guard precedent — a coding-bug backstop,
-- not the primary enforcement (that is the application layer's guarded-no-op handling of a repeat
-- moderator/retraction action).
CREATE OR REPLACE FUNCTION enforce_review_status_transition() RETURNS trigger AS $$
BEGIN
    IF OLD.status IN ('Rejected', 'Retracted') AND NEW.status <> OLD.status THEN
        RAISE EXCEPTION 'illegal ModerationStatus transition: % is terminal, cannot move to %', OLD.status, NEW.status;
    END IF;
    NEW.last_edited_at := now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_reviews_status_guard
    BEFORE UPDATE OF status ON reviews
    FOR EACH ROW EXECUTE FUNCTION enforce_review_status_transition();

-- Moderation queue scan: "SELECT * FROM reviews WHERE status = 'PendingModeration'" IS the queue
-- (ddd-model.md Modeling Decision 9 — no separate Saga/queue aggregate). FIFO-ordered by created_at.
CREATE INDEX idx_reviews_moderation_queue ON reviews (created_at)
    WHERE status = 'PendingModeration';

-- Outbox for Review's own published events (ReviewSubmitted/ReviewUpdated/ReviewUnpublished).
-- Deliberately narrower than kart-order-service's order_events table: it is NOT also a full
-- state-transition audit trail (nothing in ddd-model.md/requirement-spec asks Review to keep one),
-- so a row is inserted here only on a transition that actually fires a published event — never on
-- every raw status write (e.g. flagged-content's initial PendingModeration insert writes no row here
-- at all, per the defer-until-outcome decision, design-decisions.md).
CREATE TABLE review_outbox (
    id             UUID PRIMARY KEY,
    review_id      UUID NOT NULL REFERENCES reviews(review_id),
    event_type     VARCHAR(24) NOT NULL CHECK (event_type IN ('ReviewSubmitted', 'ReviewUpdated', 'ReviewUnpublished')),
    payload        JSONB NOT NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    published_at   TIMESTAMPTZ NULL,
    created_by     TEXT NOT NULL,                     -- BRD §24.3 -- the principal whose reviews write produced this row: the author's userId (ReviewSubmitted/ReviewUpdated from a self-service edit) or the moderating Support Agent's/Admin's userId (ReviewSubmitted/ReviewUnpublished from a moderator action)
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(), -- BRD §24.3; bumped when published_at is set
    updated_by     TEXT NOT NULL DEFAULT 'system:review-outbox-poller' -- BRD §24.3 -- the Outbox poller is the only process that ever updates a row after insert
);

CREATE INDEX idx_review_outbox_unpublished ON review_outbox (created_at)
    WHERE published_at IS NULL;   -- the Outbox relay poller's own scan, same pattern/rationale as kart-order-service's idx_outbox_unpublished

-- ProductRating aggregate root (ddd-model.md, ADR-0014's canonical rating aggregate)
CREATE TABLE product_ratings (
    sku          TEXT PRIMARY KEY,       -- reference, kart-product-service
    avg          DOUBLE PRECISION NOT NULL DEFAULT 0,   -- RatingAverage value object; weighted-incremental only, never a full recompute
    count        INTEGER NOT NULL DEFAULT 0 CHECK (count >= 0),   -- RatingCount value object
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),    -- BRD §24.3; set on the first-ever review for this sku (the ON CONFLICT DO NOTHING insert below)
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),    -- BRD §24.3; bumped on every ReviewSubmitted/ReviewUpdated/ReviewUnpublished-driven UPDATE
    created_by   TEXT NOT NULL DEFAULT 'system:review-rating-projector',  -- BRD §24.3 -- this table is written exclusively by the async Outbox-relay ProductRating consumer (ddd-model.md), never a direct API caller
    updated_by   TEXT NOT NULL DEFAULT 'system:review-rating-projector'   -- same reasoning as created_by -- no human/API caller ever writes this table directly
);

-- ProcessedReviewLedger value object (ddd-model.md) — a SEPARATE table, not a jsonb/array column
-- on product_ratings. Rationale: the ledger is retained indefinitely and grows one row per
-- (order_id, sku) ever submitted for a given sku, unbounded over the product's lifetime. Folding
-- it into a jsonb column on product_ratings would force every single ReviewSubmitted/Updated/
-- Unpublished event to read-modify-rewrite the ENTIRE growing blob on the same hot row that
-- design-decisions.md's Concurrency-Control decision explicitly chose atomic incremental UPDATEs
-- to avoid contending on — reintroducing exactly the per-SKU lock-contention cost that decision
-- rejected pessimistic locking to avoid, and unbounded MVCC/TOAST bloat on a row every concurrent
-- submission for that sku must touch. A separate table lets the count/avg UPDATE stay a cheap,
-- narrow row-level write, decoupled from ledger growth — the same reasoning kart-payment-service's
-- idempotency_keys and kart-order-service's order_events tables already apply to their own
-- unbounded per-event state.
CREATE TABLE product_rating_ledger (
    order_id              UUID NOT NULL,
    sku                   TEXT NOT NULL REFERENCES product_ratings(sku),
    last_applied_rating   SMALLINT NULL CHECK (last_applied_rating IS NULL OR last_applied_rating BETWEEN 1 AND 5),
                          -- NULL once this (order_id, sku) entry has been unpublished/retracted (ddd-model.md);
                          -- never deleted even then — a deleted row would be indistinguishable from
                          -- "never processed," reopening the double-decrement race the ledger exists to close
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),  -- BRD §24.3; set on this (order_id, sku) pair's first-ever ledger entry
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by            TEXT NOT NULL DEFAULT 'system:review-rating-projector',  -- BRD §24.3 -- same async projector as product_ratings, never a direct API caller
    updated_by            TEXT NOT NULL DEFAULT 'system:review-rating-projector',
    PRIMARY KEY (order_id, sku)   -- the dedup key ddd-model.md Modeling Decision 4 chose over raw reviewId,
                                   -- because it is present on ReviewSubmitted, ReviewUpdated, AND ReviewUnpublished alike
);

-- VerifiedPurchaseRecord — non-aggregate lookup projection (ddd-model.md; ADR-0021)
CREATE TABLE verified_purchase_records (
    order_id       UUID PRIMARY KEY,
    user_id        UUID NULL,        -- nullable until OrderCreated is consumed
    skus           TEXT[] NULL,      -- nullable/empty until OrderCreated is consumed; derived from OrderCreated's items array
    delivered_at   TIMESTAMPTZ NULL, -- nullable until OrderDelivered is consumed
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),  -- ops/partition-key metadata only — not part of ddd-model.md's own field list,
                                                          -- added here purely to support the partitioning flag below
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),  -- BRD §24.3; bumped by whichever of OrderCreated/OrderDelivered upserts second
    created_by     TEXT NOT NULL DEFAULT 'system:review-verified-purchase-consumer',  -- BRD §24.3 -- written exclusively by the OrderCreated/OrderDelivered consumers (ddd-model.md); never a direct API caller
    updated_by     TEXT NOT NULL DEFAULT 'system:review-verified-purchase-consumer'
);
```

## Idempotent Upsert Mechanics — `VerifiedPurchaseRecord` (ADR-0021)

Both consumed events are full-field upserts targeting the *same* row/key, so they commute regardless of arrival order (ADR-0021's own ordering-race resolution) — no dedup ledger, no retry-and-requeue mechanism, unlike `OrderUserIndex`'s chained-lookup case in `kart-notification-service`:

```sql
-- On consuming OrderCreated (seeds userId/skus; never touches delivered_at)
INSERT INTO verified_purchase_records (order_id, user_id, skus)
VALUES ($1, $2, $3)
ON CONFLICT (order_id) DO UPDATE
    SET user_id = EXCLUDED.user_id, skus = EXCLUDED.skus,
        updated_at = now(), updated_by = 'system:review-verified-purchase-consumer';  -- BRD §24.3

-- On consuming OrderDelivered (seeds delivered_at; never touches userId/skus)
INSERT INTO verified_purchase_records (order_id, delivered_at)
VALUES ($1, $2)
ON CONFLICT (order_id) DO UPDATE
    SET delivered_at = EXCLUDED.delivered_at,
        updated_at = now(), updated_by = 'system:review-verified-purchase-consumer';  -- BRD §24.3
```

`POST /reviews`'s gate check (requirement-spec §6 Q2's exact rejection wording) is a single `SELECT ... WHERE order_id = $1` against this table's primary key, then an application-layer check that a row exists, `delivered_at IS NOT NULL`, `user_id` matches the caller, and `sku = ANY(skus)` — a single indexed-PK lookup, no additional index needed for any part of that check.

## Rating-Update Write Mechanics (implements design-decisions.md's Concurrency-Control decision)

The Outbox relay's `ProductRating` consumer applies each of `ReviewSubmitted`/`ReviewUpdated`/`ReviewUnpublished` as one transaction, deduplicated by the ledger's `(order_id, sku)` primary key before touching `avg`/`count` at all:

```sql
BEGIN;
-- Idempotency check first: a redelivered event whose ledger row already reflects this
-- exact outcome is a no-op (ddd-model.md's three dedup rules, one per event type).
INSERT INTO product_ratings (sku, avg, count) VALUES ($sku, 0, 0)
    ON CONFLICT (sku) DO NOTHING;   -- first-ever review for this sku

SELECT last_applied_rating FROM product_rating_ledger
    WHERE order_id = $order_id AND sku = $sku FOR UPDATE;
-- application layer compares against the incoming event and either no-ops (dedup) or:

UPDATE product_ratings
   SET count = count + 1,                                  -- ReviewSubmitted
       avg   = avg + ($rating - avg) / (count + 1),
       updated_at = now(), updated_by = 'system:review-rating-projector'  -- BRD §24.3
 WHERE sku = $sku;

INSERT INTO product_rating_ledger (order_id, sku, last_applied_rating, updated_at, created_by, updated_by)
VALUES ($order_id, $sku, $rating, now(), 'system:review-rating-projector', 'system:review-rating-projector')
ON CONFLICT (order_id, sku) DO UPDATE
    SET last_applied_rating = EXCLUDED.last_applied_rating, updated_at = now(),
        updated_by = 'system:review-rating-projector';  -- BRD §24.3
COMMIT;
```

`ReviewUpdated` and `ReviewUnpublished` follow the identical shape with `avg`/`count` adjusted per ddd-model.md's stated formulas (`(newRating - oldRating) / count`, and `count -= 1` with the last-known contribution removed, respectively) and the ledger row's `last_applied_rating` set to the new rating or `NULL`. This is always a narrow, single-row `UPDATE` on `product_ratings` plus a single-row upsert on `product_rating_ledger` — never a full recompute, and never a lock held across more than one transaction, per design-decisions.md's explicit rejection of pessimistic per-SKU locking.

## Row-Level Security Policy (BRD §24.1.4)

Per BRD §24.1.4, the service whose database physically holds a row decides and enforces that row's row-level security. Review's write model is PostgreSQL (see above); `reviews` and `verified_purchase_records` both have a genuine per-row end-user ownership concept, so native RLS is the mechanism for each.

**Session-scoped principal setting.** Same ambient mechanism already established platform-wide (see `kart-identity-service/database-design.md`'s precedent, generic plumbing owned by the shared `kart-shared` `ICurrentPrincipalAccessor`, not reimplemented here): immediately after acquiring a pooled connection and before any query runs, this service issues `SET LOCAL app.current_principal = <id>`, `SET LOCAL app.current_principal_kind = <'user'|'service'|'system'>`, and — a service-specific addition this table's own predicate needs, see below — `SET LOCAL app.current_principal_role = <coarse role claim>`, all resolved server-side from the validated JWT context or the internal consumer/job context, never a client-suppliable value. `app.current_principal` is the caller's own `userId` for `POST /reviews`/`PATCH /reviews/{id}`/`DELETE /reviews/{id}`, or the moderating Support Agent's/Admin's own `userId` for `PATCH /reviews/{id}/moderate`; `app.current_principal_role` carries the same coarse role claim BRD §24.1.1 already embeds in the JWT (`Customer`/`Support Agent`/`Admin`/`Partner API`); `app.current_principal_kind` is `system` for the `OrderCreated`/`OrderDelivered`/rating-projection consumers. Carrying the coarse role alongside the principal id is not a second, independently-maintained notion of "who is acting" — it is the same JWT claim the shared accessor already reads to resolve the principal itself, merely also exposed to the RLS predicate below.

**Policy shape — `reviews` (the one table needing a non-owner write path).** Unlike Wishlist/User/Identity's pure ownership-or-system predicates, Review's own `CanWrite` rule (requirement-spec §3; ddd-model.md's Domain Invariant above) legitimately grants a **non-owner** coarse role (Support Agent/Admin) a write path for moderation — reflected directly in the policy, not worked around with a service-principal indirection:

```sql
ALTER TABLE reviews ENABLE ROW LEVEL SECURITY;
CREATE POLICY reviews_owner_or_moderator ON reviews
    USING (
        user_id = current_setting('app.current_principal')::uuid
        OR current_setting('app.current_principal_role', true) IN ('Support Agent', 'Admin')
        OR current_setting('app.current_principal_kind', true) IN ('service', 'system')
    );
```

The role branch is not a blanket bypass: it mirrors exactly the same role gate requirement-spec.md's own §3 already applies to `PATCH /reviews/{id}/moderate` at the application layer (check #2 of BRD §24.1.3's enforcement flow) — RLS's marginal, additive protection here is specifically against the failure mode §24.1.4 itself names (an application code path that forgets to enforce that role gate), which stays blocked for any caller whose role is plain `Customer`.

```sql
-- verified_purchase_records
ALTER TABLE verified_purchase_records ENABLE ROW LEVEL SECURITY;
CREATE POLICY verified_purchase_records_owner_or_system ON verified_purchase_records
    USING (
        user_id = current_setting('app.current_principal')::uuid
        OR current_setting('app.current_principal_kind', true) IN ('service', 'system')
    );
```

`verified_purchase_records`'s policy is a plain owner-or-system predicate, no role branch — `POST /reviews`'s gate check is always the review author reading their own eligibility row, never a moderator. A row whose `user_id` is still `NULL` (before `OrderCreated` is consumed) is filtered out for any `'user'`-kind session regardless of who's asking, which is exactly the existing "no matching delivered order found yet" rejection outcome the gate check already produces at the application layer — RLS reinforces, rather than changes, that behavior.

**Not covered by this policy (no per-row end-user ownership concept):**

- `product_ratings`, `product_rating_ledger` — both keyed on `sku` (or `(order_id, sku)`), never `user_id`; a rating aggregate belongs to a product, not an end user, the same "a `user_id`-shaped policy would not even apply" carve-out BRD §24.1.4's own text uses for Payment's `payment_intents`. Both tables are, in addition, written exclusively by the internal `system:review-rating-projector` consumer (ddd-model.md) — no end-user- or moderator-facing request path ever reaches either directly.
- `review_outbox` — an internal Outbox relay table, written by the same transaction as a `reviews` mutation and read exclusively by the Outbox poller; no end-user-facing request path queries it directly, the same carve-out `kart-identity-service/database-design.md` and `kart-wishlist-service/database-design.md` draw for their own Outbox tables.

## Sensitive / PII Column Classification (BRD §24.1.5)

Column-level security answers a narrower question than row-level security: of the columns in a row a caller already has `CanRead` on (BRD §24.1.2), which does that caller's own coarse role actually see — full value, masked, or nothing. Review is the exact worked example BRD §24.1.5 itself names for this column, so the classification below grounds directly in that table rather than deriving one from scratch.

| Column | Full Value Visible To | Masked/Omitted For | Masking Rule |
|---|---|---|---|
| `reviews.user_id` (author identity) | Author (own row), Support Agent/Admin (moderation) | Any other Customer (public read) | BRD §24.1.5's own worked example, verbatim for this service: public review reads return a display name only, never the raw `user_id`; moderation-facing reads resolve the true author for abuse/moderation handling. Enforced at the `review_read_model` (MongoDB) projection and `GET /reviews?sku=...`'s response DTO — the projection never carries the raw `user_id` into a publicly-servable field in the first place (see below), rather than carrying it and relying on serialization to strip it at read time. |
| `reviews.idempotency_key` | No one, via any API response, ever | Every role, including the author | A client-request-correlation token, not domain content — never included in any response DTO; the only legitimate reader is the creation-retry-dedup check itself (database-design.md's Idempotency-Key Replay Window) |

**Why this list and no more:** `reviews.rating`, `.body_text`, `.status`, `.first_published_at`, `.created_at`/`.last_edited_at`, and the other §24.3 audit columns are not classified as sensitive — review content and moderation state are, by their nature, the platform-facing content this service exists to publish, not PII. `order_id`/`sku` are opaque cross-service references (ddd-model.md's ACL notes), not personal data about the reviewer. `product_ratings`/`product_rating_ledger`/`verified_purchase_records` carry no column that identifies a person beyond the `user_id`/opaque-reference columns already covered by the RLS policy above (only the record's own owner or an internal system process ever reaches those rows at all).

**Enforcement point:** primarily the `review_read_model` MongoDB projection and `GET /reviews?sku=...`'s response DTO (api-contract.yaml), per §24.1.5's stated primary control — the projection is built to resolve `user_id` to a display name (a denormalized lookup against `kart-user-service`'s own public profile data, the same cross-service-reference pattern this service already uses for `sku`/`order_id`) before the document is ever written, so a public read never has the raw `user_id` to leak in the first place; the moderation-facing read path (`PATCH /reviews/{id}/moderate`'s own query) reads directly from the PostgreSQL `reviews` row, which does carry the true `user_id`, gated by the RLS policy above. Secondarily, for any direct database connection bypassing this service's own API entirely (an analytics/BI read-replica, ops tooling), native `GRANT SELECT (col1, ...) ON reviews TO <db_role>` restricted to exclude `user_id`/`idempotency_key` for any database role other than this service's own application service role.

## Read Model (MongoDB) — `Review` only

```json
{
  "_id": "<reviewId>",
  "orderId": "...",
  "sku": "...",
  "authorDisplayName": "...",
  "rating": 5,
  "bodyText": "...",
  "firstPublishedAt": "2026-07-20T10:00:00Z",
  "lastEditedAt": "2026-07-20T10:00:00Z"
}
```

Projected by a consumer reading `review_outbox`'s published rows and upserting into a single `review_read_model` collection, keyed by `reviewId` — rebuildable from the PostgreSQL write side at any time (the core CQRS safety property, BRD §7). Write behavior per event type: `ReviewSubmitted` inserts the document (this is, by construction, always the first time this `reviewId` becomes visible — ddd-model.md's `firstPublishedAt` rule); `ReviewUpdated` updates `rating`/`bodyText`/`lastEditedAt` in place; `ReviewUnpublished` **deletes** the document outright rather than soft-flagging it — `GET /reviews?sku=...` (requirement-spec §5: "excludes soft-retracted and queued-for-moderation reviews") must never surface unpublished content, and the read model carries no audit responsibility of its own (that lives in `reviews`/`review_outbox` on the write side, which are never pruned).

**Column-level security note (BRD §24.1.5 — see the "Sensitive / PII Column Classification" subsection below for the full rule):** this document deliberately projects `authorDisplayName`, never the raw `userId`, from `reviews.user_id` — the projector resolves the display name via a denormalized lookup against `kart-user-service`'s own public profile data at write time, the same cross-service-reference pattern already used for `sku`/`order_id`. This is the platform's own worked masking example (BRD §24.1.5) applied directly: a public `GET /reviews?sku=...` reader never has the raw author identity to leak in the first place, since it was never projected here at all; the moderation-facing path (`PATCH /reviews/{id}/moderate`) resolves the true author by reading the PostgreSQL `reviews` row directly instead, where the RLS policy (below) already restricts access to the author or a Support Agent/Admin.

```
db.review_read_model.createIndex({ sku: 1, firstPublishedAt: -1 })
```

This one compound index supports `GET /reviews?sku=...`'s paginated, newest-first list within the P95 < 150ms / P99 < 400ms read-path budget (architecture.md) — the only read query pattern this collection needs to serve (requirement-spec §5; final pagination/sort contract is the API Design Agent's job, but sku-scoped + recency-sorted is the shape already settled here). No sharding is needed at this collection's scale relative to Product/Search's own hundred-million-SKU catalog (BRD §4.3) — a single replica set is sufficient, the same posture `kart-order-service/database-design.md` takes for its own read collection, revisited only if Review's real read volume demands it.

**`ProductRating` gets no MongoDB projection at all.** `GET /reviews/{sku}/summary` (or equivalent — final shape is the API Design Agent's job, ADR-0014) is a single row lookup by `product_ratings`'s own `sku` primary key — already comfortably inside the P95 < 150ms / P99 < 400ms read budget on plain indexed PostgreSQL, the identical reasoning `kart-payment-service/database-design.md` gives for introducing no MongoDB layer at all for its own single-row-by-key reads. `avg`/`count` are also always written by a narrow, cheap `UPDATE`, never a large aggregate rewrite, so there is no write-path reason to denormalize this into a second store either; doing so would only add staleness with no corresponding latency win CQRS is meant to buy elsewhere on the platform.

## Indexing Rationale

| Index | Query it supports | Why needed |
|---|---|---|
| `reviews (order_id, sku)` UNIQUE | Pre-insert check for the one-review-per-order/SKU invariant; also the row `PATCH`/`DELETE` and the moderator action ultimately mutate | Direct DB enforcement of a permanent invariant (requirement-spec §4/§6 Q6), not just application logic |
| `reviews (idempotency_key)` UNIQUE | `POST /reviews` creation-retry dedup | Direct enforcement of the Idempotent creation invariant, mirroring `kart-order-service`'s own simpler (non-Payment-style) idempotency pattern |
| `idx_reviews_moderation_queue` (partial, `status = 'PendingModeration'`) | `PATCH /reviews/{id}/moderate`'s queue read | This partial index *is* the moderation queue (ddd-model.md Modeling Decision 9) — scoped so the scan never touches `Published`/`Rejected`/`Retracted` rows it will never return |
| `idx_review_outbox_unpublished` (partial, `published_at IS NULL`) | Outbox relay poller's unpublished-row scan | Same rationale as `kart-order-service`'s `idx_outbox_unpublished` — scoped to rows actually awaiting publish |
| `product_ratings (sku)` PRIMARY KEY | `GET /reviews/{sku}/summary` reads; every rating-update `UPDATE` | The only access pattern this table ever serves — single-row by key, both read and write |
| `product_rating_ledger (order_id, sku)` PRIMARY KEY | Idempotency check before every `ReviewSubmitted`/`ReviewUpdated`/`ReviewUnpublished` application | Direct enforcement of the dedup key ddd-model.md Modeling Decision 4 settles on — must be indexed, it's on the hot path of every rating-affecting event |
| `verified_purchase_records (order_id)` PRIMARY KEY | `POST /reviews`'s eligibility gate lookup; both `OrderCreated`/`OrderDelivered` upserts | The sole access pattern (ADR-0021) — a single-row-by-key lookup/upsert, no secondary index needed for the `user_id`-match or `sku`-membership checks, both evaluated in-application against the one already-fetched row |

**No index exists, or is needed, for the edit-window check** (`PATCH /reviews/{id}` comparing `now() - created_at` against 30 days) — the row is already fetched by `review_id`'s primary key before that comparison runs; adding a secondary index keyed on a derived expiry would be exactly the kind of speculative index this stage's own definition rules out, since no query pattern ever scans for "reviews near their edit-window boundary."

## Idempotency-Key Replay Window

Not specified by requirement-spec/design-decisions.md beyond "unique constraint" (the Idempotency Mechanism decision). Adopting the same 24-hour replay-window default `kart-order-service/database-design.md` and `kart-payment-service`'s `IdempotencyRecord` TTL both already use, for consistency with platform precedent rather than a fresh number: a client retry of `POST /reviews` within 24h of the original request returns the original review's representation; past that window, a reused key is treated as a new logical attempt subject to full validation (including the still-live `(order_id, sku)` unique constraint as the independent second dedup layer). Enforced at the application layer against `created_at`, not a separate expiry column — `reviews` rows are never hard-deleted (retraction is a soft `status` transition, not a delete), so there is nothing to physically expire.

## Partitioning/Sharding

`reviews`, `review_outbox`, `product_ratings`, and `product_rating_ledger` are **not partitioned at launch** — neither architecture.md nor requirement-spec states a Review-specific write-volume figure distinct from the platform-wide default (unlike Order's explicit 1M/day normal, 20M/day flash-sale-peak figures, BRD §4.1, that justify `orders`/`order_events`'s own monthly range-partitioning), and review submission volume is inherently a fraction of order volume (not every delivered order line item is ever reviewed). Single-table PostgreSQL with the indexes above holds the stated P95 < 300ms write-path / P95 < 150ms–P99 < 400ms read-path budgets at that implied scale — the same "single-table sufficient until evidence says otherwise" default `kart-payment-service/database-design.md` and `kart-offer-service/database-design.md` both already apply to their own tables.

**`verified_purchase_records` is flagged explicitly, not silently defaulted, because it does inherit a stated high-volume figure — just not its own.** Every `OrderCreated` event platform-wide upserts exactly one row here (ADR-0021), so this table's write volume tracks Order's own 1M/day normal, 20M/day flash-sale-peak figures 1:1 — the same volume that already justifies `orders`' own monthly range-partitioning on `created_at`. This table is **not** partitioned in this pass, because Review's own approved docs (architecture.md, requirement-spec) never restate that figure as a Review-specific NFR the way they would need to for this stage to commit to a partition scheme with confidence — but the `created_at` column above is added specifically so a future pass can range-partition by month on the identical scheme `orders` already uses, with no schema migration beyond adding partitions, the moment real ingestion volume or `kart-order-service`'s own partition-maintenance cadence makes it warranted. This is a self-critique against a genuine "chosen key risks a write hotspot at scale" pattern (this stage's own Failure Conditions), resolved by flagging rather than either silently ignoring it or committing to a partition scheme unsupported by this service's own stated numbers.

No table here has any stated or implied sharding requirement — all four write-model concerns are far below the scale (BRD §4.3's hundred-million-SKU catalog) that would ever force horizontal write-sharding on this platform.

## GDPR Erasure (ADR-0016) — Flagged, Not Resolved Here

ADR-0016 names Review explicitly as a service holding userId-linked PII (`ReviewSubmitted` carries `userId`-attributable review content) and states every such service "picks up a new consumer responsibility the next time its own requirement-spec/edge-cases pass runs." That pass has **not** happened yet for `kart-review-service` — none of its approved `requirement-spec.md`, `edge-cases.md`, `design-decisions.md`, or `ddd-model.md` mentions consuming `UserDataErased` or a redaction shape for `reviews.user_id`/`reviews.body_text`. Deciding a redaction mechanism here, unprompted by any upstream approved doc, would be inventing a new domain/consumer responsibility this stage has no mandate to add (that decision belongs to a future requirement-spec/ddd-model pass, the same posture ADR-0021's own Consequences section already took toward `kart-order-service/event-contract.md`'s consumer-list update — a different, already-approved document's own scope, not silently absorbed into this one). Recorded here only so this gap is visible rather than silently missed the way `kart-cart-service`'s equivalent gap was found and closed by ADR-0016's own update: this schema's `user_id` column is a plain, non-nullable, non-tombstone-aware `UUID` today, and would need an explicit erasure-handling decision (tombstone-in-place vs. anonymize-and-retain, per ADR-0016's item 3) before `UserDataErased` consumption could actually be implemented against it.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner
- [x] Read-model/projection design approved directly (per this stage's own Human Approval policy — MongoDB `review_read_model` projection; the decision that `ProductRating` needs no MongoDB projection): **Approved**
- [x] Write-model schema (`reviews`, `review_outbox`, `product_ratings`, `product_rating_ledger`, `verified_purchase_records`) — **Approved**
