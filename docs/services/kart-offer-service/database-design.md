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
    version              INT NOT NULL DEFAULT 1   -- optimistic-concurrency token for admin writes (see "Admin Write-Path Mechanics" below); incremented only on deactivation, since issuance is a single INSERT and no full-edit endpoint exists
);

CREATE TABLE coupon_redemptions (
    id              UUID PRIMARY KEY,
    coupon_code     TEXT NOT NULL REFERENCES coupons(coupon_code),
    user_id         TEXT NOT NULL,
    order_id        TEXT NOT NULL,
    redeemed_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    voided_at       TIMESTAMPTZ NULL,       -- set on CouponRedemptionVoided
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
    expires_at      TIMESTAMPTZ NOT NULL   -- issued_at + 15 min, per ddd-model.md Modeling Decision #2
);

-- PromotionCampaign aggregate
CREATE TABLE promotion_campaigns (
    campaign_id     UUID PRIMARY KEY,
    starts_at       TIMESTAMPTZ NOT NULL,
    ends_at         TIMESTAMPTZ NOT NULL,
    discount_rule   JSONB NOT NULL,         -- DiscountRule value object, shape varies by campaign type
    version         INT NOT NULL DEFAULT 1  -- optimistic-concurrency token for admin writes, same mechanism as coupons.version below
);

CREATE INDEX idx_promotion_campaigns_window ON promotion_campaigns (starts_at, ends_at);
```

## Admin Write-Path Mechanics (implements ddd-model.md's Modeling Decision #4, doesn't re-derive it)

Fills the mechanism gap `design-decisions.md`'s "Idempotency Mechanism for Admin-Invoked Coupon/Promotion Write Endpoints" decision and `kart-admin-service/design-decisions.md`'s "Concurrency Control for Back-Office Writes" decision both require, now that these endpoints are actually specified (`api-contract.yaml`):

- **Issuance (`POST /v1/coupons`, `POST /v1/promotions`)** — a plain `INSERT`. Idempotency under a client-supplied `Idempotency-Key` retry is served by the row's own natural unique key: `coupon_code` is caller-supplied and PK-constrained, so a retried `POST /v1/coupons` with the same code hits the same conflict-to-idempotent-response translation already established for `/v1/coupons/redeem`'s `(coupon_code, order_id)` constraint (edge-cases.md "Double-redemption for the same order"). `campaign_id` is server-generated per request, so a `POST /v1/promotions` retry is only naturally idempotent if the client reuses a previously-returned `campaign_id` on retry — out of scope to enforce server-side beyond the `Idempotency-Key` header contract itself (no separate idempotency-ledger table is introduced; this mirrors how `/v1/coupons/redeem` itself has never had one either).
- **Deactivation (`POST /v1/coupons/{couponCode}/deactivate`, `POST /v1/promotions/{campaignId}/deactivate`)** — one atomic conditional `UPDATE`, combining the window-truncation mechanism (ddd-model.md Modeling Decision #4) with the `If-Match`/version precondition `kart-admin-service/design-decisions.md` requires of every owning service's write API it calls:

```sql
UPDATE coupons
SET valid_until = LEAST(valid_until, now()), version = version + 1
WHERE coupon_code = $1 AND version = $2;
-- 0 rows affected → 412 Precondition Failed (stale version) or 404 (unknown code) —
-- api-contract.yaml distinguishes the two by checking existence first, since the same
-- zero-rows-updated result covers both. LEAST() guarantees a deactivation request against
-- an already-naturally-expired coupon is a no-op, never an accidental extension.

UPDATE promotion_campaigns
SET ends_at = LEAST(ends_at, now()), version = version + 1
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

## Sign-off

- [x] Reviewed by: kakon-mehedi — re-reviewed this pass for the `version` column addition (additive, non-breaking; supports the now-specified admin write endpoints) and the "Admin Write-Path Mechanics" section
- [x] Approved (write-model schema)
