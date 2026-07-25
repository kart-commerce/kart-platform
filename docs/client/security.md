---
doc_type: security
service: null
status: pending-approval
generated_by: human-authored (client tier)
source: docs/client/kart-web/requirement-spec.md §5, docs/client/kart-admin-web/requirement-spec.md §5/§6, docs/services/kart-identity-service/requirement-spec.md §4
---

# Security: Kart Client Tier

Cross-cutting client-tier security decisions shared by `kart-web` and `kart-admin-web`. The generic mechanism (BFF token handling, silent refresh, CSRF posture, device/session logout) is owned by `agent-reusables/docs/standards/frontend/security-standards.md` and is not restated here — this file owns the two things that standard deliberately leaves as a per-app policy call: **concrete session-timeout numbers** (closing `kart-admin-web/requirement-spec.md` Open Question #1) and the **PCI DSS / OWASP ASVS scope statement** for the client tier as a whole.

## 1. Token Handling (confirmed, not new)

Both apps use the BFF pattern already decided in `kart-web/requirement-spec.md` §5: the SSR server (or, for `kart-admin-web`'s CSR-only build, a thin session-broker endpoint co-located with its static hosting) holds the access/refresh token; the browser holds only an `HttpOnly`/`Secure`/`SameSite=Strict` session cookie. Neither app ever writes a token to `localStorage`/`sessionStorage`, per the reusable standard's explicit prohibition.

`kart-identity-service` already fixes the platform-wide token lifetimes both apps build against (`kart-identity-service/requirement-spec.md` §4):

| Token | Lifetime |
|---|---|
| Access token | 15 minutes, all principals |
| Native refresh token (password login) | 30-day sliding window, 90-day absolute cap |
| Federated refresh token (SAML/OIDC) | 24-hour absolute cap, **no sliding extension** |

These are backend-owned facts, not client-tier decisions — restated here only because §2's session-timeout policy is deliberately bounded by them, never longer.

## 2. Session Timeout Policy

### 2.1 `kart-web` (Customer)

| Parameter | Value | Why |
|---|---|---|
| Idle timeout | None (client-side) — session validity is governed entirely by the token lifetimes in §1 | A customer session timing out mid-browse is a conversion-harming false positive with no security benefit proportionate to a public storefront's risk profile; the 15-minute access token + silent refresh already bounds a hijacked-cookie's usable window |
| Absolute session lifetime | 90 days (native), 24 hours (federated/social login) | Matches Identity's own caps in §1 exactly — `kart-web` invents no separate figure |
| Warning popup | None | No idle timeout to warn ahead of |
| Silent refresh | Transparent, interceptor-driven, before expiry or on a single 401 retry, per the reusable standard | Standard consumer UX — never surfaced as a re-login unless the refresh token itself is expired/revoked |
| Remember me | Offered at login (extends to the full 90-day native cap by default; declining still gets the same 90-day cap today since `kart-web` has no shorter authenticated default — "remember me" is framed to the user as convenience, not as unlocking a longer session than they'd otherwise get) | Consumer-tier UX expectation; carries no elevated-privilege risk the way an internal tool's persistent session would |
| Multi-tab behavior | Login/logout state synchronized across tabs via a `BroadcastChannel('kart-session')` (storage-event fallback for older engines) — logging out in one tab logs out every open tab immediately | Prevents a stale-authenticated tab from submitting a mutating request after the user believed they'd logged out elsewhere |

### 2.2 `kart-admin-web` (Support Agent / Admin) — closes Open Question #1

Elevated-privilege sessions get a materially tighter policy than `kart-web`'s, split by role because `Admin` and `Support Agent` carry different blast radii (`kart-admin-web/requirement-spec.md` §3's category-grant model):

| Parameter | `Admin` (SSO-federated) | `Support Agent` (native login) | Why |
|---|---|---|---|
| Idle timeout | **15 minutes** | **20 minutes** | OWASP ASVS V7 (Session Management) guidance for high-value sessions is single-digit-to-low-teens minutes; `Admin` gets the stricter figure as the higher-privilege role, `Support Agent`'s capped grant justifies a slightly longer figure without approaching `kart-web`'s no-idle-timeout posture |
| Absolute session lifetime | **24 hours**, no sliding extension | **8 hours**, no sliding extension | `Admin` inherits Identity's own already-decided federated cap (§1) verbatim — no new number invented. `Support Agent` uses native login but is explicitly **not** given the native tier's 90-day cap: an elevated-privilege session never inherits the consumer default regardless of login method, so this doc fixes an 8-hour cap — one work shift — as the client-tier override |
| Warning popup | **60 seconds** before idle logout: a modal with a live countdown and a single "Stay signed in" action | Same | Enterprise-standard courtesy window — long enough to react to, short enough not to functionally extend the idle timeout by habit |
| Silent refresh | Transparent, but **only while the tab is active/interacted-with** (mouse, keyboard, touch, or `visibilitychange`-confirmed foreground) — a background/idle tab is never kept alive by a timer-driven refresh alone | Prevents the classic anti-pattern where silent refresh silently defeats the idle timeout above; an idle tab's access token is allowed to lapse and the interceptor does not proactively renew it |
| Remember me | **Not offered** | **Not offered** | Elevated-privilege sessions never gain persistence beyond the absolute caps above — "remember me" is a `kart-web`-only, consumer-tier pattern |
| Multi-tab behavior | `BroadcastChannel('kart-admin-session')`: any tab's user interaction resets the shared idle timer for every open tab of the same browser profile; a warning popup or logout in any tab is mirrored to all tabs immediately | Same | An internal user with the console open in five tabs must not be logged out of four of them while actively working in the fifth, but a logout must be instant and total once triggered — either by idle timeout or a manual "log out" |

**Enforcement is layered, matching the reusable standard's rule that a route guard is UX, not the boundary:** the idle-timer/warning/logout behavior above is client-side UX; the actual session is invalidated server-side (revocation-list entry, per `kart-identity-service`) the moment idle logout fires, and every subsequent request re-validates against that revoked state regardless of what the client believes.

## 3. PCI DSS Scope

Confirmed, not new — restated for completeness against this task's PCI DSS requirement: neither app is ever in PCI DSS SAQ A-EP/D scope for card data, because raw PAN never transits either app's own code (`kart-web/requirement-spec.md` §5, `kart-web/architecture.md` Dependencies table's Payment Gateway row) — the card-entry UI posts directly to the external Payment Gateway's hosted tokenization field/iframe, and Kart's backend only ever receives the resulting token. This keeps both client apps at **PCI DSS SAQ A** scope (the lowest self-assessment tier, for merchants who fully outsource cardholder-data handling to a PCI-compliant third party and never touch cardholder data electronically). No client-tier code change can widen this scope without also changing `requirement-spec.md` §5's boundary decision — that would be a re-litigation of an already-settled architectural invariant, not a routine feature change.

## 4. OWASP ASVS Alignment

Both apps target **OWASP ASVS Level 2** (the appropriate tier for applications handling financial transactions and PII, per ASVS's own applicability guidance) as their verification baseline, layered on top of the reusable `security-standards.md`'s OWASP Top 10 mandate:

- **V2 (Authentication)** and **V3 (Session Management)** — satisfied by §1–2 above plus `kart-identity-service`'s token issuance.
- **V4 (Access Control)** — role/permission claims read from the validated session only, never a client-supplied value (reusable standard); `kart-admin-web`'s category-grant UI gating is UX-only, enforced server-side by `kart-admin-service` (`kart-admin-web/requirement-spec.md` §5).
- **V5 (Validation, Sanitization, Encoding)** and **V11 (Business Logic)** — every domain invariant `kart-web/requirement-spec.md` §8 states (price re-quote, stock display, no-offline money-moving) is UI convenience only; the owning backend service is always the actual enforcement point, never this client tier.
- **V9 (Communications)** — TLS everywhere, HSTS, no mixed content — platform-wide default, not a client-tier-specific addition.
- **V14 (Configuration)** — CSP per app (ADR-0022's "separate CSPs, separate allow-lists" consequence), no inline scripts/styles without a nonce, `Referrer-Policy: strict-origin-when-cross-origin`, `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY` (or an equivalent `frame-ancestors 'none'` CSP directive) on both apps — `kart-admin-web` additionally blocks framing unconditionally given its elevated-privilege surface has no legitimate embed use case.

## 5. Cookie/Consent Cross-Reference

Cookie categories, consent banner, and consent-versioning mechanics are specified in `docs/client/privacy.md` §"Cookie Consent" rather than duplicated here — the session cookie itself (§1) and the locale/currency cookies (`docs/client/localization.md`) are both `Necessary`-category and therefore never gated behind consent, per that doc's categorization.
