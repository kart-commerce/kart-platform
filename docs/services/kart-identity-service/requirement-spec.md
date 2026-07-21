---
doc_type: requirement-spec
service: kart-identity-service
status: approved
generated_by: requirement-agent
source: docs/requirements/kart-requirements.md
---

# Requirement Spec: kart-identity-service

## 1. Scope

Covers the single BRD service **Identity Service** (BRD §2.1 item 1: "AuthN, tokens, sessions, MFA, SSO federation, RBAC role/claim issuance"). No merge; no ADR applies. This is the only service in the BRD's core-modules table that no other row's Scope note or event catalog entry references as a merge candidate.

Unlike the prior draft of this spec, Identity is **not** limited to the condensed §5.4 row and scattered §24 mentions. The BRD gives it two dedicated cross-cutting subsections — §24.1 "Cross-Cutting RBAC Model" and §24.2 "SSO / Identity Federation" — that state, in explicit prose (not implication), that Identity is the platform's single role issuer and the sole termination point for both enterprise SSO federation and customer social login. This redraft incorporates both; the prior draft predated them and treated their content as unresolved open questions (see §6). This spec draws on §2.1, §5.4, §10, §18, §24, §24.1, and §24.2, plus ADR-0006 and ADR-0007 for the two event-catalog gaps those ADRs closed — it does not invent detail beyond what those sources state; remaining gaps are named explicitly in §6.

## 2. Functional Requirements

**Core AuthN / token issuance**

- Authenticate a user and issue tokens (`POST /auth/login`, BRD §5.4).
- Refresh an access token (`POST /auth/refresh`, BRD §5.4).
- Act as the platform's single token issuer: mint the JWT the API Gateway validates at the edge (BRD §18: "JWT validated at gateway edge; downstream services trust a signed internal header, not the raw client token") and that every other service trusts. This is now stated directly, not just implied by §18 — BRD §24.1 says outright: "Identity Service is the single issuer of roles; every other service is a **consumer** of the claim, never a second source of truth." Resolves what was previously Open Question #4.
- Terminate both OAuth2 flows named in BRD §24's AuthN row — Authorization Code (web/mobile clients) and Client Credentials (service-to-service) — at Identity Service. §24.1's Issuance bullet describes minting for a "user/service-principal," covering both flows, and §24.2 confirms federated logins "land on the same Identity Service token issuance path" as native login, i.e. there is exactly one issuance path, owned by Identity. Resolves what was previously Open Question #5.
- Support multi-factor authentication (BRD §2.1 item 1: "...MFA") — the BRD names MFA as a responsibility but specifies no mechanism (TOTP, SMS OTP, WebAuthn, email code); see Open Questions.

**RBAC role/claim issuance (BRD §24.1)**

- At token-mint time, resolve the authenticated user or service-principal to a role set and embed it as scoped claims (`roles: [...]`, `scopes: [...]`) in the same JWT described above — this is the exact mechanism BRD §24.1's "Issuance" bullet describes, and is a new functional requirement this redraft adds; the prior draft had no FR for role-claim issuance at all.
- The four roles named in §24.1's table (Customer, Support Agent, Admin, Partner API) are the role vocabulary Identity resolves against; each role's actual scope/grant enforcement happens downstream (Gateway coarse-grained, owning service fine-grained per §24.1's "Enforcement" bullet) — Identity's own responsibility stops at correct role resolution and claim embedding, not downstream enforcement.

**SSO / Identity Federation (BRD §24.2)**

- Terminate SAML 2.0 or OIDC federation against the organization's enterprise IdP (Okta/Azure AD/Google Workspace) for Admin/back-office users, exchanging the external assertion for Kart's own short-lived JWT carrying Kart-native role claims (BRD §24.2). New FR this redraft adds.
- Terminate OIDC social login (Google/Apple/etc.) for customers, alongside native email/password signup, exchanging the external token for Kart's own JWT via the same issuance path as native login (BRD §24.2). New FR this redraft adds.
- Both federation paths terminate exclusively at Identity Service — no other service validates a SAML assertion or holds an external IdP client secret (BRD §24.2, explicit). See also Domain Invariants (§4).

**Session / revocation**

- Create a session on successful authentication, publishing `SessionCreated` (BRD §5.4).
- Maintain a token revocation list, checked at logout (BRD §24: "...revocation list for logout").
- Support session lifecycle management implied by "sessions" (BRD §2.1 item 1) and `SessionCreated` (§5.4) — the BRD does not state a session termination/expiry event (no `SessionExpired` or `SessionRevoked` in the event catalog, §10); see Open Questions.

**Cross-service event publishing**

- Register a new user identity, publishing `UserRegistered` on success (BRD §5.4; consumed by User, Notification, and Analytics per the Event Catalog, §10, as extended by ADR-0007).
- Publish `UserAccountUpdated` (payload: `userId`, `email`, `displayName`) whenever Identity's copy of login email or display name changes **after** registration — not just at registration time — so User Service can reconcile its denormalized profile copy. This event and its Identity→User direction are stated directly in BRD §5.4's Identity row and §10's Event Catalog; the underlying data-ownership split (Identity owns login-credential-adjacent fields; User owns the broader profile and keeps a denormalized copy) is resolved by **ADR-0006**, cited here rather than re-derived. The prior draft of this spec had no FR for this event at all — its own Consumed-Events note ("§5.4 shows Identity consuming nothing") was correct and remains correct, but the omission was on the **publish** side, not consume.

## 3. Non-Functional Requirements

Pulled from the BRD's global NFR table (§3) and the cross-cutting Security section (§24/§24.1/§24.2), scoped to this service:

| Attribute | Target | Applies here because |
|---|---|---|
| Availability | 99.99% (order path) or 99.9% (secondary)? — BRD §3 splits the two tiers only by "order path" vs. "secondary," and does not place Identity in either explicitly. Every authenticated request depends on Identity per the Gateway's JWT model (§18) and §24.1's single-issuer model, which argues for the 99.99% tier, but the BRD never says so; see Open Questions | Auth gates all authenticated traffic through the Gateway (§18), and RBAC resolution for every service now runs through Identity at mint time (§24.1) |
| Latency | P95 < 150ms, P99 < 400ms (read path); P95 < 300ms (write path, includes Outbox insert) | `/auth/login` and `/auth/refresh` are on the request-critical path for every authenticated call, and token-mint-time role resolution (§24.1) adds work to that same critical path |
| Consistency | Strong (PostgreSQL write path) per BRD §3's general write-path rule; Identity's DB is PostgreSQL (§5.4) | Login/session/token/role state cannot be eventually consistent — a stale "not authenticated," "still valid," or "wrong role" read is a security defect, not a UX one |
| Reliability | At-least-once delivery + idempotent consumers (BRD §3 general rule) | Applies to `UserRegistered`, `SessionCreated`, and `UserAccountUpdated` publication. Unlike the prior draft, this is no longer an open gap: all three events now have a full row (consumer(s), retry count, DLQ strategy) in the Event Catalog (§10) — `UserRegistered` and `SessionCreated` were added by **ADR-0007** (Event Catalog Completeness Pass) and `UserAccountUpdated` by **ADR-0006**. |
| Security | Zero plaintext secrets, signed tokens, TLS everywhere; JWT short-lived + refresh rotation (BRD §3, Security row); short-lived access tokens (~15 min), rotating refresh tokens, revocation list for logout, AES-256 at rest for PII (BRD §24); RBAC role claims are the platform's single source of truth for authorization, never duplicated locally by another service (BRD §24.1); external IdP contact (SAML/OIDC federation) is exclusive to Identity (BRD §24.2) | This is Identity's core NFR — it is the service that issues and rotates the tokens the rest of the platform trusts, resolves roles into those tokens, and is the platform's only point of contact with external IdPs |
| Observability | 100% trace coverage on order path (BRD §3/§23) — Identity is not on the order path itself, but every traced request downstream carries a correlation ID Identity's login/refresh calls must originate | Auth calls are the first hop of most traced request chains |

## 4. Domain Invariants

- A refresh token must be single-use and rotated on every refresh (BRD §24: "rotating refresh tokens") — reusing a refresh token after rotation must be detectable, though the BRD does not state what happens on reuse (revoke the session? revoke all sessions for the user?); see Open Questions.
- A revoked token (post-logout) must never be accepted again, regardless of its stated expiry (BRD §24: "revocation list for logout").
- An access token's validity window must not exceed the BRD's stated ~15 minutes (BRD §24, Token Lifecycle row).
- `UserRegistered` must be published exactly once per successful registration and must be idempotent-safe for its consumers (BRD §3 general Reliability rule; §5.4/§10 — User, Notification, and Analytics all consume it per ADR-0007).
- `UserAccountUpdated` must be published on every login-email or display-name change after registration (not only at registration) and must be idempotent-safe for User Service's consumer, mirroring the reliability bar already set for `UserRegistered` (BRD §5.4, §10; **ADR-0006**).
- Identity Service is the platform's single issuer of role/permission claims; no other service may maintain its own independent role or permission table as a second source of truth for authorization (BRD §24.1, explicit: "one issuer + one claim shape is what makes RBAC auditable across the whole platform"). This is a new invariant this redraft adds — the prior draft had no domain invariant covering RBAC at all.
- Identity Service is the platform's sole point of contact with any external IdP: no other service may hold an external IdP client secret or validate a SAML assertion / external OIDC token directly (BRD §24.2, explicit). New invariant this redraft adds.
- PII (at minimum, credentials and any stored personal identifiers) must be encrypted at rest with AES-256 (BRD §24, Encryption row) and never logged in plaintext (implied by BRD §23's structured-logging discipline, though not stated specifically for Identity).

## 5. API Surface (from BRD, starting point only)

| Endpoint/Event | Direction | Notes |
|---|---|---|
| `POST /auth/login` | Inbound API | BRD §5.4 |
| `POST /auth/refresh` | Inbound API | BRD §5.4 |
| SSO federation endpoint(s) (SAML ACS / OIDC callback for Admin; OIDC callback for customer social login) | Inbound API | BRD §24.2 states the responsibility (terminate SAML 2.0/OIDC federation for Admin/back-office against an enterprise IdP; OIDC social login for customers) but names no specific path, verb, or per-IdP routing scheme. Not invented here — final contract is the API Design Agent's job. |
| `UserRegistered` | Published | Consumed by User, Notification, and Analytics (BRD §5.4, §10 as extended by ADR-0007: 3x retry, `identity.dlq`) |
| `SessionCreated` | Published | Consumed by Analytics only (BRD §10 as extended by ADR-0007: 2x retry, `identity.dlq`) |
| `UserAccountUpdated` | Published | Consumed by User Service to reconcile its denormalized email/display-name copy (BRD §5.4, §10; **ADR-0006**). Payload: `userId`, `email`, `displayName`; 2x retry, `identity.dlq` per §10. |

No logout, MFA-challenge, or password-reset endpoint appears in the BRD at all. No consumed events are listed for Identity (§5.4 shows "—" under Consumes) — this remains true even with `UserAccountUpdated` added, since that event is published by Identity, not consumed by it. Final contract is the API Design Agent's job, not this spec's.

## 6. Open Questions / Flagged Ambiguities

**Resolved since the prior draft.** The prior draft carried five items (#4, #5, and part of #6 below) as open questions that BRD §24.1, §24.2, and ADR-0007 already answer directly:

- *Token issuer identity* (prior #4) and *OAuth2 flow termination point* (prior #5) are both resolved by BRD §24.1 ("Identity Service is the single issuer of roles... at token-mint time") and §24.2 ("Federation is terminated entirely at Identity Service... lands on the same Identity Service token issuance path"). See §2's new FRs.
- *Retry/DLQ policy for `UserRegistered`/`SessionCreated`* (part of prior #6) is resolved by **ADR-0007**, which added full Event Catalog rows for both. See §3's Reliability row and §5's API Surface table.

These are removed from the list below rather than carried forward as open. Remaining genuinely open items (renumbered):

1. **MFA mechanism unspecified.** BRD §2.1 item 1 names MFA as a responsibility but no other section names a mechanism (TOTP/SMS/WebAuthn/email code) or when it's required (always vs. step-up for sensitive actions). Cannot be inferred from the rest of the BRD. Blocking for any MFA-related functional requirement beyond "must exist in some form."
2. **Session TTL unspecified.** BRD §24 gives access-token (~15 min) and refresh-token rotation but never states a session lifetime, idle timeout, or absolute session cap. `SessionCreated` (§5.4) has no corresponding termination event.
3. **Refresh-token reuse/theft response unspecified.** BRD §24 states rotation but not the detection/response policy (revoke single session vs. revoke all sessions for the user vs. just deny) if a rotated-out refresh token is replayed.
4. **No consumed events.** BRD §5.4 shows Identity consuming nothing ("—"), and this remains true even after adding `UserAccountUpdated` (published, not consumed) per ADR-0006. This still seems surprising for a service that presumably needs to react to, e.g., an account-deletion or admin-lock action from the Admin Service (`AdminActionPerformed`, §5.4) — but the BRD does not state this integration, so it is not assumed here.
5. **Availability tier unassigned.** BRD §3 splits Availability into "99.99% (order path)" and "99.9% (secondary)" but never places Identity in either tier explicitly, despite Identity gating all authenticated traffic per the Gateway model (§18) and now also gating RBAC resolution for every service (§24.1). Left to the Architecture Agent to resolve with a human decision, not inferred here.
6. **No password-reset, logout, or MFA-challenge endpoint stated.** Only `/auth/login` and `/auth/refresh` appear anywhere in the BRD (§5.4). Whether these are BRD omissions (expected to exist but under-specified) or genuinely out of scope for this pass is not stated.
7. **External IdP role/group mapping unspecified.** BRD §24.1 states Identity resolves a user/service-principal to one of four platform roles (Customer, Support Agent, Admin, Partner API) at token-mint time, and §24.2 states enterprise-IdP-federated Admin/back-office logins land on that same issuance path — but the BRD never states how an enterprise IdP's own group/role claims (e.g., an Okta or Azure AD group membership) map onto Kart's four roles. Is this mapping config-driven per tenant, hardcoded, or provisioned manually out-of-band per admin account? Newly found while re-reading §24.1/§24.2 for this redraft; not resolved here.
8. **Federation session termination / Single Logout (SLO) unaddressed.** BRD §24.2 describes federation as a one-way exchange (external assertion → Kart JWT) at login time but says nothing about the reverse direction: if the enterprise IdP session ends, or a SAML SLO request arrives from the IdP, does Identity revoke the corresponding Kart session/refresh tokens? Given Domain Invariant #2 (a revoked token must never be accepted again) already exists for the native-logout case, this is a real gap for the federated-logout case specifically. Newly found while re-reading §24.2 for this redraft; not resolved here.

## Sign-off

- [ ] Blocking open questions resolved (Q1–Q3 in particular)
- [ ] Reviewed by:
- [ ] Approved to proceed to Architecture Agent
