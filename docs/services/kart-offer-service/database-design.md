---
doc_type: database-design
service: kart-offer-service
status: approved
generated_by: database-design-agent
source: docs/services/kart-offer-service/ddd-model.md, docs/services/kart-offer-service/design-decisions.md, docs/services/kart-offer-service/api-contract.yaml, docs/services/kart-admin-service/design-decisions.md
---

# Database Design: kart-offer-service

Write model is PostgreSQL (source of truth) for all three aggregates. No separate read model/MongoDB projection is needed yet — `/promotions/active` and `/pricing/quote` are served by Redis-cached reads over the same PostgreSQL tables (per architecture.md's note that catalog price data must be materialized locally, not fetched synchronously).

## Write Model (PostgreSQL)

```sql
-- Coupon aggregate
CREATE TABLE coupons (
    coupon_code         TEXT PRIMARY KEY,
    per_user_cap        INT NULL,           -- RedemptionLimit.perUserCap
    global_cap          INT NULL,           -- RedemptionLimit.globalCap
    valid_from           TIMESTAMPTZ NOT NULL,
    valid_until          TIMESTAMPTZ NOT NULL,
    total_redemptions    INT NOT NULL DEFAULT 0,
    version              INT NOT NULL DEFAULT 1,  -- optimistic-concurrency token for admin writes (see "Admin Write-Path Mechanics" below); incremented only on deactivation, since issuance is a single INSERT and no full-edit endpoint exists
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),   -- BRD §24.3
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),   -- BRD §24.3; bumped on deactivation (the only post-issuance write)
    created_by           TEXT NOT NULL,           -- BRD §24.3 — Admin Service's client-credentials principal (ddd-model.md's CanRead/CanWrite/CanDelete invariant); the only writer of POST /coupons
    updated_by           TEXT NOT NULL            -- BRD §24.3 — Admin Service's client-credentials principal for a deactivation write; same value as created_by until a coupon is ever deactivated
);

CREATE TABLE coupon_redemptions (
    id              UUID PRIMARY KEY,
    coupon_code     TEXT NOT NULL REFERENCES coupons(coupon_code),
    user_id         TEXT NOT NULL,
    order_id        TEXT NOT NULL,
    redeemed_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
                        -- this table's created_at under BRD §24.3, in the domain's own
                        -- redemption vocabulary
    voided_at       TIMESTAMPTZ NULL,       -- set on CouponRedemptionVoided
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),   -- BRD §24.3; bumped when voided_at is set
    created_by      TEXT NOT NULL,          -- BRD §24.3 — the redeeming Customer's own user_id (ddd-model.md's CanRead/CanWrite/CanDelete invariant); same value as the row's own user_id column above
    updated_by      TEXT NOT NULL DEFAULT 'system:order-cancelled-consumer',
                        -- BRD §24.3 — the OrderCancelled consumer is the only process that ever
                        -- updates a row after insert (setting voided_at)
    UNIQUE (coupon_code, order_id)          -- enforces "never redeemed twice for the same order"
);

CREATE INDEX idx_coupon_redemptions_user ON coupon_redemptions (coupon_code, user_id)
    WHERE voided_at IS NULL;               -- supports per-user cap check under load

-- PricingQuote aggregate (append-only — a quote is a snapshot, never mutated)
CREATE TABLE pricing_quotes (
    quote_id        UUID PRIMARY KEY,
    currency        TEXT NOT NULL,
    total_amount     NUMERIC(12,2) NOT NULL,
    issued_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
                        -- this table's created_at under BRD §24.3, in the domain's own quote
                        -- vocabulary
    expires_at      TIMESTAMPTZ NOT NULL,  -- issued_at + 15 min, per ddd-model.md Modeling Decision #2
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),   -- BRD §24.3; never advances past issued_at in practice — a quote is never mutated after creation (ddd-model.md), carried for platform-wide uniformity
    created_by      TEXT NOT NULL,          -- BRD §24.3 — the requesting Customer's user_id, or an anonymous checkout-session identifier for a guest quote (ddd-model.md's audit-actor invariant) — an audit-trail concern, not an RLS ownership column (no CanRead/CanWrite ownership check exists on this table, see database-design.md's RLS section)
    updated_by      TEXT NOT NULL          -- BRD §24.3 — same value as created_by; this row has exactly one writer, ever
);

-- PromotionCampaign aggregate
CREATE TABLE promotion_campaigns (
    campaign_id     UUID PRIMARY KEY,
    starts_at       TIMESTAMPTZ NOT NULL,
    ends_at         TIMESTAMPTZ NOT NULL,
    discount_rule   JSONB NOT NULL,         -- DiscountRule value object, shape varies by campaign type
    version         INT NOT NULL DEFAULT 1, -- optimistic-concurrency token for admin writes, same mechanism as coupons.version below
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),   -- BRD §24.3
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),   -- BRD §24.3; bumped on deactivation (the only post-creation write)
    created_by      TEXT NOT NULL,          -- BRD §24.3 — Admin Service's client-credentials principal (ddd-model.md's CanRead/CanWrite/CanDelete invariant); the only writer of POST /promotions
    updated_by      TEXT NOT NULL           -- BRD §24.3 — Admin Service's client-credentials principal for a deactivation write; same value as created_by until a campaign is ever deactivated
);

CREATE INDEX idx_promotion_campaigns_window ON promotion_campaigns (starts_at, ends_at);
```

## Admin Write-Path Mechanics (implements ddd-model.md's Modeling Decision #4, doesn't re-derive it)

Fills the mechanism gap `design-decisions.md`'s "Idempotency Mechanism for Admin-Invoked Coupon/Promotion Write Endpoints" decision and `kart-admin-service/design-decisions.md`'s "Concurrency Control for Back-Office Writes" decision both require, now that these endpoints are actually specified (`api-contract.yaml`):

- **Issuance (`POST /v1/coupons`, `POST /v1/promotions`)** — a plain `INSERT`. Idempotency under a client-supplied `Idempotency-Key` retry is served by the row's own natural unique key: `coupon_code` is caller-supplied and PK-constrained, so a retried `POST /v1/coupons` with the same code hits the same conflict-to-idempotent-response translation already established for `/v1/coupons/redeem`'s `(coupon_code, order_id)` constraint (edge-cases.md "Double-redemption for the same order"). `campaign_id` is server-generated per request, so a `POST /v1/promotions` retry is only naturally idempotent if the client reuses a previously-returned `campaign_id` on retry — out of scope to enforce server-side beyond the `Idempotency-Key` header contract itself (no separate idempotency-ledger table is introduced; this mirrors how `/v1/coupons/redeem` itself has never had one either).
- **Deactivation (`POST /v1/coupons/{couponCode}/deactivate`, `POST /v1/promotions/{campaignId}/deactivate`)** — one atomic conditional `UPDATE`, combining the window-truncation mechanism (ddd-model.md Modeling Decision #4) with the `If-Match`/version precondition `kart-admin-service/design-decisions.md` requires of every owning service's write API it calls:

```sql
UPDATE coupons
SET valid_until = LEAST(valid_until, now()), version = version + 1,
    updated_at = now(), updated_by = $acting_admin_principal
WHERE coupon_code = $1 AND version = $2;
-- 0 rows affected → 412 Precondition Failed (stale version) or 404 (unknown code) —
-- api-contract.yaml distinguishes the two by checking existence first, since the same
-- zero-rows-updated result covers both. LEAST() guarantees a deactivation request against
-- an already-naturally-expired coupon is a no-op, never an accidental extension.
-- $acting_admin_principal (BRD §24.3) is Admin Service's own client-credentials principal,
-- resolved by the shared kart-shared current-principal accessor, never a caller-supplied value.

UPDATE promotion_campaigns
SET ends_at = LEAST(ends_at, now()), version = version + 1,
    updated_at = now(), updated_by = $acting_admin_principal
WHERE campaign_id = $1 AND version = $2;
-- Identical mechanism and failure-mode handling as coupons above.
```

- **Reading the current `version` before a deactivate call** — `api-contract.yaml`'s new `GET /v1/coupons/{couponCode}` / `GET /v1/promotions/{campaignId}` admin-read endpoints return `version` in their response body for exactly this purpose (an admin operator/Admin Service reads current state, then submits `If-Match: <version>` on the deactivate call) — the same read-then-conditional-write flow `kart-admin-service/design-decisions.md` already assumes exists on every owning service it calls.
- **Why a version column, not a full audit/history table:** neither `Coupon` nor `PromotionCampaign` has a general-purpose field-level edit endpoint (only issuance and deactivation) — a single incrementing integer is sufficient to detect "did someone else already act on this record since I read it," the identical minimal mechanism `kart-admin-service/design-decisions.md`'s own row-version choice for `admin_permission_grants` uses, not a new pattern invented here.

## Indexing Rationale

| Index | Query it supports | Why needed |
|---|---|---|
| `coupon_redemptions (coupon_code, order_id)` unique | Redemption idempotency check | Direct enforcement of the "never redeemed twice for the same order" invariant — a DB constraint, not just application logic |
| `idx_coupon_redemptions_user` (partial, `voided_at IS NULL`) | Per-user cap check on redeem | `/coupons/redeem` is on the checkout path — this must be an index lookup, not a table scan, to hold the P95 < 150ms budget |
| `idx_promotion_campaigns_window` | "Which campaigns are active right now" for `/promotions/active` and quote computation | Same latency constraint; range scan on a B-tree over the window bounds |

## Partitioning/Sharding

Not needed at current scale. The BRD's capacity plan (§4.3) doesn't call out Coupon/Pricing/Promotion write volume specifically — these are far lower-write-volume than Order/Payment (redemptions and quotes are read-heavy, writes only happen once per checkout, not once per RPS-scale read). Single-table PostgreSQL is sufficient; revisit only if evidence emerges otherwise.

## Row-Level Security Policy (BRD §24.1.4)

Per BRD §24.1.4, the service whose database physically holds a row decides and enforces that row's row-level security — never a shared, central component. Offer's write model is entirely PostgreSQL (`coupons`, `coupon_redemptions`, `pricing_quotes`, `promotion_campaigns`), but only one of the four tables has a genuine per-row end-user ownership column to key a policy on.

**`coupon_redemptions` — native RLS applies.** `user_id` is a real per-row owner (the redeeming Customer). Same ambient mechanism already established platform-wide (see `kart-identity-service/database-design.md`'s precedent): immediately after acquiring a pooled connection and before any query runs, this service issues `SET LOCAL app.current_principal = <id>` and `SET LOCAL app.current_principal_kind = <'user'|'system'>`, resolved server-side from the validated JWT (redemption write, customer-facing) or the internal `OrderCancelled`-consumer context (`system`) — never a client-suppliable value. This is the same resolved-principal value the shared `kart-shared` `created_by`/`updated_by` interceptor (§24.3, above) stamps onto every mutation.

```sql
ALTER TABLE coupon_redemptions ENABLE ROW LEVEL SECURITY;

CREATE POLICY coupon_redemptions_owner_isolation ON coupon_redemptions
    USING (
        current_setting('app.current_principal_kind') = 'system'
        OR user_id = current_setting('app.current_principal')::text
    );
```

The `system` branch is not a blanket bypass: it is reached only by the internal `OrderCancelled` consumer voiding a redemption, an internal process no external caller can reach — RLS's marginal, additive protection here is specifically against a user-facing code path that forgets its own `WHERE user_id = ...` clause, which stays fully blocked whenever `app.current_principal_kind = 'user'`.

**`coupons` and `promotion_campaigns` — no per-row end-user ownership concept; RLS does not apply.** Both are platform-wide, admin-managed resources (ddd-model.md's CanRead/CanWrite/CanDelete invariants for each): no individual Customer owns a `Coupon` or `PromotionCampaign` row the way a `carts` row belongs to a `user_id`. This is the same "no owner column exists" carve-out BRD §24.1.4 itself names for Admin's own `admin_permission_grants` (keyed on `principal_id` + `category`, not `user_id`) and for Identity's `idp_group_role_mappings` — access control for these two tables lives entirely at §24.1.2's tier (the inline Admin-Service-client-credentials-principal check on every write; open, business-rule-gated reads), not at a row-ownership predicate that has nothing to key on.

**`pricing_quotes` — no per-row end-user ownership concept; RLS does not apply, for a different reason than `coupons`/`promotion_campaigns`.** This is the exact carve-out BRD §24.1.4 itself anticipates via its own Payment `payment_intents` example: `pricing_quotes` has a `created_by` audit column (§24.3, above) recording who requested the quote, but **no persisted ownership column any subsequent read/write path filters on** — a quote is returned synchronously at issuance and referenced only by its opaque `QuoteId` at checkout (requirement-spec §5 has no "read my quotes" endpoint), so there is no ongoing caller-facing access path for an ownership predicate to guard in the first place. Recording `created_by` (§24.3, an audit-trail obligation that always applies) is a distinct concern from row-level access control (§24.1.4, which only has teeth where a row is read back by a caller other than the one who created it) — this table simply never reaches the second situation.

## Sensitive / PII Column Classification (BRD §24.1.5)

Column-level security answers a narrower question than row-level security: of the columns in a row a caller already has `CanRead` on (BRD §24.1.2), which does that caller's own coarse role actually see — full value, masked, or nothing.

**Offer has no sensitive/PII columns to classify.** `coupons` holds only a caller-supplied code, caps, and a validity window; `promotion_campaigns` holds only a window and a `discount_rule` JSON blob — both platform-wide commercial configuration, not personal data. `pricing_quotes` holds only amounts/currency and timestamps. `coupon_redemptions` holds an opaque `user_id`/`order_id` reference (already governed by the RLS policy above, not column-level masking — knowing *which* opaque id redeemed a coupon one is already authorized to read is not itself a PII disclosure, the same reasoning `kart-order-service`/`kart-cart-service` apply to their own opaque owner columns) plus timestamps. None of these is the kind of column §24.1.5 exists to mask — no phone number, address, or credential-shaped value is stored anywhere in this service's schema. This mirrors BRD §24.1.5's own reasoning for Payment Service ("no unmasked PCI data exists to protect in the first place") for a structurally similar reason: Offer's columns are commercial/promotional data, never PII.

**Enforcement point:** not applicable — there is no column requiring role-differentiated response shaping today. If a future requirement introduces a genuinely sensitive column, the primary control would be this service's own response-serialization DTO (api-contract.yaml) per §24.1.5's stated default, consistent with every other service on this platform.

## Sign-off

- [x] Reviewed by: kakon-mehedi — re-reviewed this pass for the `version` column addition (additive, non-breaking; supports the now-specified admin write endpoints) and the "Admin Write-Path Mechanics" section
- [x] Approved (write-model schema)
