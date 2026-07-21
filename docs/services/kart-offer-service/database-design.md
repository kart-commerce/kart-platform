---
doc_type: database-design
service: kart-offer-service
status: approved
generated_by: database-design-agent
source: docs/services/kart-offer-service/ddd-model.md
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
    total_redemptions    INT NOT NULL DEFAULT 0
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
    discount_rule   JSONB NOT NULL          -- DiscountRule value object, shape varies by campaign type
);

CREATE INDEX idx_promotion_campaigns_window ON promotion_campaigns (starts_at, ends_at);
```

## Indexing Rationale

| Index | Query it supports | Why needed |
|---|---|---|
| `coupon_redemptions (coupon_code, order_id)` unique | Redemption idempotency check | Direct enforcement of the "never redeemed twice for the same order" invariant — a DB constraint, not just application logic |
| `idx_coupon_redemptions_user` (partial, `voided_at IS NULL`) | Per-user cap check on redeem | `/coupons/redeem` is on the checkout path — this must be an index lookup, not a table scan, to hold the P95 < 150ms budget |
| `idx_promotion_campaigns_window` | "Which campaigns are active right now" for `/promotions/active` and quote computation | Same latency constraint; range scan on a B-tree over the window bounds |

## Partitioning/Sharding

Not needed at current scale. The BRD's capacity plan (§4.3) doesn't call out Coupon/Pricing/Promotion write volume specifically — these are far lower-write-volume than Order/Payment (redemptions and quotes are read-heavy, writes only happen once per checkout, not once per RPS-scale read). Single-table PostgreSQL is sufficient; revisit only if evidence emerges otherwise.

## Sign-off

- [x] Reviewed by: kakon-mehedi
- [x] Approved (write-model schema)
