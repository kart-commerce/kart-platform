---
doc_type: database-design
service: kart-admin-service
status: pending-approval
generated_by: database-design-agent
source: docs/services/kart-admin-service/requirement-spec.md, docs/services/kart-admin-service/edge-cases.md, docs/services/kart-admin-service/design-decisions.md, docs/services/kart-admin-service/architecture.md, docs/adr/0010-admin-service-scope-and-integration.md
---

# Database Design: kart-admin-service

No `ddd-model.md` exists for this service — ADR-0010's Consequences section already fixes Admin's domain shape as narrow enough to design directly from `requirement-spec.md` §4/§6, `edge-cases.md`, `design-decisions.md`, and `architecture.md`: "Admin's own DDD model has exactly one aggregate root of its own consequence — the admin action / permission grant — never a `Product`, `Category`, `Coupon`, or `InventoryStock` aggregate." Consistent with that and with Domain Invariant #3 (`requirement-spec.md` §4: "Admin Service never becomes a second owner of another service's domain data"), this write model holds exactly two Admin-owned tables and nothing else — no local copy of Product/Category/Coupon/user-identity/Inventory data.

Write model is PostgreSQL (source of truth) for both tables. No read model (MongoDB/Redis) is introduced: Admin has no read-heavy, latency-budgeted query path of its own (it is absent from the Order Saga and BRD §5.5's diagram — secondary availability tier, no dedicated customer-facing latency SLA, per `requirement-spec.md` §3 Decision D4), and `design-decisions.md`'s "Caching Strategy for Fine-Grained Permission Grants" decision explicitly rules out any cache (including Redis) in front of the permission-grant lookup, to avoid reopening the staleness window `edge-cases.md`'s "Stale Admin Permission Outliving an Identity-Side Revocation" closes. `AdminActionPerformed` is published via the standard PostgreSQL Outbox pattern (BRD §11), not projected into a separate read store — Analytics is the sole consumer and reads the event off the queue, not off Admin's database.

## Write Model (PostgreSQL)

```sql
-- Fine-grained permission grant record (requirement-spec.md §6 Decision item 1, Domain Invariant #1)
-- One row per grant lifecycle event (issue or re-issue); revocation is an UPDATE on the live row,
-- never a delete, so grant/revoke history is preserved for the same audit reasons the Security NFR
-- and Decision item 3 (audit completeness) require elsewhere in this service.
CREATE TABLE admin_permission_grants (
    grant_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    principal_id    TEXT NOT NULL,          -- Identity-issued principal id; no FK — Identity, not Admin, owns this identifier (Domain Invariant #1)
    category        TEXT NOT NULL CHECK (category IN (
                        'catalog-management',
                        'coupon-issuance',
                        'user-suspension',
                        'inventory-replenishment',
                        'permission-management'   -- meta-category: grants/revokes the other four (requirement-spec.md §6 Decision item 1)
                    )),
    granted_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    granted_by      TEXT NOT NULL,           -- principal id of the granting admin, or 'seed-script' for the one-time out-of-band bootstrap of the first permission-management grant
    revoked_at      TIMESTAMPTZ NULL,
    revoked_by      TEXT NULL,
    version         INT NOT NULL DEFAULT 1  -- optimistic concurrency for revoke writes (design-decisions.md, "Concurrency Control for Back-Office Writes")
);

-- At most one *live* (non-revoked) grant per (principal, category) — this is the single source of
-- truth "which of the four categories can this Admin-role holder actually exercise" (Domain Invariant #1),
-- and it is what every /admin/* handler reads fresh, uncached, on every request.
CREATE UNIQUE INDEX uq_admin_permission_grants_live
    ON admin_permission_grants (principal_id, category)
    WHERE revoked_at IS NULL;

-- Admin's audit trail AND its Outbox row for AdminActionPerformed are the same table (requirement-spec.md
-- §6 Decision item 3: "the outbox/admin-action table is append-only ... only the poller's published_at
-- column mutates"). A row is written exactly once, in the same local transaction as the completed
-- back-office action, only after the synchronous outbound call to the owning service (Product, Category,
-- Offer, Identity, or Inventory) has already succeeded (Domain Invariant #2; design-decisions.md,
-- "Audit Trail Publication Atomicity").
CREATE TABLE admin_actions (
    action_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    idempotency_key  UUID NOT NULL,          -- design-decisions.md "Idempotency Mechanism for Outbound Write Calls" — generated once per admin-action attempt, forwarded to the owning service on every retry
    admin_id         TEXT NOT NULL,          -- Identity-issued principal id of the acting admin; AdminActionPerformed payload field `adminId`
    category         TEXT NOT NULL CHECK (category IN (
                        'catalog-management',
                        'coupon-issuance',
                        'user-suspension',
                        'inventory-replenishment',
                        'permission-management'
                    )),
    action           TEXT NOT NULL,          -- specific operation within the category, e.g. 'product.create', 'product.deactivate', 'category.reorder', 'coupon.create', 'coupon.deactivate', 'user.lock', 'user.unlock', 'inventory.replenish', 'grant.issue', 'grant.revoke'; AdminActionPerformed payload field `action`
    entity_id        TEXT NOT NULL,          -- id of the mutated entity in the owning service (Product id, Category node id, Coupon code, user id, Inventory SKU, or admin_permission_grants.grant_id for permission-management); AdminActionPerformed payload field `entityId`; no FK — the owning service, never Admin, is that entity's source of truth (ADR-0010 Decision 2)
    context          JSONB NULL,             -- optional richer audit detail (e.g. request payload sent downstream) beyond the three fields the AdminActionPerformed event actually carries; supports Decision item 3's "authoritative, sole audit trail" without widening the published event's contract
    performed_at     TIMESTAMPTZ NOT NULL DEFAULT now(), -- this table's BRD §24.3 created_at equivalent, together with admin_id as its created_by equivalent — kept under their existing domain names, not duplicated
    published_at     TIMESTAMPTZ NULL,       -- set only by the Outbox poller after successful publish; the one column exempt from this table's append-only rule (requirement-spec.md §6 Decision item 3)
    published_by     TEXT NULL               -- BRD §24.3 — new column, closing the one genuine gap: published_at previously had no actor. Always "system:admin-outbox-poller" once set; NULL exactly when published_at is NULL (no mutation has happened yet)
);

CREATE UNIQUE INDEX uq_admin_actions_idempotency_key
    ON admin_actions (idempotency_key);

CREATE INDEX idx_admin_actions_unpublished
    ON admin_actions (performed_at)
    WHERE published_at IS NULL;

CREATE INDEX idx_admin_actions_admin_category
    ON admin_actions (admin_id, category, performed_at);
```

## Row-Level Security Policy (BRD §24.1.4)

Per BRD §24.1.4, the service whose database physically holds a row decides and enforces that row's row-level security — this platform's own §24.1.4 text names Admin's `admin_permission_grants` explicitly as the worked example of a table keyed on `(principal_id, category)`, not `user_id`. Admin's write model is 100% PostgreSQL, so native RLS is the mechanism for both tables.

**Session-scoped principal setting.** Same ambient mechanism established platform-wide (`kart-identity-service/database-design.md`'s precedent): immediately after acquiring a pooled connection, this service issues `SET LOCAL app.current_principal = <id>`, resolved server-side from the validated `Admin`-role JWT — never client-suppliable. This is the same resolved-principal value the shared `kart-shared` `created_by`/`updated_by` interceptor (§24.3, above) stamps onto every mutation.

**`admin_permission_grants` — not a simple ownership predicate.** Unlike most RLS-scoped tables on this platform, a principal legitimately needs to read/write *another* principal's row here: issuing or revoking someone else's grant is exactly what the `permission-management` meta-category exists to do (requirement-spec.md §6 Decision item 1). The policy therefore mirrors the same live-grant check the application layer already runs (`uq_admin_permission_grants_live`), expressed as a same-table subquery rather than a plain `principal_id = current_setting(...)` comparison:

```sql
ALTER TABLE admin_permission_grants ENABLE ROW LEVEL SECURITY;
CREATE POLICY admin_permission_grants_self_or_grant_manager ON admin_permission_grants
    USING (
        principal_id = current_setting('app.current_principal')
        OR EXISTS (
            SELECT 1 FROM admin_permission_grants g
            WHERE g.principal_id = current_setting('app.current_principal')
              AND g.category = 'permission-management'
              AND g.revoked_at IS NULL
        )
    );
```

This is additive, database-layer enforcement of the exact same rule the API handler for `POST /admin/permission-grants`/`.../revoke` and `GET /admin/permission-grants` already checks (api-contract.yaml) — not a new rule invented at this layer. A principal with no live `permission-management` grant can still see their own row (self-service visibility of "what can I currently do"), but never another principal's, which the application-layer check (§24.1.2) already independently enforces before a request reaches this table at all; RLS's marginal protection is the same one BRD §24.1.4 names generally — a code path that forgets its own permission check stays blocked here regardless.

**`admin_actions` — coarse-role read, not row-ownership.** Per requirement-spec.md's amended Domain Invariant (§4) and api-contract.yaml's own stated rule ("No fine-grained category check applies to this read-only audit view"), `GET /admin/actions` is deliberately readable by any principal holding the coarse `Admin` claim, not scoped to `admin_id = caller`. RLS here therefore does not restrict by row-ownership either — restricting audit visibility to "only the admin who performed the action" would contradict the audit trail's own stated purpose (any admin must be able to review any other admin's actions). The database-layer control for this table is coarser than per-row: only Admin Service's own application role may query `admin_actions` at all (no direct external connection), and the coarse-`Admin`-claim check happens at the API layer (§24.1.3 check #2) before any query runs — there is no additional per-row predicate BRD §24.1.4 would add on top without contradicting the invariant that just fixed this table's intended visibility.

## Sensitive / PII Column Classification (BRD §24.1.5)

Column-level security answers a narrower question than row-level security: of the columns in a row a caller already has `CanRead` on (BRD §24.1.2), which does that caller's own coarse role actually see — full value, masked, or nothing. This service is BRD §24.1.5's own cited worked example, so the classification below grounds directly in that table rather than deriving one from scratch.

| Column | Full Value Visible To | Masked/Omitted For | Masking Rule |
|---|---|---|---|
| `admin_actions.context` | Admin holding a live grant for that action's category (§24.1.2) | Support Agent, Customer | Back-office action detail is not customer-facing data and is scoped to the same category-grant check §24.1.2 already applies to the action itself — identical treatment to BRD §24.1.5's own `admin_actions.metadata` example, `context` being this schema's actual column name for that same field |
| `admin_permission_grants.granted_by` / `revoked_by` | Admin holding a live `permission-management` grant, or the row's own `principal_id` (self-visibility, per the RLS policy above) | Support Agent, Customer | These identify which admin issued/revoked a grant — back-office operational data, not customer PII; visible to whoever the RLS policy above already allows to reach the row at all, since there is no narrower masking need once row-level access is already this restricted |

**Why this list and no more:** `admin_permission_grants.principal_id`/`category`/`granted_at`/`revoked_at`/`version` and `admin_actions.admin_id`/`category`/`action`/`entity_id`/`performed_at`/`published_at`/`published_by` carry no PII — they are operator/operational identifiers and timestamps, not personal data about a customer. Neither table stores any customer-facing PII column at all (`entity_id` is an opaque reference to another service's own entity — a Product id, Coupon code, user id, or Inventory SKU — never a denormalized copy of that entity's own PII fields), consistent with Domain Invariant #4 (§4): Admin never becomes a second owner, and therefore never a second custodian, of another service's PII.

**Enforcement point:** primarily this service's own response-serialization DTO (api-contract.yaml) shaping `admin_actions.context` per the caller's category-grant status, per §24.1.5's stated primary control; secondarily, for any direct database connection bypassing this service's own API (an ops/BI tooling query), native `GRANT SELECT (col1, col2, ...) ON admin_actions TO <db_role>` restricted to exclude `context` for any database role other than this service's own application role — no such secondary direct-access role exists today per this document, so this is the defense-in-depth control to apply if/when one is added.

## Indexing Rationale

| Index | Query it supports | Why needed |
|---|---|---|
| `uq_admin_permission_grants_live` (partial unique, `revoked_at IS NULL`) | The fine-grained authorization check every `/admin/*` handler runs — "does `(principal_id, category)` have a live grant" | `design-decisions.md`'s "Caching Strategy for Fine-Grained Permission Grants" mandates this be an uncached, indexed point-lookup on every request; the same index doubles as a DB-enforced invariant (at most one live grant per principal/category), matching Domain Invariant #1's single-source-of-truth requirement for this layer |
| `uq_admin_actions_idempotency_key` | Dedupe check before/while retrying an admin-action attempt | Backs `design-decisions.md`'s "Idempotency Mechanism for Outbound Write Calls" — a retried attempt (after the bounded-retry resilience decision) must not produce two local audit rows for one logical action |
| `idx_admin_actions_unpublished` (partial, `published_at IS NULL`) | The Outbox poller's "find rows not yet published" scan | Standard Outbox mechanics (BRD §11); keeps the poller a cheap index range-scan rather than a full-table scan as the 5-year-retention audit table grows (requirement-spec.md §6 Decision item 3) |
| `idx_admin_actions_admin_category` | Audit/compliance queries — "what did this admin do, in which category, over what window" — the pattern `kart-analytics-service`'s audit/compliance dashboard (requirement-spec.md §3 Observability) and any manual compliance review would run against 5 years of rows | Without this, a compliance lookup against a multi-year append-only table degrades to a full scan; this is the one query pattern the Observability NFR and Decision item 3's retention commitment imply beyond the poller's own scan |

## Partitioning/Sharding

Not needed at current scale for either table. `admin_permission_grants` is bounded by the number of admin principals times five categories — a small, slow-growing table by construction (back-office operators are a tiny population relative to any customer-facing entity count). `admin_actions` accumulates one row per human-paced back-office action (requirement-spec.md §3 Decision D4: "Admin actions are infrequent and human-paced relative to customer-facing traffic") — confirmed absent from the Order Saga and every high-throughput path in the BRD's capacity plan (§4.3), so even at 5-year retention (Decision item 3) this table's write volume is orders of magnitude below Order/Payment's. Single-table PostgreSQL is sufficient; if the 5-year retention window later proves to make `admin_actions` unwieldy for compliance queries or backup/restore time, range-partitioning it by `performed_at` (e.g., yearly) with older partitions moved to cold storage is the natural next step — flagged as a later cost detail per requirement-spec.md §6 Decision item 3's own "tiered to cold storage as a later cost detail" note, not decided here since no throughput evidence currently calls for it.

## Sign-off

- [ ] Reviewed by: _pending human review_
- [ ] Approved (write-model schema)
