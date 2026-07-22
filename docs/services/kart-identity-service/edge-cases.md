---
doc_type: edge-cases
service: kart-identity-service
status: approved
generated_by: edge-case-analyzer-agent
source: docs/services/kart-identity-service/requirement-spec.md
---

# Edge Cases: kart-identity-service

## Edge Case: Refresh Token Replay After Rotation

- **What happens:** A refresh token that has already been rotated out is presented again and the service must decide whether to honor it.
- **Why it happens:** Refresh tokens are single-use and rotated on every refresh (Domain Invariant #1); a stolen or cached old token being replayed after legitimate rotation is the direct failure mode that invariant exists to catch.
- **Solutions available (3):** Reuse-detection with token families (each rotation chains to a parent; replay of a non-current-generation token revokes the whole family) · Simple reject-and-continue (deny the stale token, leave the current session alone) · Full session teardown on any reuse (revoke every session for the user, forcing re-login everywhere)
- **Decision:**
  - Chosen: Token-family reuse detection — replay of a stale token revokes that token's entire family (all sessions descended from it)
  - Why: Reject-and-continue leaves a live compromise path open (the attacker's stolen token and the legitimate rotated one can coexist indefinitely); full teardown of every session for the user is disruptive to unrelated, uncompromised sessions
  - Trade-off accepted: Requires storing rotation lineage per token (not just a flat single-use flag), which is more write-path state than the simplest reject option

## Edge Case: Concurrent Refresh Race (Double-Spend on One Refresh Token)

- **What happens:** Two `/auth/refresh` requests using the same still-valid refresh token arrive close together (e.g., client retry, or two tabs), and both attempt to rotate it before either write commits.
- **Why it happens:** Refresh tokens must be single-use (Domain Invariant #1) but the check-and-rotate is a read-then-write sequence; without serialization, both requests can read "still valid" before either marks it consumed.
- **Solutions available (3):** DB-level uniqueness/CAS on the token's consumed-state (`UPDATE ... WHERE consumed = false`, only one request's row-update succeeds) · Distributed lock keyed on the token/session before allowing rotation · Optimistic retry (both proceed, reconcile after, revoke on conflict)
- **Decision:**
  - Chosen: DB-level conditional update (single atomic `UPDATE ... WHERE consumed = false` on PostgreSQL)
  - Why: The requirement-spec's Consistency NFR calls for strong consistency on Identity's write path (PostgreSQL); a conditional update gets atomicity from the existing store instead of introducing a separate locking layer
  - Trade-off accepted: The losing request must handle a rejected rotation as a normal race outcome (return "refresh again" or fall back to the family reuse-detection path above), not as an unexpected error

## Edge Case: Stale Revocation Under Stateless JWT Validation

- **What happens:** A user logs out (or is force-revoked); the access token they already hold is still cryptographically valid and the Gateway keeps accepting it until it naturally expires.
- **Why it happens:** The Gateway validates JWTs at the edge without a round-trip to Identity (BRD §18 / requirement-spec §2), so a stateless signature check has no way to see a revocation that happened after the token was issued — this is the direct tension with Domain Invariant #2 ("a revoked token must never be accepted again").
- **Solutions available (3):** Keep access tokens short-lived (~15 min per BRD §24) and accept a bounded post-logout window · A shared, low-latency revocation/deny-list (e.g., Redis) the Gateway checks on every request · Force full token introspection against Identity on every request (no local Gateway validation)
- **Decision:**
  - Chosen: Short-lived access tokens as the primary control, backed by a Redis-based revocation list the Gateway consults for the (rare) explicit-logout case
  - Why: Full introspection on every request defeats the stated purpose of edge JWT validation (BRD §18); the ~15-minute token lifetime is already a stated NFR target, so the residual exposure window is bounded and known rather than open-ended
  - Trade-off accepted: A revoked token can still be honored for up to the access-token TTL if the revocation-list check is skipped or lagging — this is a deliberately accepted bounded window, not full immediate revocation

## Edge Case: Credential Stuffing / Brute-Force on `/auth/login`

- **What happens:** An attacker submits large volumes of username/password guesses against `/auth/login`, either from leaked-credential lists (stuffing) or exhaustive guessing.
- **Why it happens:** `/auth/login` (FR, BRD §5.4) is the platform's single authentication choke point and, per the Security NFR (BRD §24: "zero plaintext secrets, signed tokens"), is the only place password verification happens — making it the highest-value target in the whole platform.
- **Solutions available (3):** Per-account and per-IP progressive throttling/lockout at Identity, layered under the Gateway's existing tiered rate limiting (BRD §18) · CAPTCHA/step-up challenge after N failed attempts · Passive detection only (log and alert, no blocking)
- **Decision:**
  - Chosen: Per-account and per-IP progressive throttling at Identity, layered under the Gateway's tiered rate limiting
  - Why: The Gateway's rate limiting (BRD §18) is generic per API key/user and not password-attempt-aware; Identity is the only place that knows "this was a failed password check" and can throttle on that specific signal
  - Trade-off accepted: Legitimate users who mistype a password repeatedly (e.g., shared device, forgotten recent password change) can trip the same throttle as an attacker — a false-positive lockout risk accepted in exchange for closing the guessing vector

## Edge Case: Partial-Auth Window During MFA

- **What happens:** Between a successful password check and a completed MFA challenge, the account is in a "step one done, step two pending" state; if that intermediate state is addressable by a token, an attacker who obtains it could attempt to use it as if authentication were complete.
- **Why it happens:** MFA is a stated responsibility (BRD §2.1 item 1 / requirement-spec FR) but its mechanism is unspecified (Open Question 1) — any two-step verification flow, regardless of which mechanism is eventually chosen, forces an intermediate state to exist between the two steps.
- **Solutions available (2):** Issue a short-lived, narrowly-scoped "pending-MFA" token that is explicitly rejected by every endpoint except the MFA-completion one · Do not issue any token until MFA fully completes (hold state server-side only, keyed by a one-time challenge ID)
- **Decision:**
  - Chosen: Server-side challenge state only (no token issued until MFA completes)
  - Why: A scoped pending-MFA token still requires every consuming endpoint to correctly enforce the scope restriction, which is an ongoing correctness burden across services; holding state server-side means nothing exists for a client-side interception to replay
  - Trade-off accepted: Requires Identity to keep short-lived server-side challenge state (versus the fully stateless pattern used for other Identity/Gateway token flows), a minor consistency-model exception scoped to the MFA window only

## Edge Case: Session Fixation via Pre-Auth Session Reuse

- **What happens:** A session identifier issued before login is carried over and reused as the authenticated session after login succeeds, letting an attacker who fixed that identifier on a victim's client inherit the authenticated session.
- **Why it happens:** `SessionCreated` is published on successful authentication (FR, BRD §5.4) but the BRD states no session TTL, idle timeout, or explicit new-session-on-privilege-change rule (Open Question 2) — without an explicit regeneration rule, a naive implementation can carry one identifier across the anonymous-to-authenticated boundary.
- **Solutions available (2):** Always issue a new session identifier at the moment of successful authentication, regardless of any pre-auth session that existed · Reuse the same identifier across login, relying only on other controls (token binding, IP checks) to catch hijacking
- **Decision:**
  - Chosen: Always regenerate the session identifier on successful authentication
  - Why: This is the standard, low-cost mitigation for session fixation and requires no additional infrastructure, unlike relying on secondary signals (IP/device binding) that are noisy for mobile clients on carrier NAT
  - Trade-off accepted: None material — this is treated as an engineering default, not a genuine trade-off between comparably-viable options

## Edge Case: RBAC Role Change Outlives an Already-Minted JWT

- **What happens:** A user's role assignment changes (e.g., promoted to Admin, demoted, or an Admin account deactivated) while they still hold a valid, unexpired access token whose role/scope claims were resolved at the previous mint time; every downstream service keeps authorizing that token's requests against the old, now-incorrect claims until it naturally expires.
- **Why it happens:** Role/claim resolution happens exactly once, at token-mint time (requirement-spec §2, RBAC FR: "at token-mint time, resolve... embed as claims"), and Identity is stated as the platform's single issuer with every other service a pure claim *consumer*, never re-validating a claim against current role state (Domain Invariant: "Identity Service is the platform's single issuer of role/permission claims... no other service may maintain its own independent role or permission table"). Nothing in the stated FRs re-resolves claims mid-token-lifetime.
- **Solutions available (3):** Shorten access-token TTL specifically for role-bearing claims, tighter than the general ~15 min, to bound the exposure window on its own · Extend the existing Redis-backed revocation-list check (already required for the logout case, see the Stale-Revocation edge case above) to also cover forced-role-change events, so the Gateway's existing lookup path catches this case too · Force full re-authentication (new mint) on every role change, invalidating the old token immediately via the revocation list
- **Decision:**
  - Chosen: Extend the existing Redis-backed revocation-list check to also cover role-change events — Identity marks a user's outstanding tokens stale the moment a role changes, reusing the same Gateway-side lookup path the logout case already requires.
  - Why: Reuses infrastructure already accepted for the logout case instead of adding a second, separate bounded-staleness mechanism (a role-specific shorter TTL) or forcing disruptive full re-auth for a comparatively rare event.
  - Trade-off accepted: The same bounded window already accepted for post-logout staleness (up to the access-token TTL) now also covers post-role-change staleness unless the revocation-list check catches it first — an explicit extension of an already-accepted risk, not a new unbounded one.
  - Note: this is also the confirmed enforcement mechanism for the admin-triggered account-lock FR (requirement-spec.md §2, "Admin-triggered account suspension") — a lock invoked via Admin Service's internal call populates this same revocation list, it does not require a new mechanism of its own.

## Edge Case: SAML Assertion Replay at the ACS Endpoint

- **What happens:** The same SAML Response (same assertion, still inside its stated validity window) is submitted to Identity's SAML endpoint more than once — captured and resent by an attacker, or double-submitted by a client (browser back-button/retry) — and each submission could independently mint a fresh Kart JWT/session from what was really one authentication event.
- **Why it happens:** SAML termination is a stated FR (BRD §24.2 / requirement-spec §2) with Identity named as the platform's sole point of contact with any external IdP (Domain Invariant, explicit), but the Security NFR's stated control ("signed tokens") addresses forgery, not replay — a signed SAML Response stays technically valid on every resubmission within its window unless the Service Provider itself tracks which assertions it has already consumed, and nothing in the stated FRs does that.
- **Solutions available (3):** Maintain a consumed-assertion-ID cache (keyed on the SAML Response's assertion ID, TTL'd to the assertion's own validity window) and reject any ID seen before · Bind each outbound AuthnRequest to a one-time server-side state value and reject any Response that doesn't match a not-yet-consumed request (standard SP-initiated relay-state pattern) · Accept the replay risk and rely solely on the assertion's stated expiry as the only control
- **Decision:**
  - Chosen: Consumed-assertion-ID cache, keyed on assertion ID and TTL'd to the assertion's validity window.
  - Why: This is the same single-use-plus-reuse-detection shape already chosen elsewhere in this service (see the Refresh Token Replay edge case above), applied to inbound SAML assertions instead of Identity-issued refresh tokens — closing the replay path directly rather than relying on an expiry window a replay inside that window would still pass.
  - Trade-off accepted: Requires Identity to hold short-lived per-assertion state scoped to the SAML flow specifically — a similarly scoped statelessness exception to the one already accepted for the MFA partial-auth window elsewhere in this file, not a cost-free addition.

## Edge Case: Federated Login With No Matching Kart Account

- **What happens:** A valid SAML/OIDC assertion (enterprise Admin) or OIDC social-login token (customer) arrives at Identity for an external identity with no corresponding existing Kart user record — Identity must decide whether to create one on the spot, reject the login, or redirect to a separate signup step.
- **Why it happens:** The FR states federation "exchang[es] the external assertion for Kart's own... JWT via the same issuance path as native login" (requirement-spec §2) but never states what happens on a *first* login for that external identity — a scenario the stated FR simply doesn't address for either federation path, and the two paths plausibly warrant different answers (enterprise Admin accounts are typically pre-provisioned out-of-band; customer social login is typically expected to create an account on first use), which the BRD states neither way. This is a distinct gap from Open Question #7 (how an IdP's *existing* group claims map to Kart's four roles) — this edge case is about whether an *account* should be created at all, prior to any role mapping being relevant.
- **Solutions available (3):** Just-in-time (JIT) provisioning — auto-create a Kart account on first successful federated login for both paths · JIT-provision for customer social login only; reject/require pre-provisioning for enterprise Admin federation · Reject JIT entirely for both paths, requiring an out-of-band account-creation step before any federated login can succeed
- **Decision:**
  - Chosen: JIT provisioning for **both** federation paths — a Kart account/identity record is auto-created on first successful federated login, whether enterprise (Admin/back-office) or customer social login.
  - Why: For customer social login this directly matches BRD §24.2's stated self-service-registration intent ("reduces signup friction"). For enterprise federation, the governance risk this edge case originally worried about — auto-creating a fully-privileged Admin account from an external assertion alone — is closed by a separate decision, not by rejecting JIT: requirement-spec.md §2's resolution of prior Open Question #7 makes role grant fail-closed (zero platform roles unless an explicit IdP-group→role mapping entry exists, and `Admin` is never auto-granted merely by successful federation). Once role grant is fail-closed, JIT-provisioning the *account record* itself carries no privilege-escalation risk — it only means the org's IdP stays the single source of truth for "who currently has a corporate identity," without a separate manual Kart-side pre-provisioning step that would drift out of sync with the IdP.
  - Trade-off accepted: A JIT-provisioned enterprise account with no matching role-mapping entry yet is a real, existing account that can access nothing (rather than a rejected login with a more specific error) — accepted because it fails closed either way, and keeps "should this login succeed" and "what can this login do" as two separably-solved questions instead of one combined reject/accept decision.
  - Resolved via: requirement-spec.md §2 (SSO / Identity Federation FRs), which formalizes this alongside the Open Question #7 role-mapping decision. No new ADR needed — this is Identity's own account-provisioning behavior and does not change any other service's integration surface.

## Edge Case: Federated Session Can Outlive IdP-Side Revocation Indefinitely

- **What happens:** An enterprise IdP disables or deprovisions an Admin's account (or that Admin's IdP-side session otherwise ends) after Identity has already exchanged a prior assertion for a Kart JWT and refresh token. Unlike the native-logout case, nothing ever populates Identity's revocation list for this event, so ongoing refresh-token rotation alone could keep that federated session alive indefinitely — not just for one bounded access-token TTL, but for as long as the client keeps refreshing.
- **Why it happens:** Federation is a stated one-way, login-time-only exchange (requirement-spec §2; Open Question #8 already names the missing reverse-direction/SLO signal), and Identity's consumed-event set is stated as empty (Open Question #4) — there is no SLO callback, webhook, or polling path anywhere in the BRD. This is a concrete consequence of that gap beyond the gap itself: the Stale-Revocation edge case's bounded-window default (access-token TTL + revocation-list check) doesn't transfer here, because the revocation list is never populated for an IdP-side deprovisioning event in the first place — rotation, not a single TTL, is the actual exposure surface.
- **Solutions available (3):** Apply an absolute (non-rolling) lifetime cap to refresh tokens issued via a federated login specifically, so rotation cannot extend a federated session past that cap even with zero revocation signal ever arriving · Add a periodic re-validation ping against the enterprise IdP for federated sessions (extra latency/cost, and needs IdP-side support this spec has no stated integration for) · Accept the gap as-is with no additional cap, relying only on whatever general session-TTL default eventually resolves Open Question #2
- **Decision:**
  - Chosen: A federated-login refresh token gets a **24-hour absolute cap, with no sliding extension** — distinct from, and far shorter than, the native (non-federated) refresh token's 30-day sliding / 90-day absolute cap (requirement-spec.md §4, resolving prior Open Question #2).
  - Why: This closes the specific failure mode — indefinite renewal with no revocation signal ever arriving — without requiring a new IdP integration; it is a defensible engineering default (a bounded cap) rather than the actual fix, which is real-time SLO propagation. 24 hours (roughly one working day) is chosen specifically because the federated population is disproportionately Admin/back-office (§24.1's higher-privilege roles), so the exposure window after an unnoticed IdP-side deprovisioning is bounded tightly rather than matching the much longer native-user cap.
  - Trade-off accepted: A still-employed Admin using a long-lived federated session is forced to re-authenticate against the IdP at least once every 24 hours even though nothing about their access changed — accepted because the alternative (no cap, or the native 90-day cap) has unbounded/much larger exposure once the IdP has already revoked the person, which conflicts directly with Domain Invariant #2 ("a revoked token must never be accepted again").
  - Note: This mitigates the worst failure mode but does not solve the underlying gap — real-time SLO/deprovisioning propagation is carried forward as a non-blocking, later-pipeline-stage item (requirement-spec.md §6, item 1) once specific IdP capabilities (SCIM, SLO endpoints) are known at the Architecture Agent stage.

## Edge Case: `UserDataErased` Arrives While the User Holds Active Sessions

- **What happens:** Identity consumes `UserDataErased` for a user who still holds one or more valid, unexpired access/refresh tokens; redacting the `users` row alone does nothing to stop the Gateway from continuing to accept those already-minted tokens until they naturally expire.
- **Why it happens:** Requirement-spec §4's new erasure invariant states redaction and revocation together, but they are two mechanically separate actions on two separate stores (PostgreSQL tombstone write vs. Redis revocation-list population) — the same tension as "Stale Revocation Under Stateless JWT Validation" above, now triggered by erasure instead of logout.
- **Solutions available (2):** Reuse the existing Redis-backed revocation-list mechanism — populate a revocation entry for every live session belonging to that `userId` in the same handler that performs the PII tombstone write · Rely solely on the bounded access-token TTL (~15 min) with no explicit revocation action, accepting a short post-erasure access window
- **Decision:**
  - Chosen: Reuse the existing revocation-list mechanism — the `UserDataErased` handler enumerates the user's live sessions (`idx_sessions_user_live`) and populates a revocation entry for each, the same write shape already used for logout/role-change/admin-lock.
  - Why: No new infrastructure is needed; a compliance-triggered erasure deserves at least the same immediacy guarantee already given to an admin-triggered lock, not a weaker one.
  - Trade-off accepted: None material beyond the already-accepted bounded window on the revocation-list check itself (see "Stale Revocation Under Stateless JWT Validation") — this reuses an already-accepted risk, not a new one.

## Edge Case: Out-of-Order Delivery of Successive `UserAccountUpdated` Events

- **What happens:** A user changes their login email and/or display name twice in quick succession (e.g., corrects a typo moments after saving, or two devices submit changes close together); the resulting `UserAccountUpdated` events for the same `userId` can be delivered to User Service out of order or redelivered, letting a stale (earlier) value overwrite the newer one in User Service's denormalized copy.
- **Why it happens:** `UserAccountUpdated` must be published on every login-email/display-name change and be idempotent-safe for User Service's consumer (Domain Invariant, ADR-0006), and the platform's general messaging model is at-least-once delivery with TTL-ladder retries (`docs/standards/event-standards.md`: "Retry via TTL-ladder parking-lot queues... never immediate requeue"). Neither the stated reliability rule nor ADR-0006's payload (`userId`, `email`, `displayName` only) addresses preserving delivery order across two separate publishes for the same user, and a retried message can land after a newer, non-retried one by construction.
- **Solutions available (3):** Add a monotonic `updatedAt`/version field to the payload so User Service applies last-write-wins by version rather than by arrival order (extends ADR-0006's stated 3-field payload) · Move this specific event onto a partition-by-`userId` ordering guarantee (the Kafka-partition-by-aggregate-id pattern named in `event-standards.md`), which means taking it off the platform's RabbitMQ default for this one event type · Accept last-delivery-wins as-is and rely on the low real-world frequency of rapid successive changes to bound the blast radius
- **Decision:**
  - Chosen: Add a monotonic `updatedAt` (or sequence) field to the `UserAccountUpdated` payload; the consumer applies an incoming update only if it is newer than its currently stored value.
  - Why: Lowest-cost fix that doesn't require moving one low-volume event type off the platform's default RabbitMQ topology just to get ordering guarantees; it mirrors the "reconcile by version, not by arrival order" shape this service already relies on elsewhere (token-family lineage for refresh rotation).
  - Trade-off accepted: This extends ADR-0006's stated payload (`userId`, `email`, `displayName`) with one additional field — flagged here as a **proposed contract addition** for the Architecture/Event-Design Agent to confirm when `UserAccountUpdated`'s schema is finalized, not assumed as already-approved per AGENTS.md §2's rule against inventing fields silently.
