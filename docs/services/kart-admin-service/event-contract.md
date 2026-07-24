---
doc_type: event-contract
service: kart-admin-service
status: approved
generated_by: event-design-agent
source: docs/services/kart-admin-service/requirement-spec.md, docs/services/kart-admin-service/edge-cases.md, docs/services/kart-admin-service/architecture.md, docs/services/kart-admin-service/design-decisions.md, docs/services/kart-admin-service/ddd-model.md, docs/adr/0007-event-catalog-completeness.md, docs/adr/0010-admin-service-scope-and-integration.md
---

# Event Contract: kart-admin-service

**Superseded note (corrected on this pass):** this section previously read "No `ddd-model.md` exists for this service," citing the same basis `database-design.md` originally recorded. `docs/services/kart-admin-service/ddd-model.md` has since been authored — formalizing Admin's shape as **two** aggregate roots, `AdminPermissionGrant` and `AdminAction`, refining ADR-0010's slash-joined "the admin action / permission grant" shorthand rather than contradicting it. `AdminAction` is the sole source of this service's one published event: `ddd-model.md`'s own Domain Events section for that aggregate states `AdminActionPerformed` is "raised by the Outbox poller once this row's own local commit has landed" — fully consistent with this document's table below, no rework needed.

Exchange: `ecommerce.events` (per [kart-conventions.md](../../standards/kart-conventions.md)). Every consumer queue below gets its own DLQ per the reusable event standard — never shared.

| Event | Routing Key | Published/Consumed | Key Fields | Retry | DLQ | Criticality Justification |
|---|---|---|---|---|---|---|
| `AdminActionPerformed` | `admin.admin-action.performed` | Published (Analytics) | `adminId`, `action`, `entityId` | 1x | `admin.admin-action-performed.dlq` | Fire-and-forget audit tier — see below. Own DLQ per the reusable event standard's "never shared" rule (`event-standards.md`), rather than reusing ADR-0007's simplified shared `admin.dlq` label (the same correction `kart-offer-service/event-contract.md` already made for its own BRD-simplified DLQ names) |

No consumed events. BRD §5.4 lists "—" under Admin's "Key Events Consumed" column, and `requirement-spec.md` §2/§5 and `architecture.md`'s Dependencies table both confirm this as intentional, not a gap: every `/admin/*` action is synchronously human/operator-initiated, and the one plausible event-reactive candidate (inventory replenishment) is an automated trigger Inventory Service owns for itself, not something Admin Service consumes an event to perform.

## Naming-Convention Compliance

`AdminActionPerformed` = Entity `AdminAction` (the one aggregate root ADR-0010's Consequences section grants this service) + past-tense verb `Performed` — compliant with the `<Entity><PastTenseVerb>` convention (`event-standards.md`). Routing key follows the `service.entity.action` convention (`kart-conventions.md`): `admin.admin-action.performed`.

## Retry-Tier Justification: Fire-and-Forget Audit Tier, Not a Higher One

**Chosen: 1x retry, `admin.admin-action-performed.dlq`, no on-call paging on final failure** — the same tier ADR-0007 assigns this event ("audit-only, same fire-and-forget tier as `NotificationSent`") — but restated here against this service's own actual failure-mode risk, per this stage's own responsibility, rather than copied forward unexamined:

- **The durable audit record does not depend on this RabbitMQ delivery succeeding.** `database-design.md`'s `admin_actions` table is Admin's own local, append-only, 5-year-retention record of every back-office action (`requirement-spec.md` §6 Decision item 3), written in the same PostgreSQL transaction as the triggering write via the Outbox pattern (Domain Invariant #2, `edge-cases.md`'s "Admin Action Succeeds but `AdminActionPerformed` Is Lost"). If this event exhausts its 1 retry and lands in `admin.admin-action-performed.dlq`, the underlying fact of what the admin did is *not* lost — it is durably sitting in `admin_actions`, independently queryable via `idx_admin_actions_admin_category` for exactly the compliance-review scenario the Observability NFR names. What is at risk on final failure is only Analytics' downstream copy of that fact for its "Admin audit/compliance dashboard" (`kart-analytics-service/requirement-spec.md` §1), which is recoverable by DLQ inspection/replay rather than gone.
- **This is a materially different risk shape than a `Payment*`-tier event**, where the event *is* the only record of a state transition a downstream service must act on to stay correct (e.g., a refund). Here, Admin's own database is already the authoritative source of truth for the audit trail — the event is a fan-out copy for Analytics' reporting, not the sole record of anything. Escalating retry/paging here would treat a reporting-delivery risk as if it were a money-moving or oversell risk, which it is not.
- **Consumer assignment (Analytics only) is correct, not incomplete**, notwithstanding ADR-0004's platform-wide "Analytics is a consumer of every event by default" rule: no other service is named or inferable as a synchronous consumer of `AdminActionPerformed` anywhere in the BRD, `requirement-spec.md`, or `architecture.md` — it is Admin's sole published event and Analytics is its sole stated purpose (audit trail).

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner
- [x] Approved
