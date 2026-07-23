---
doc_type: database-design
service: kart-notification-service
status: approved
generated_by: database-design-agent
source: docs/services/kart-notification-service/ddd-model.md, docs/services/kart-notification-service/architecture.md, docs/services/kart-notification-service/design-decisions.md, docs/services/kart-notification-service/requirement-spec.md, docs/services/kart-notification-service/edge-cases.md, docs/services/kart-notification-service/api-contract.yaml, docs/adr/0016-user-gdpr-erasure-policy.md, docs/adr/0020-notification-userid-resolution.md
---

# Database Design: kart-notification-service

Write model is PostgreSQL, the sole source of truth for both approved aggregates (`ddd-model.md`: `NotificationAttempt`, `NotificationPreference`). **There is no MongoDB or Redis read side, and none is introduced here.** This is an explicit design choice, not a default carried over out of habit:

- `design-decisions.md`'s "Caching Strategy for Opt-Out Preference Lookup" decision already rejected a cache (in-process, Redis, or startup-preload) for exactly the query this schema exists to serve — the opt-out check is an absolute invariant ("must never dispatch... regardless of criticality tier"), and any cache staleness window, even a short TTL, risks the outcome the invariant forbids. The decision explicitly accepts "one extra indexed DB read... per send attempt at up to ~50,000 msgs/sec peak, instead of the lower-latency path a cache would offer," in exchange for correctness.
- `api-contract.yaml` confirms this service has no public or internal API surface at all (consumer-only) — there is no read/query path for a projection to serve in the first place. Contrast with `kart-shipping-service/database-design.md` (Postgres-only write side, no cache, but flags a *possible* future ops-query endpoint as the trigger to revisit) and `kart-delivery-tracking-service/database-design.md` (MongoDB *is* the sole source of truth there, because that service's own domain has no synchronous write path and its only client surface is a read). Neither precedent applies here: Notification has a real write path (every consumed event resolves into a `NotificationAttempt` row) and, per `design-decisions.md`, a deliberately rejected cache — so PostgreSQL-only, direct-read is the correct and only architecture for both tables below.

Four tables total: two per aggregate root, matching `ddd-model.md`'s two-aggregate split exactly (the transaction-boundary test: a preference upsert and a send-attempt insert never need to commit together), plus two non-aggregate lookup projections — `order_user_index` and `tracking_order_index` — added per ADR-0020 to resolve `userId` for the nine of thirteen consumed triggering events whose own payload does not carry it.

## Write Model (PostgreSQL)

```sql
-- ═══════════════════════════════════════════════════════════════════════
-- NotificationAttempt aggregate (ddd-model.md) — the (eventId, channel)
-- idempotency boundary AND the audit record every consumed event must
-- resolve into (requirement-spec §4 Domain Invariant #1: "never a silent
-- drop").
-- ═══════════════════════════════════════════════════════════════════════

CREATE TABLE notification_attempts (
    event_id             UUID NOT NULL,            -- the triggering event's own id (OrderConfirmed.eventId, etc.)
    channel              TEXT NOT NULL
                             CHECK (channel IN ('Email', 'SMS', 'Push')),   -- Channel value object
    user_id              UUID NOT NULL,             -- reference only, owned by kart-identity-service
    triggering_event_type TEXT NOT NULL,            -- TriggeringEventType, e.g. 'OrderConfirmed', 'PaymentFailed'
    criticality_tier     TEXT NOT NULL
                             CHECK (criticality_tier IN ('Tier1', 'Tier2', 'Tier3')),  -- snapshotted at creation (Modeling Decision #3), never re-derived
    category             TEXT NOT NULL,             -- NotificationCategory, derived from triggering_event_type via static config (Modeling Decision #4)
    status               TEXT NOT NULL DEFAULT 'Pending'
                             CHECK (status IN ('Pending', 'Sent', 'Failed', 'Suppressed')),  -- DeliveryOutcome
    attempt_count         INTEGER NOT NULL DEFAULT 0,
    suppressed_reason     TEXT NULL,                -- populated only when status = 'Suppressed'
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_attempt_at        TIMESTAMPTZ NULL,

    -- NotificationAttemptKey (ddd-model.md) — this constraint IS the idempotency mechanism
    -- (insert-first / ON CONFLICT semantics, Modeling Decision #2), not a pre-check against a
    -- separately-queried row. event_id is included because HASH partitioning below requires
    -- every unique constraint on a partitioned table to include the partition key column.
    PRIMARY KEY (event_id, channel),

    -- Backstops the "Suppressed always carries a reason, every other status never does" shape,
    -- mirroring kart-shipping-service/database-design.md's chk_shipment_status_shape pattern.
    CONSTRAINT chk_notification_attempt_suppressed_reason_shape CHECK (
        (status = 'Suppressed' AND suppressed_reason IS NOT NULL)
        OR (status <> 'Suppressed' AND suppressed_reason IS NULL)
    ),

    -- Defense-in-depth backstop for the TTL-ladder retry ceiling (design-decisions.md's Retry &
    -- DLQ decision: Tier1 <= 5 attempts, Tier2 <= 3, Tier3 <= 2). The ceiling is actually enforced
    -- by RabbitMQ's own ladder depth (an external, not a DB, mechanism) — this CHECK exists only
    -- so a coding bug that keeps incrementing attempt_count past its tier's budget fails loudly
    -- at the DB layer instead of silently persisting an impossible row, the same defense-in-depth
    -- reasoning kart-payment-service/database-design.md applies via its refund-ceiling index.
    CONSTRAINT chk_notification_attempt_count_within_tier CHECK (
        (criticality_tier = 'Tier1' AND attempt_count <= 5)
        OR (criticality_tier = 'Tier2' AND attempt_count <= 3)
        OR (criticality_tier = 'Tier3' AND attempt_count <= 2)
    )
)
PARTITION BY HASH (event_id);

-- See "Partitioning Rationale" below for why HASH-on-event_id, not RANGE-on-created_at, is the
-- correct choice here despite this being a time-ordered audit-trail table.
CREATE TABLE notification_attempts_p0  PARTITION OF notification_attempts FOR VALUES WITH (MODULUS 16, REMAINDER 0);
CREATE TABLE notification_attempts_p1  PARTITION OF notification_attempts FOR VALUES WITH (MODULUS 16, REMAINDER 1);
-- ... p2 through p15, sixteen partitions total (a defensible starting point at ~50,000 msgs/sec
-- peak platform-wide, not an exact figure derived from a stated per-partition throughput ceiling;
-- revisit the modulus only if evidence of per-partition hotspotting emerges at real production
-- volume, the same "single-table/partition count sufficient until evidence says otherwise" default
-- kart-payment-service/database-design.md and kart-shipping-service/database-design.md both apply
-- to their own unpartitioned tables).

-- Enforces DeliveryOutcome's monotonic, terminal-transition invariant (ddd-model.md: "Pending ->
-- {Sent, Failed, Suppressed} only, and only once"). Declared on the partitioned parent; PostgreSQL
-- propagates row-level triggers to every partition automatically, mirroring
-- kart-shipping-service/database-design.md's enforce_shipment_status_transition() pattern.
CREATE OR REPLACE FUNCTION enforce_notification_attempt_status_transition() RETURNS trigger AS $$
BEGIN
    IF OLD.status IN ('Sent', 'Failed', 'Suppressed') AND NEW.status <> OLD.status THEN
        RAISE EXCEPTION 'illegal DeliveryOutcome transition: % is terminal, cannot move to %', OLD.status, NEW.status;
    END IF;
    NEW.last_attempt_at := now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_notification_attempts_status_guard
    BEFORE UPDATE OF status ON notification_attempts
    FOR EACH ROW EXECUTE FUNCTION enforce_notification_attempt_status_transition();

-- Audit/support lookup: "what notifications has this user received" (requirement-spec §4 Domain
-- Invariant #1's audit-trail purpose; there is no formal ops/support API endpoint for this
-- per api-contract.yaml, but the audit-trail invariant itself implies internal tooling needs a
-- way to query it, the same reasoning kart-payment-service/database-design.md applies to
-- gateway_webhook_events for "ops/support debugging during an incident").
CREATE INDEX idx_notification_attempts_user_audit ON notification_attempts (user_id, created_at);

-- Ops/admin DLQ-inspection tooling: "show every terminally-failed send attempt" (BRD §8.2's
-- "failures are inspected via admin tooling, never silently dropped" philosophy; edge-cases.md's
-- DLQ decision). Partial index — Failed is expected to be a small fraction of all attempts, so
-- this keeps the scan bounded rather than degrading to a full-table scan across every partition.
CREATE INDEX idx_notification_attempts_failed ON notification_attempts (created_at)
    WHERE status = 'Failed';


-- ═══════════════════════════════════════════════════════════════════════
-- OrderUserIndex / TrackingOrderIndex (ddd-model.md, ADR-0020) — lookup
-- projections, not aggregates. Resolve userId for the nine of thirteen
-- triggering events that do not carry it directly in their own payload
-- (checked against each publisher's own approved event-contract.md).
-- ═══════════════════════════════════════════════════════════════════════

-- Seeded solely by consuming OrderCreated (orderId, userId already both present
-- on that event's own payload). Read-only for every other order/payment/shipping
-- triggering event's userId resolution (ADR-0020).
CREATE TABLE order_user_index (
    order_id    UUID PRIMARY KEY,
    user_id     UUID NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Seeded solely by consuming ShipmentDispatched (orderId, trackingId already both
-- present on that event's own payload). Chains DeliveryStatusUpdated's trackingId
-- to order_user_index's orderId, since that event carries neither userId nor
-- orderId directly.
CREATE TABLE tracking_order_index (
    tracking_id  TEXT PRIMARY KEY,
    order_id     UUID NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Neither table is partitioned: both are bounded by distinct order count, not raw
-- event-stream volume (same "bounded by entity count" reasoning applied to
-- notification_preferences below), and neither is a write-hot path comparable to
-- notification_attempts — each row is written at most twice (insert, then a
-- possible no-op ON CONFLICT DO NOTHING on redelivery of its own seeding event).


-- ═══════════════════════════════════════════════════════════════════════
-- NotificationPreference aggregate (ddd-model.md) — the local, eventually-
-- consistent opt-out/reachability projection, populated solely by consuming
-- UserNotificationPreferenceUpdated (owned by kart-user-service).
-- ═══════════════════════════════════════════════════════════════════════

CREATE TABLE notification_preferences (
    user_id          UUID PRIMARY KEY,          -- reference only, owned by kart-identity-service
    opt_out_matrix   JSONB NOT NULL DEFAULT '{}'::jsonb,  -- OptOutMatrix: {channel -> {category -> optedOut: bool}}
    app_installed    BOOLEAN NOT NULL DEFAULT false,      -- AppInstalled — gates Push as a candidate channel
    last_updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()

    -- No separate idempotency ledger, unlike notification_attempts (Modeling Decision #9): a
    -- full-map replace upsert (Modeling Decision #7) is naturally idempotent under
    -- UserNotificationPreferenceUpdated's at-least-once redelivery — replaying the same payload
    -- twice against the same user_id produces the same resulting row every time.
);
```

## Write Mechanics

**0. `userId` resolution path (ADR-0020) — run before step 1, only for the nine triggering events that do not carry `userId` directly:**

```sql
-- Seed on consuming OrderCreated (own payload already has both fields):
INSERT INTO order_user_index (order_id, user_id) VALUES ($order_id, $user_id)
ON CONFLICT (order_id) DO NOTHING;

-- Seed on consuming ShipmentDispatched (own payload already has both fields):
INSERT INTO tracking_order_index (tracking_id, order_id) VALUES ($tracking_id, $order_id)
ON CONFLICT (tracking_id) DO NOTHING;

-- Resolve, for OrderConfirmed/OrderCancelled/OrderCompensationTriggered/OrderDelivered/
-- PaymentCompleted/PaymentFailed/RefundIssued/ShipmentDispatched (orderId-keyed):
SELECT user_id FROM order_user_index WHERE order_id = $order_id;

-- Resolve, for DeliveryStatusUpdated only (trackingId-keyed, chains through order_id):
SELECT oui.user_id
FROM tracking_order_index toi
JOIN order_user_index oui ON oui.order_id = toi.order_id
WHERE toi.tracking_id = $tracking_id;
```

A `NULL`/no-row result means the seeding event (`OrderCreated` or `ShipmentDispatched`) has not yet been consumed — treated as transient, not a permanent failure: the message nacks/requeues onto its own already-modeled `CriticalityTier` retry ladder rather than proceeding with a missing `userId` (ADR-0020's ordering-race handling; `ddd-model.md`'s Lookup Projections section).

**1. Send-attempt path — opt-out check and idempotency insert combined into one query, per `design-decisions.md`'s stated intent ("combined... into a single query path per send attempt where practical"):**

```sql
WITH pref AS (
    SELECT opt_out_matrix
    FROM notification_preferences
    WHERE user_id = $user_id
)
INSERT INTO notification_attempts
    (event_id, channel, user_id, triggering_event_type, criticality_tier, category, status, suppressed_reason)
SELECT
    $event_id, $channel, $user_id, $triggering_event_type, $criticality_tier, $category,
    CASE WHEN opted_out THEN 'Suppressed' ELSE 'Pending' END,
    CASE WHEN opted_out THEN format('opted out of %s/%s', $channel, $category) ELSE NULL END
FROM (
    SELECT COALESCE(
        (SELECT (pref.opt_out_matrix -> $channel ->> $category)::boolean FROM pref),
        false   -- absence of a row, or absence of this channel/category in the map, defaults to
                -- opted-in (Modeling Decision #8) — never treated as opted-out
    ) AS opted_out
) resolved
ON CONFLICT (event_id, channel) DO NOTHING
RETURNING status;
```

- **0 rows returned:** this `(event_id, channel)` already exists — a redelivery of an already-handled attempt. This is a full no-op: no delivery is (re)attempted and `NotificationSent` is not (re)published (Modeling Decision #2's uniqueness invariant; the original attempt already published it).
- **`status = 'Suppressed'` returned:** the opt-out check fired before any physical delivery try — `attempt_count` stays `0`, and `NotificationSent(status=suppressed)` is published immediately.
- **`status = 'Pending'` returned:** proceed to the physical delivery attempt via the channel adapter (bulkhead-isolated per channel, circuit-breaker per provider — `design-decisions.md`'s Resilience decision).

**2. Delivery-attempt resolution** (RabbitMQ TTL-ladder retry is external infrastructure, not modeled in Postgres — only the outcome of each physical try is persisted):

```sql
-- Success
UPDATE notification_attempts
SET status = 'Sent', attempt_count = attempt_count + 1
WHERE event_id = $event_id AND channel = $channel;

-- Failure, retry budget not yet exhausted (status stays Pending; message requeues onto the next
-- TTL-ladder rung, a RabbitMQ-level concern this table does not track)
UPDATE notification_attempts
SET attempt_count = attempt_count + 1
WHERE event_id = $event_id AND channel = $channel;

-- Failure, retry budget exhausted (chk_notification_attempt_count_within_tier is the backstop
-- that would reject a coding bug that tried to increment past this point)
UPDATE notification_attempts
SET status = 'Failed', attempt_count = attempt_count + 1
WHERE event_id = $event_id AND channel = $channel;
```

Once `status` reaches any terminal value, `NotificationSent(userId, channel, status)` is published — exactly once per row (requirement-spec Domain Invariant #2).

**3. Preference sync path** (consuming `UserNotificationPreferenceUpdated`):

```sql
INSERT INTO notification_preferences (user_id, opt_out_matrix, app_installed, last_updated_at)
VALUES ($user_id, $opt_out_matrix, $app_installed, now())
ON CONFLICT (user_id) DO UPDATE
SET opt_out_matrix = EXCLUDED.opt_out_matrix,
    app_installed  = EXCLUDED.app_installed,
    last_updated_at = EXCLUDED.last_updated_at;
```

## No Transactional Outbox — `NotificationSent` Publish Is Direct, Not Transactional

Unlike `kart-shipping-service/database-design.md` (which introduces a `shipment_outbox` table) or `kart-order-service`'s own Outbox relay, no Outbox table is introduced here. This is deliberate, not an oversight: `design-decisions.md` names no "Event Publish Atomicity" decision for Notification at all, and requirement-spec §6 Q6 explicitly states the `NotificationSent` audit-publish tier is "1x, fire-and-forget" *because* "losing/delaying this publish delays Analytics' visibility into an already-resolved outcome, not the user-facing delivery itself" — i.e., the platform has already decided this publish does not need atomicity with the row's own state transition. Building an Outbox table to guarantee exactly that atomicity would be solving a durability problem this service's own upstream docs explicitly declined to require. The consumer publishes `NotificationSent` directly to RabbitMQ immediately after the `UPDATE ... SET status = ...` commits, best-effort.

## Partitioning Rationale — Hash on `event_id`, Not Range on `created_at`

`notification_attempts` is the platform's highest-write-volume audit trail (requirement-spec §3: up to ~50,000 msgs/sec peak, ~200M msgs/day platform-wide, Notification being the broadest single fan-in consumer on its resolved scope) and, per requirement-spec §4 Domain Invariant #1, a permanent record that is never silently dropped — no TTL, no stated retention/deletion window anywhere in requirement-spec, edge-cases, or design-decisions.md (unlike `kart-payment-service`'s `idempotency_keys`, which has a stated 24h TTL that range-partitioning-by-`created_at` exists specifically to make cheap to prune).

A time-range partitioning scheme (the more obvious first instinct for a time-ordered audit table, and the pattern `kart-payment-service/database-design.md` uses for `idempotency_keys`) was considered and rejected here for a concrete, technical reason: PostgreSQL requires every unique/primary-key constraint on a partitioned table to include the partition key column. `NotificationAttemptKey`'s uniqueness (`event_id, channel`) is not an incidental index — it is the atomic idempotency mechanism itself (`ddd-model.md` Modeling Decision #2, closing the exact residual race requirement-spec Open Question 4 flagged). Partitioning by `RANGE (created_at)` would force `created_at` into the primary key (e.g. `PRIMARY KEY (event_id, channel, created_at)`), which would let a redelivery landing in a different partition window bypass the constraint — reintroducing, at the partition boundary, exactly the race this schema exists to close. That trade-off is not acceptable given how explicitly `ddd-model.md` treats this as a closed, not narrowed, correctness guarantee.

**Decision:** `PARTITION BY HASH (event_id)`, 16 partitions. Because `event_id` is already part of the primary key, every row for a given `event_id` is deterministically routed to the same partition regardless of `channel` — so the per-partition `(event_id, channel)` constraint composes into a true, uncompromised global uniqueness guarantee across the whole table, with no weakening of the idempotency invariant. This buys the operational benefit partitioning exists to provide at this volume (distributing insert/index-maintenance load and vacuum work across 16 smaller B-trees instead of one, avoiding a single index becoming the write-throughput bottleneck at ~50,000 msgs/sec peak) without touching correctness.

**Trade-off accepted, flagged explicitly:** hash partitions are not time-bounded, so they cannot be dropped wholesale the way `kart-payment-service`'s date-named `idempotency_keys` partitions can once their TTL passes. This is accepted because no retention/archival policy is stated anywhere upstream for this table to begin with (the domain invariant requires the audit trail to persist, not to expire) — this partitioning scheme optimizes for write-throughput distribution today, not for a deletion mechanism nothing upstream authorizes yet. If a future compliance or storage-cost decision introduces a retention window for `notification_attempts`, that decision would need its own archival mechanism (e.g., a scheduled job moving/deleting rows past a stated age via `idx_notification_attempts_failed`-style indexed sweeps, or a secondary range-partitioned cold-storage table), not a partition-drop — flagged here as a non-blocking gap for a future pass, the same way `kart-delivery-tracking-service/database-design.md` flags its own unbounded `tracking_status_history_entries` growth as "revisit... once a real retention/archival decision... exists."

`notification_preferences` is **not partitioned**. Its row count is bounded by distinct registered-user count, not event volume — the same "bounded by entity count, not event-stream volume" reasoning `kart-delivery-tracking-service/database-design.md` applies to its own `tracking_records` collection — and a single table comfortably holds that at any Kart-plausible user count.

## Indexing Rationale

| Index | Query it supports | Why needed |
|---|---|---|
| `notification_attempts` `PRIMARY KEY (event_id, channel)` (per-partition, composing to a global guarantee under hash partitioning) | The combined opt-out+idempotency insert on every send attempt; the "is this a redelivery" check | This constraint **is** the idempotency mechanism (`ddd-model.md` Modeling Decision #2) — insert-first/`ON CONFLICT`, not a separate pre-check against a possibly-uncommitted row. Must stay atomic at up to ~50,000 msgs/sec peak (requirement-spec §3) |
| `notification_preferences` `PRIMARY KEY (user_id)` | The opt-out check's `SELECT ... WHERE user_id = $user_id`, run on (effectively) every send attempt per `design-decisions.md`'s no-cache decision | Direct point lookup by the aggregate's own identity — the only query pattern this table ever serves; must stay a single indexed read to hold the throughput budget without a cache layer |
| `idx_notification_attempts_user_audit (user_id, created_at)` | "What notifications has this user received" — support/ops audit lookup implied by requirement-spec §4 Domain Invariant #1's audit-trail purpose | No formal endpoint exists for this (`api-contract.yaml`: no API surface at all), but the invariant that every event resolve into an auditable record implies internal tooling needs a way to query it per-user; without this index that query degrades to a full cross-partition scan |
| `idx_notification_attempts_failed (created_at) WHERE status = 'Failed'` | Ops/admin DLQ-inspection tooling: "show every terminally-failed send attempt" | Direct implementation of BRD §8.2's "failures are inspected via admin tooling, never silently dropped" philosophy; partial index keeps the scan bounded since `Failed` is expected to be a small fraction of all attempts |

| `order_user_index` `PRIMARY KEY (order_id)` | `userId` resolution for eight `orderId`-keyed triggering events; the `ON CONFLICT (order_id) DO NOTHING` seed-on-`OrderCreated` upsert | Direct point lookup by the only key this table is ever queried on (ADR-0020) |
| `tracking_order_index` `PRIMARY KEY (tracking_id)` | `orderId` resolution for `DeliveryStatusUpdated`, chained into `order_user_index` | Direct point lookup by the only key this table is ever queried on (ADR-0020) |

No index is added for JSONB containment queries against `opt_out_matrix` (e.g. a GIN index) — the only query pattern this column serves is "fetch the one row for this `user_id`, then inspect the map in application code" (the combined query above), never a `WHERE opt_out_matrix @> ...` scan across many users' rows. Adding one would be exactly the kind of speculative index this stage's own standard (`database-design-agent.md`: "no speculative indexes") warns against.

## GDPR Erasure (ADR-0016) — Checked, One Discrepancy Flagged (Non-Blocking)

ADR-0016's own Context section names "Notification (audit trail of sent messages, BRD §5.4)" as one of the platform services expected to hold userId-linked PII and pick up a `UserDataErased` redaction responsibility. Checked against the schema actually approved by this service's own `ddd-model.md`, that expectation does not hold in the form ADR-0016's introductory framing implied: `notification_attempts` and `notification_preferences` carry `user_id` purely as an **opaque referential key** (owned by `kart-identity-service`) and hold no other directly-identifying field anywhere in either table — no name, email address, phone number, or message body/content is persisted (channel-specific delivery addresses are resolved at send time via the channel adapter's own lookup against Identity/User profile data, never written to this schema). This is the identical conclusion `kart-payment-service/database-design.md` reaches for `payment_intents` ("There is nothing here to redact, and therefore no reason... to consume `UserDataErased`") — for the same reason: `user_id` surviving indefinitely as an opaque key is exactly what ADR-0016 item 3 already asks retained-history tables to do ("keep `userId` as an opaque referential key but have their own copies of directly-identifying fields... tombstoned"); there are simply no such fields here to tombstone.

**Flagged, not silently resolved:** ADR-0016's framing of "Notification's audit trail" as a PII-bearing table predates this service's own full `ddd-model.md` pass, which fixed a narrower field list than that framing assumed. This schema does not need to consume `UserDataErased`, and neither `requirement-spec.md`, `edge-cases.md`, `architecture.md`, nor `ddd-model.md` for this service names it as a consumed event — consistent with, not contradicting, the actual approved DDD model. If a future requirements pass adds a field to either table that does carry directly-identifying PII (e.g., a raw delivery address persisted for debugging), that would be the trigger to add `UserDataErased` consumption then, not a gap in this schema today.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner
- [x] Approved (write-model schema)
