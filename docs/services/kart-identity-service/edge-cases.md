---
doc_type: edge-cases
service: kart-identity-service
status: pending-approval
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
