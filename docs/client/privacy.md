---
doc_type: privacy
service: null
status: pending-approval
generated_by: human-authored (client tier)
source: docs/adr/0016-user-gdpr-erasure-policy.md, docs/adr/0017-user-erasure-request-intake-caller.md, docs/services/kart-identity-service/requirement-spec.md
---

# Privacy: Cookie Consent & GDPR (Kart Client Tier)

Shared by both apps, though `kart-admin-web`'s own users (internal staff) are a materially smaller consent-management surface than `kart-web`'s anonymous public traffic — the mechanism is identical, the volume differs.

## Part A — Cookie Consent

### A.1 Cookie Categories

| Category | Examples | Consent required? | Default state |
|---|---|---|---|
| **Necessary** | Session cookie (§`security.md` §1), CSRF double-submit token, `kart_locale`, `kart_currency`, cart-session identifier for guests, cookie-consent-state itself | No — GDPR/ePrivacy exempts strictly necessary cookies | Always on, no banner control shown for these individually beyond an informational list |
| **Analytics** | First/third-party product-analytics and clickstream cookies feeding `kart-analytics-service`'s ingestion pipeline (`ClickstreamSource`, per `container-diagram.md`) | Yes | **Off** until accepted |
| **Marketing** | Ad-retargeting pixels, marketing-attribution cookies, third-party marketing-platform cookies | Yes | **Off** until accepted |
| **Preference** | Non-essential UX preferences that aren't strictly required to function (e.g., "dismissed this promo banner," recently-viewed-products local cache sync) | Yes | **Off** until accepted |

`kart-admin-web` in practice only ever sets **Necessary** cookies (an internal, authenticated-only tool has no anonymous-marketing surface) — its consent banner is present for completeness/policy-consistency but will typically show nothing to accept.

### A.2 Consent Banner

- Shown on first visit (no existing consent-version cookie, see §A.4) as a bottom-of-viewport banner, not a full-page interstitial — never blocks the page from being read/navigated before a choice is made (a GDPR-compliant pattern; blocking access entirely is itself a dark pattern this platform's own no-dark-patterns invariant, `kart-web/requirement-spec.md` §8.5, already forecloses).
- Three actions, equally prominent (no visual weighting toward "Accept All" over "Reject Non-Essential" — an equal-prominence requirement several EU DPAs now enforce directly): **Accept All**, **Reject Non-Essential**, **Manage Preferences** (opens the Preference Center, §A.3).
- Rendered SSR'd on `kart-web`'s first response (no flash-of-unconsented-tracking-script) — analytics/marketing scripts are not loaded server-side or client-side until a positive consent signal exists for that category; a script tag is conditionally injected post-consent, never present-but-inert (present-but-inert is still a measurable ePrivacy violation in several jurisdictions).

### A.3 Preference Center

A persistent, always-reachable settings surface (footer link "Cookie Preferences" on `kart-web`; Account/Privacy settings section on both apps) that reopens the same choice set as the banner, category-by-category toggle, plus a link to the full Privacy Policy (a CMS page, `docs/client/kart-web/seo.md`'s CMS-page tier). Changing a toggle here takes effect immediately (script load/unload), not on next visit.

### A.4 Consent Versioning

- Every banner/preference-center render is tagged with a `consentVersion` (a monotonic integer bumped whenever the cookie-category list or purpose descriptions materially change — e.g., adding a new Marketing sub-processor).
- The stored consent record (`kart_consent` cookie, `Necessary` category, 1-year expiry) carries `{ version, categories: { analytics: bool, marketing: bool, preference: bool }, timestamp }`.
- A stored consent whose `version` is older than the current `consentVersion` is treated as **stale** — the banner re-shows on next visit (existing category choices are pre-filled as the starting point, not reset to unconsented, so a returning user isn't forced to re-decide from scratch, only to re-confirm against the new version's disclosure).

### A.5 Consent Withdrawal

Withdrawing consent (toggling a category off in the Preference Center, or "Reject Non-Essential") takes effect immediately: the corresponding script/pixel is unloaded/disabled client-side in the same page load, and a withdrawal event is recorded with the same audit shape as a grant (§A.4's stored shape, `categories.analytics: false` etc.) — withdrawal is a first-class state transition, not merely "absence of a grant record."

### A.6 Cookie Expiration

| Cookie | Expiry |
|---|---|
| `kart_session` | Session-scoped (browser close) for the underlying auth session's own lifetime rules (`security.md` §2) — the cookie itself carries no longer-lived expiry than the session it represents |
| `kart_consent` | 1 year, or immediately superseded by a newer explicit choice |
| `kart_locale` / `kart_currency` | 1 year |
| Analytics/Marketing cookies | Governed by each third-party processor's own documented retention (recorded in the Privacy Policy CMS content, not hand-duplicated here) — never silently extended by this platform beyond what's disclosed |

## Part B — GDPR Privacy

Builds directly on ADR-0016 (User erasure via `UserDataErased`, consumed platform-wide) and ADR-0017 (erasure-request intake caller) — this section is the **client-tier UI** for rights the backend already implements or is now extended to implement; it invents no new backend erasure mechanism, only the missing rights (access, export, rectification) and the customer-facing entry points.

### B.1 Consent Recording

Every GDPR-relevant consent (cookie categories §A, marketing-communication opt-in at registration/checkout, terms-of-service acceptance) is recorded with `{ purpose, granted: bool, version, timestamp, mechanism }` — `mechanism` distinguishes "banner," "preference center," "checkout checkbox," etc., so an audit can reconstruct exactly how and where consent was captured, not just that it exists.

### B.2 Privacy Policy Acceptance

Tracked as its own consent purpose (§B.1), versioned identically to cookie consent (§A.4) — a Privacy Policy content change bumps its own version independent of the cookie-consent version, and a logged-in user whose accepted version is stale sees a one-time non-blocking banner ("We've updated our Privacy Policy") linking to the CMS page, not a forced re-click-through gate (forcing re-acceptance to keep using an existing account is disproportionate for a policy-clarity update; a *material* rights-narrowing change would instead be a product/legal decision to force re-consent, out of this doc's engineering scope).

### B.3 Right to Access / B.4 Right to Export (Data Portability)

**New client-facing capability**, Account → Privacy → "Download my data": submits a request that lands on `kart-user-service` (the same erasure-request intake pattern ADR-0017 already establishes — reusing that intake mechanism for a second request *type*, not inventing a second pipeline). `kart-user-service` fans out a read-only aggregation request across every service ADR-0016 already lists as holding user-linked PII (Identity, Order, Cart, Wishlist, Review, Notification, Analytics), assembles a machine-readable export (JSON, the standard GDPR-portability format) and a human-readable summary (PDF), and notifies the user when ready (Notification Service, existing fan-out) with a time-limited signed download link (7-day expiry, then the export is deleted — never left indefinitely downloadable). This closes Right to Access and Right to Export as one mechanism, since a full data export both answers "what do you have on me" and satisfies portability. New backend work is captured as a ticket (`docs/client/kart-web/tickets.md`) — this doc fixes the UX entry point and the shape, not the implementation.

### B.5 Right to Delete

Account → Privacy → "Delete my account" — reuses the existing erasure flow (ADR-0016/0017) end-to-end: submission triggers `kart-user-service`'s intake, which drives `UserDataErased` and every consumer's already-specified redaction (including `kart-identity-service`'s session/token-family revocation, `requirement-spec.md` §"GDPR erasure consumption"). Client-side requirement: a confirmation step stating the erasure is irreversible and what specifically survives it (financial/order records retained per legal/tax obligation — `payment_intents`/`refunds` are never hard-deleted per `kart-payment-service/requirement-spec.md` §"CanDelete is never exposed to any principal" — the confirmation copy states this explicitly rather than implying total erasure).

### B.6 Right to Rectification

Account → Profile — already-scoped profile/address editing (`kart-web/requirement-spec.md` §3.5, `kart-user-service`) *is* the rectification mechanism for self-service-correctable fields. For fields a user cannot self-edit (e.g., a fraud-flagged account attribute), a "Request a correction" support ticket path routes to `kart-admin-web`'s support-console (§3.3, already scoped) rather than a new dedicated rectification pipeline — reuses existing scope.

### B.7 Data Portability

Covered by B.4 — the export format (JSON) is the portability deliverable; no separate mechanism is defined because GDPR's portability right and access right are satisfied by the same artifact here.

### B.8 Cookie Consent Linkage

The GDPR consent record (§B.1) and the cookie-consent record (§A.4) share the same `consentVersion`/`timestamp` shape and the same storage location (`kart_consent` cookie for guests, `kart-user-service` profile for authenticated users) so a single Preference Center screen can display and let a user manage every consent purpose — cookie categories and GDPR-specific consents (marketing communication, data-processing purposes beyond the strictly necessary) — in one place, not two disconnected UIs.

### B.9 Audit Logging

Every consent grant/withdrawal (§A.5, §B.1) and every rights-request (§B.3–B.6) is written to the same platform-wide audit mechanism already established for admin actions (`Kart.Shared.Auditing` interceptor, `created_by`/`updated_by`/`created_at` — BRD §24.3) — a rights-request row stamps the requesting user's own principal id (self-service, never a third party acting on their behalf without the existing Admin-assisted support path), and `kart-admin-web`'s existing Audit & Compliance dashboard (§3.5, already scoped) is extended to include a "Privacy Requests" view for compliance reporting, reusing that screen rather than building a parallel one.
