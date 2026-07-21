---
doc_type: adr
status: accepted
---

# ADR-0006: Identity → User Profile Sync via `UserAccountUpdated`

## Status

Accepted

## Context

`kart-requirements.md` had a `UserRegistered` event (Identity → User) for initial account creation, and User Service's own `UserProfileUpdated` event for profile changes User itself manages (addresses, preferences). No event existed for the case where an Identity-side field — login email, display name used at auth time — changes *after* registration and needs to reach User Service's profile copy. `docs/services/README.md` tracked this as an open cross-service contradiction; both `kart-identity-service`'s and `kart-user-service`'s docs surfaced the ownership ambiguity (User's docs correctly flagged it and were approved on that basis; Identity's docs did not, one of several reasons that service's review came back NEEDS-WORK).

## Decision

Identity Service owns login-credential-adjacent identity fields (login email, display name shown at auth time) as the source of truth for *those specific fields*; User Service owns the broader profile (addresses, preferences) but keeps a denormalized copy of email/display name for its own reads (e.g., showing account info without a cross-service call).

When Identity's copy of email or display name changes, Identity publishes a new event, **`UserAccountUpdated`** (payload: `userId`, `email`, `displayName`), which User Service consumes to reconcile its denormalized copy — the same "every index is a derived, rebuildable projection" pattern the platform blueprint already applies to the control plane's own knowledge base (`PLATFORM_BLUEPRINT.md` §1), applied here to a cross-service field sync instead of a read-model.

Naming follows the existing convention (`UserRegistered`, `UserProfileUpdated`) rather than introducing a new verb pattern.

## Consequences

- User Service's profile read path never needs a synchronous call to Identity to show current email/display name — it stays eventually consistent via this event, consistent with the platform's CQRS-style design elsewhere.
- Identity must publish this event on every login-email or display-name change, not just at registration — a new responsibility that needs to be added to `kart-identity-service`'s requirement-spec.md (already flagged as missing during the professional-grade review, alongside the §24.1/§24.2 SSO/RBAC gaps).
- `kart-user-service`'s docs already anticipated this and can simply cite this ADR as the resolution to their open question.
