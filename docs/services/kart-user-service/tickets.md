---
doc_type: tickets
service: kart-user-service
status: approved
generated_by: ticket-agent
source: [architecture.md, ddd-model.md, api-contract.yaml, database-design.md, event-contract.md, design-decisions.md, requirement-spec.md, edge-cases.md]
---

# Tickets: kart-user-service

Local draft. Not yet created as real GitHub Issues — that requires the target repo to exist (Project Scaffold Agent) and is a separate, explicit step.

## Epic: kart-user-service v1

Profile, address book, and preference management (BRD §2.1 item 2), modeled as one aggregate (`UserProfile`, with `Address` as a child entity — `ddd-model.md`'s aggregate-boundary resolution). PostgreSQL is the strongly-consistent write side; `user_read_model` (MongoDB) is the eventually-consistent read side. Denormalizes a copy of Identity-owned email/display-name (ADR-0006) and implements the platform's GDPR-style erasure workflow (ADR-0016), whose intake caller is Admin Service (ADR-0017).

| ID | Task | Vertical Slice (Application/Features/) | Depends On | Design Source |
|---|---|---|---|---|
| USR-1 | Create a user profile on `UserRegistered` | `CreateUserProfileOnRegistration` | — | `event-contract.md` `UserRegistered` (consumed, `user.user-registered.dlq`); `ddd-model.md` `UserProfile` aggregate-creation invariant; `database-design.md` `user_profiles`, `user_outbox_events` |
| USR-2 | Get a user's profile | `GetUserProfile` | USR-1 | `api-contract.yaml` `GET /v1/users/{userId}`; `database-design.md` `user_read_model` point-read by `_id` |
| USR-3 | Update preferences and the app-installed signal | `UpdateUserPreferences` | USR-1 | `api-contract.yaml` `PATCH /v1/users/{userId}`; `ddd-model.md` Modeling Decision 2 (both `UserProfileUpdated` and `UserNotificationPreferenceUpdated` fire on a preference-touching write); `event-contract.md` both events, per-consumer-group DLQs |
| USR-4 | Add an address | `AddAddress` | USR-1 | `api-contract.yaml` `POST /v1/users/{userId}/addresses` (format-only validation, `400` on failure); `ddd-model.md` default-address invariant; `database-design.md` `addresses`, `idx_addresses_one_default_per_type`; `event-contract.md` `UserProfileUpdated` |
| USR-5 | Update an address, including its default flag | `UpdateAddress` | USR-4 | `api-contract.yaml` `PATCH /v1/users/{userId}/addresses/{addressId}`; `ddd-model.md`/`database-design.md` — setting `isDefault` clears any prior default of the same type in the same write; `event-contract.md` `UserProfileUpdated` |
| USR-6 | Remove an address | `RemoveAddress` | USR-4 | `api-contract.yaml` `DELETE /v1/users/{userId}/addresses/{addressId}`; `event-contract.md` `UserProfileUpdated` |
| USR-7 | Reconcile the denormalized Identity contact copy | `ReconcileIdentityContactCopy` | USR-1 | `event-contract.md` `UserAccountUpdated` (consumed, apply-if-newer via `updatedAt`, `user.user-account-updated.dlq`); `ddd-model.md` `contactCopy` invariant (never re-publishes `UserProfileUpdated` — Modeling Decision in ddd-model.md's Domain Events section) |
| USR-8 | Process a verified erasure request | `ProcessErasureRequest` | USR-1 | `api-contract.yaml` `POST /internal/v1/users/{userId}/erasure-requests` (Admin-called, ADR-0017, idempotent no-op on repeat); `ddd-model.md` `ErasureStatus` invariant (one-directional tombstone); `database-design.md` PII tombstone write; `event-contract.md` `UserDataErased` (compliance-critical tier, 7 per-consumer-group DLQs) |

## Notes for Sprint Planner Agent

- USR-1 has no dependencies — the foundation every other ticket needs (a `UserProfile` row to read, update, or erase).
- USR-2, USR-3, USR-4, and USR-7 all depend only on USR-1 and are independent of each other — all four can proceed in parallel once USR-1 lands.
- USR-5 and USR-6 both depend on USR-4 (an address must exist before it can be updated or removed) but are independent of each other.
- USR-8 depends only on USR-1 (a profile must exist to be tombstoned) — independent of every address/preference ticket, since erasure overwrites whatever state exists regardless of which fields have been touched.
- No circular dependencies in this graph; longest chain is USR-1 → USR-4 → USR-5 (or USR-6), 3 deep.
- USR-3 is one ticket, not two, despite publishing two events on the same write — both fire from the same single-aggregate write path with no independent trigger condition, so splitting them would split one cohesive use case across tickets.
