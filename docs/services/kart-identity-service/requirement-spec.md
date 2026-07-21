---
doc_type: requirement-spec
service: kart-identity-service
status: pending-approval
generated_by: requirement-agent
source: docs/requirements/kart-requirements.md
---

# Requirement Spec: kart-identity-service

## 1. Scope

Covers the single BRD service **Identity Service** (BRD §2.1 item 1): "AuthN, tokens, sessions, MFA." No merge; no ADR applies. This is the only service in the BRD's core-modules table that no other row's Scope note or event catalog entry references as a merge candidate.

The BRD's treatment of Identity is condensed relative to Order/Inventory/Payment (which get dedicated deep-dive sections, §5.1–5.3). Identity only appears as one row in the "remaining services" table (§5.4) plus scattered mentions in the cross-cutting Security (§24) and API Gateway (§18) sections. This spec draws on those scattered mentions but does not invent detail the BRD doesn't state — see §6 for the resulting gaps.

## 2. Functional Requirements

- Authenticate a user and issue tokens (`POST /auth/login`, BRD §5.4).
- Refresh an access token (`POST /auth/refresh`, BRD §5.4).
- Register a new user identity, publishing `UserRegistered` on success (BRD §5.4; consumed by User Service per its own row in §5.4, "Consumes: `UserRegistered`").
- Create a session on successful authentication, publishing `SessionCreated` (BRD §5.4).
- Support multi-factor authentication (BRD §2.1 item 1: "...MFA") — the BRD names MFA as a responsibility but specifies no mechanism (TOTP, SMS OTP, WebAuthn, email code); see Open Questions.
- Issue JWTs consumed by the API Gateway for edge validation (BRD §18: "JWT validated at gateway edge; downstream services trust a signed internal header, not the raw client token") — this implies Identity is the token issuer, though the BRD never states this outright; see Open Questions.
- Support OAuth2 Authorization Code flow for web/mobile clients and Client Credentials flow for service-to-service auth (BRD §24, Security §AuthN row). The BRD does not say which service terminates these flows (Identity vs. the Gateway itself); see Open Questions.
- Maintain a token revocation list, checked at logout (BRD §24: "...revocation list for logout").
- Support session lifecycle management implied by "sessions" (BRD §2.1 item 1) and `SessionCreated` (§5.4) — the BRD does not state a session termination/expiry event (no `SessionExpired` or `SessionRevoked` in the event catalog, §10); see Open Questions.

## 3. Non-Functional Requirements

Pulled from the BRD's global NFR table (§3) and the cross-cutting Security section (§24), scoped to this service:

| Attribute | Target | Applies here because |
|---|---|---|
| Availability | 99.99% (order path) or 99.9% (secondary)? — BRD §3 splits the two tiers only by "order path" vs. "secondary," and does not place Identity in either explicitly. Every authenticated request depends on Identity per the Gateway's JWT model (§18), which argues for the 99.99% tier, but the BRD never says so; see Open Questions | Auth gates all authenticated traffic through the Gateway (§18) |
| Latency | P95 < 150ms, P99 < 400ms (read path); P95 < 300ms (write path, includes Outbox insert) | `/auth/login` and `/auth/refresh` are on the request-critical path for every authenticated call |
| Consistency | Strong (PostgreSQL write path) per BRD §3's general write-path rule; Identity's DB is PostgreSQL (§5.4) | Login/session/token state cannot be eventually consistent — a stale "not authenticated" or "still valid" read is a security defect, not a UX one |
| Reliability | At-least-once delivery + idempotent consumers (BRD §3 general rule) | Applies to `UserRegistered`/`SessionCreated` publication; BRD gives Identity no explicit retry/DLQ row in the Event Catalog (§10) — see Open Questions |
| Security | Zero plaintext secrets, signed tokens, TLS everywhere; JWT short-lived + refresh rotation (BRD §3, Security row); short-lived access tokens (~15 min), rotating refresh tokens, revocation list for logout, AES-256 at rest for PII (BRD §24) | This is Identity's core NFR — it is the service that issues and rotates the tokens the rest of the platform trusts |
| Observability | 100% trace coverage on order path (BRD §3/§23) — Identity is not on the order path itself, but every traced request downstream carries a correlation ID Identity's login/refresh calls must originate | Auth calls are the first hop of most traced request chains |

## 4. Domain Invariants

- A refresh token must be single-use and rotated on every refresh (BRD §24: "rotating refresh tokens") — reusing a refresh token after rotation must be detectable, though the BRD does not state what happens on reuse (revoke the session? revoke all sessions for the user?); see Open Questions.
- A revoked token (post-logout) must never be accepted again, regardless of its stated expiry (BRD §24: "revocation list for logout").
- An access token's validity window must not exceed the BRD's stated ~15 minutes (BRD §24, Token Lifecycle row).
- `UserRegistered` must be published exactly once per successful registration and must be idempotent-safe for the User Service consumer (BRD §3 general Reliability rule; §5.4 shows User consuming `UserRegistered`).
- PII (at minimum, credentials and any stored personal identifiers) must be encrypted at rest with AES-256 (BRD §24, Encryption row) and never logged in plaintext (implied by BRD §23's structured-logging discipline, though not stated specifically for Identity).

## 5. API Surface (from BRD, starting point only)

| Endpoint/Event | Direction | Notes |
|---|---|---|
| `POST /auth/login` | Inbound API | BRD §5.4 |
| `POST /auth/refresh` | Inbound API | BRD §5.4 |
| `UserRegistered` | Published | Consumed by User Service (BRD §5.4); absent from the Event Catalog at §10 — see Open Questions |
| `SessionCreated` | Published | No consumer listed anywhere in the BRD (§5.4 or §10) — see Open Questions |

No logout, MFA-challenge, or password-reset endpoint appears in the BRD at all. No consumed events are listed for Identity (§5.4 shows "—" under Consumes). Final contract is the API Design Agent's job, not this spec's.

## 6. Open Questions / Flagged Ambiguities

1. **MFA mechanism unspecified.** BRD §2.1 item 1 names MFA as a responsibility but no other section names a mechanism (TOTP/SMS/WebAuthn/email code) or when it's required (always vs. step-up for sensitive actions). Cannot be inferred from the rest of the BRD. Blocking for any MFA-related functional requirement beyond "must exist in some form."
2. **Session TTL unspecified.** BRD §24 gives access-token (~15 min) and refresh-token rotation but never states a session lifetime, idle timeout, or absolute session cap. `SessionCreated` (§5.4) has no corresponding termination event.
3. **Refresh-token reuse/theft response unspecified.** BRD §24 states rotation but not the detection/response policy (revoke single session vs. revoke all sessions for the user vs. just deny) if a rotated-out refresh token is replayed.
4. **Token issuer identity unconfirmed.** BRD §18 says the Gateway validates JWTs at the edge and downstream services trust a signed internal header instead of the raw token, which implies Identity mints the JWTs — but no BRD section says this explicitly, and it's equally readable as the Gateway itself owning token minting with Identity only validating credentials. Architecturally significant; needs human confirmation before the Architecture Agent draws the trust boundary.
5. **OAuth2 flow termination point unconfirmed.** BRD §24 states Authorization Code (web/mobile) and Client Credentials (service-to-service) flows exist, but not which component (Identity vs. Gateway) terminates them.
6. **`UserRegistered` / `SessionCreated` missing from the Event Catalog (§10).** The Event Catalog table lists retry count and DLQ strategy for every other cross-service event but has no rows for either Identity event, even though §5.4 states them as published. Retry/DLQ policy for these two events is therefore undefined — carried to the Event Design Agent stage, but flagged here since it's a direct BRD gap, not a downstream design choice.
7. **No consumed events.** BRD §5.4 shows Identity consuming nothing ("—"). This seems surprising for a service that presumably needs to react to, e.g., an account-deletion or admin-lock action from the Admin Service (`AdminActionPerformed`, §5.4) — but the BRD does not state this integration, so it is not assumed here.
8. **Availability tier unassigned.** BRD §3 splits Availability into "99.99% (order path)" and "99.9% (secondary)" but never places Identity in either tier explicitly, despite Identity gating all authenticated traffic per the Gateway model (§18). Left to the Architecture Agent to resolve with a human decision, not inferred here.
9. **No password-reset, logout, or MFA-challenge endpoint stated.** Only `/auth/login` and `/auth/refresh` appear anywhere in the BRD (§5.4). Whether these are BRD omissions (expected to exist but under-specified) or genuinely out of scope for this pass is not stated.

## Sign-off

- [ ] Blocking open questions resolved (Q1–Q5 in particular)
- [ ] Reviewed by:
- [ ] Approved to proceed to Architecture Agent
