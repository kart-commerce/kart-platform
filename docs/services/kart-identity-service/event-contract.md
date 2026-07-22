---
doc_type: event-contract
service: kart-identity-service
status: approved
generated_by: event-design-agent
source: docs/services/kart-identity-service/requirement-spec.md, docs/services/kart-identity-service/edge-cases.md, docs/services/kart-identity-service/design-decisions.md, docs/services/kart-identity-service/architecture.md, docs/services/kart-identity-service/ddd-model.md, docs/adr/0004-analytics-full-fanin-ingestion.md, docs/adr/0006-identity-user-profile-sync-event.md, docs/adr/0007-event-catalog-completeness.md, docs/adr/0016-user-gdpr-erasure-policy.md, docs/requirements/kart-requirements.md
---

# Event Contract: kart-identity-service

## Pipeline Note

This contract was originally drafted before `ddd-model.md` existed for this service. That file has since been produced and approved — it confirms Identity's three published events and (now) one consumed event exactly as this contract already stated, with no contradiction. Status now `approved`.

Exchange: `ecommerce.events` (per [kart-conventions.md](../../standards/kart-conventions.md)). Every consumer queue below gets its own DLQ per the reusable event standard — never shared.

## Published Events

| Event | Routing Key | Published/Consumed | Key Fields | Retry | DLQ | Criticality Justification |
|---|---|---|---|---|---|---|
| `UserRegistered` | `identity.user.registered` | Published (User, Notification, Analytics) | `userId`, `email` | 3x | `identity.user-registered.dlq` | Above-standard, below money-critical tier — see below. Own DLQ per the reusable event standard's "never shared" rule (`event-standards.md`), splitting ADR-0006/ADR-0007's simplified shared `identity.dlq` label into one queue per event type — the same correction already made in `kart-offer-service/event-contract.md` (`coupon.dlq`), `kart-admin-service/event-contract.md` (`admin.dlq`), and `kart-cart-service/event-contract.md` for their own BRD-simplified shared DLQ labels. |
| `SessionCreated` | `identity.session.created` | Published (Analytics) | `userId`, `sessionId` | 2x | `identity.session-created.dlq` | Standard tier — see below. Own DLQ, same "never shared" split as above. |
| `UserAccountUpdated` | `identity.user-account.updated` | Published (User, Analytics) | `userId`, `email`, `displayName`, `updatedAt` | 2x | `identity.user-account-updated.dlq` | Standard tier — see below. Own DLQ, same "never shared" split as above. `updatedAt` is a **confirmed schema addition** this stage finalizes — see "Schema Finalization" below. |

**Consumer-set note on `UserAccountUpdated`:** `architecture.md`'s Dependencies table (drafted before `kart-requirements.md` §10's ADR-0008 pass was cross-checked against it) names only User Service as this event's consumer. The more authoritative, later-resolved source — `kart-requirements.md` §10 as corrected by ADR-0008, applying ADR-0004's platform-wide "Analytics consumes every event by default" rule — adds Analytics. This contract uses the corrected two-consumer set (User, Analytics); it does not change `architecture.md` itself (out of this stage's scope, per this agent's own remit), but the discrepancy is a stale omission in that document's Dependencies table, not a live cross-document contradiction requiring escalation — Analytics-as-default-consumer is a settled platform rule (ADR-0004), not a judgment call this stage is making unilaterally.

## Consumed Events

| Event | Consumed From | Key Fields | Retry | DLQ | Criticality Justification |
|---|---|---|---|---|---|
| `UserDataErased` | User Service | `userId`, `erasedAt` | 5x, exponential backoff, on-call paging on exhaustion | `identity.user-data-erased.dlq` | **Compliance-critical tier**, per ADR-0016 item 7's own stated policy ("the same high-retry-budget/human-paging tier the platform already reserves for money-critical events... an erasure event silently swallowed by DLQ is a compliance failure, not a tolerable staleness window"). This is the only event in Identity's contract at this tier — every published event above stays at the standard/above-standard tiers justified there, since none of them carry the same compliance-failure-on-loss risk. |

The admin-triggered account-suspension trigger (`POST /internal/users/{userId}/lock` / `.../unlock`) remains a synchronous internal REST call Admin Service makes against Identity's own API (ADR-0010; `design-decisions.md`, "Communication Style for Admin-Triggered Suspension"), not an event — `UserDataErased` above is Identity's only consumed event.

**Resolved, not a phantom row:** ADR-0016 has been updated to name Identity explicitly among the services expected to consume `UserDataErased` (closing the gap `architecture.md` previously flagged rather than silently deciding), and `requirement-spec.md` §2/§4/§5 now carry the corresponding FR, Domain Invariant, and API Surface row. `ddd-model.md`'s `UserIdentity` aggregate defines the redaction behavior this consumer triggers; `database-design.md` defines the exact write sequence.

## Naming-Convention Compliance

All three events follow the `<Entity><PastTenseVerb>` convention (`event-standards.md`):

- `UserRegistered` = Entity `User` + past-tense verb `Registered`.
- `SessionCreated` = Entity `Session` + past-tense verb `Created`.
- `UserAccountUpdated` = Entity `UserAccount` + past-tense verb `Updated`.

Routing keys follow the `service.entity.action` convention (`kart-conventions.md`): `identity.user.registered`, `identity.session.created`, `identity.user-account.updated` (kebab-case multi-word entity, matching the precedent already set by `admin.admin-action.performed` in `kart-admin-service/event-contract.md`). No collision was found against any event name already registered in another service's `event-contract.md`, `ddd-model.md`, or `kart-requirements.md` §10 — checked against every existing `docs/services/*/event-contract.md` and `docs/services/*/ddd-model.md` in this repo.

## Retry-Tier Justification

**`UserRegistered` — 3x retry, `identity.user-registered.dlq`, no on-call paging.** Restated against this service's own actual failure-mode risk, not copied forward from ADR-0007 unexamined:

- This is materially riskier to lose than a pure fan-out/audit event, because one of its three consumers — User Service — treats it as its **aggregate-creation trigger** (`kart-user-service/requirement-spec.md` §4: "a User Service profile record must not exist independent of a corresponding `UserRegistered` event"). A permanently-lost delivery (exhausted retries, unrecovered DLQ) leaves User Service with no profile record at all for a real, successfully-registered Identity account — a correctness gap in another service's write model, not just a stale read. That is a higher-stakes failure mode than `SessionCreated`'s or `UserAccountUpdated`'s (below), which justifies one more retry attempt than the standard 2x tier.
- It is not promoted to the `Payment*`/`RefundIssued` 5x-plus-paging tier: a lost `UserRegistered` delivery does not move money, oversell inventory, or leave two systems disagreeing about a financial state — it is recoverable via DLQ inspection/replay (User Service can be backfilled once the DLQ'd event is found), and Identity's own PostgreSQL row for the new account remains the authoritative, unaffected source of truth regardless of whether this event is ever successfully delivered.
- Consumer set (User, Notification, Analytics) matches ADR-0007's assignment and is re-confirmed current: Notification needs it for the welcome-email use case (`kart-notification-service/requirement-spec.md` §2: "`UserRegistered` (welcome email)"), Analytics per its standing full-fan-in default (ADR-0004).

**`SessionCreated` — 2x retry, `identity.session-created.dlq`, no on-call paging.** Standard tier: Analytics is its sole consumer, for login/session-tracking metrics only (`kart-requirements.md` §10; `architecture.md`'s Dependencies table). No other service's aggregate or authoritative state depends on this event's delivery — session state itself is fully owned and enforced by Identity's own Redis/PostgreSQL mechanisms (the revocation list, refresh-token rotation), independent of whether this event ever reaches Analytics. A lost delivery costs an inaccurate login-count metric, not a correctness gap anywhere else — the same risk class `event-standards.md` reserves the standard (not highest) tier for.

**`UserAccountUpdated` — 2x retry, `identity.user-account-updated.dlq`, no on-call paging.** Standard tier, matching ADR-0006's original assignment, restated against actual risk: unlike `UserRegistered`, User Service's consumption of this event is a **reconciliation of an already-existing, already-correct denormalized copy** (login email / display name), not an aggregate-creation trigger — a lost or delayed delivery leaves User Service's copy transiently stale until the next successful `UserAccountUpdated` publish, not permanently missing or inconsistent in a way nothing else can repair. This is a materially lower-stakes failure mode than `UserRegistered`'s, which is why it stays at 2x rather than matching that event's 3x, even though both originate from Identity and share a DLQ-naming pattern. The added `updatedAt` field (see below) further bounds the practical impact of a redelivered or reordered message.

## Schema Finalization: `UserAccountUpdated`'s `updatedAt` Field

`edge-cases.md`'s "Out-of-Order Delivery of Successive `UserAccountUpdated` Events" decision proposed adding a monotonic `updatedAt` (or sequence) field to `UserAccountUpdated`'s payload, beyond ADR-0006's original three-field shape (`userId`, `email`, `displayName`), so User Service can apply last-write-wins by version instead of by arrival order — and explicitly flagged it as "a proposed contract addition for the Architecture/Event-Design Agent to confirm when `UserAccountUpdated`'s schema is finalized, not assumed as already-approved." `design-decisions.md`'s "Event Publication Reliability" decision independently assumes the same field exists, for the same reason.

**Confirmed here, as this stage's own responsibility for event schemas:** `UserAccountUpdated`'s payload is `userId`, `email`, `displayName`, `updatedAt` (ISO-8601 timestamp of the write that triggered publication, monotonic per `userId`). User Service's consumer applies an incoming update only if `updatedAt` is strictly newer than the value it currently has stored for that `userId`, per `edge-cases.md`'s own decision. This is an additive change to ADR-0006's three-field shape, not a breaking one — existing/other consumers (Analytics, per the corrected consumer set above) can ignore the new field without needing a version bump under the platform's `event-standards.md` compatibility rule ("a breaking payload change requires a new version"). No new ADR is needed for this specific addition: it does not change consumer assignment, ownership, or direction — only adds one field to an already-approved event, consistent with `edge-cases.md`'s own framing of it as a low-risk, additive fix.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner
- [x] Approved
