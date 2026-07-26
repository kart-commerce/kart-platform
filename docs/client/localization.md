---
doc_type: localization
service: null
status: pending-approval
generated_by: human-authored (client tier)
source: docs/client/kart-web/requirement-spec.md §2/§9, docs/client/kart-admin-web/requirement-spec.md §2
---

# Localization & Currency: Kart Client Tier

Closes `kart-web/requirement-spec.md` Open Question #1 ("launch locales/currencies are not stated anywhere in the BRD") and the i18n line of `kart-admin-web/requirement-spec.md` §2. Shared by both apps — `kart-admin-web` launches single-locale but inherits the same mechanism, per its own "structurally i18n-ready via the same reusable standard" decision. Layered on `agent-reusables/docs/standards/frontend/accessibility-i18n-standards.md`, which owns the *mechanism* (runtime switching, ICU MessageFormat, `Intl` APIs, RTL logical properties); this file owns Kart's actual launch values.

## 1. Languages

| Code | Language | Role |
|---|---|---|
| `en` | English | **Default / fallback** |
| `bn` | Bangla | Launch locale |
| `de` | German | Launch locale |

**Default language:** English (`en`). Used for: first-time anonymous visitors with no detectable preference, any translation key missing from `bn`/`de`, and every non-Production environment unless a tester explicitly overrides it.

**Fallback language:** English, unconditionally. A missing `bn`/`de` translation key is a **CI-blocking lint error** (translation-completeness gate, checked against the `en` bundle's key set on every PR) — the runtime fallback-to-English path exists as a safety net for a bad hotfix/rollback race, never as the expected production behavior for a genuinely missing key.

## 2. Language Detection

Resolution order, first match wins, evaluated server-side during SSR so the very first response is already correct (no client-side flash-of-wrong-locale):

1. **Explicit user preference** — authenticated: `kart-user-service`'s `preferredLocale` field (new field, see `docs/client/kart-web/tickets.md`); guest: the `kart_locale` cookie (§3).
2. **URL locale segment** — `/en/...`, `/bn/...`, `/de/...`. Always present in the canonical URL once resolved (see below); a request to an un-prefixed path resolves via steps 3–4 and 302-redirects to the locale-prefixed canonical URL, so every cacheable, crawlable, bookmarked URL is unambiguous about its locale.
3. **`Accept-Language` header** — first entry matching a supported locale; unsupported entries are skipped, not treated as a hard failure.
4. **Default** — English.

Resolving via URL segment (not a cookie alone) is deliberate: `kart-web`'s CDN-first, SSR-per-request posture (`kart-web/architecture.md`) needs a stable cache key, and a cookie-only locale would fragment CDN cache entries per cookie value — an anti-pattern for a CDN-fronted SSR app. The locale segment is that stable key.

## 3. Language Persistence

| Actor | Mechanism | Notes |
|---|---|---|
| Authenticated user | `kart-user-service.preferredLocale` | Synced to the profile on explicit switch (§4); read back on every login from any device — persistence follows the account, not the browser. |
| Guest | `kart_locale` cookie (first-party, `Necessary` category — no consent banner gate, see `docs/client/privacy.md`), 1-year expiry, plus a `localStorage` mirror for instant re-render before the next round-trip completes | Cleared/superseded the moment a guest authenticates and a `preferredLocale` already exists on their account (account value wins). |

## 4. Runtime Language Switching

The header locale switcher triggers an **Angular Router navigation to the same route under the new locale prefix** (`/de/products/123` → `/bn/products/123`) — per `agent-reusables/docs/standards/frontend/accessibility-i18n-standards.md`'s "without a full page reload" rule, this is a client-side route navigation, not a browser document reload: the new locale's translation bundle lazy-loads if not already cached, and the route's data resolvers re-run so `Meta`/`Title`/structured-data (`docs/client/kart-web/seo.md`) re-render correctly for the new locale — never a client-only string swap that would leave stale SSR'd meta tags for crawlers revisiting the URL later.

## 5. Fallback Language

English, as declared in §1. Enforcement is a build-time completeness gate, not a runtime guess — see §1.

## 6. Date Formatting

`Intl.DateTimeFormat`, keyed to the active locale, never a hand-rolled formatter:

| Locale | Example (2026-07-25) |
|---|---|
| `en` | Jul 25, 2026 |
| `de` | 25.07.2026 |
| `bn` | 25 Jul, 2026 — **Latin numerals**, not Bengali digit script (see note below) |

Account/order timestamps render in the browser's local timezone; raw API payloads remain UTC.

**Numeral-script decision:** Bangla (`bn`) locale strings are fully translated, but all numerals (dates, quantities, currency) render in Latin/Arabic numerals (`0–9`), not Bengali digit glyphs (`০–৯`). This is a deliberate e-commerce-readability call — price/quantity/date scanning speed matters more than linguistic purity for a transactional flow, and Latin numerals are already near-universally understood by Bangla-literate users in a commerce context. Stated explicitly here so it is not re-litigated per feature.

## 7. Number Formatting

`Intl.NumberFormat`, active-locale grouping/decimal separators:

| Locale | 1234.5 renders as |
|---|---|
| `en` | 1,234.5 |
| `de` | 1.234,5 |
| `bn` | 1,234.5 (Latin numerals, §6) |

## 8. Currency Formatting

Currency is an **independent axis from display language** — a `de`-reading user may shop in USD, a `bn`-reading diaspora user may shop in USD, and so on. Always rendered via `Intl.NumberFormat({ style: 'currency', currency })`, never a hand-built symbol-concatenation.

| Currency | Format | Notes |
|---|---|---|
| USD | `$1,234.56` | Symbol-first |
| BDT | `৳1,234.56` (primary), `BDT 1,234.56` (fallback where the font stack can't render `৳` reliably) | `aria-label="1,234.56 Bangladeshi Taka"` always present for screen readers — never a bare ambiguous number |

## 9. RTL Support Policy

**No launch language is RTL** (`en`/`bn`/`de` are all LTR). RTL is **structurally supported, not actively built**: every component uses CSS logical properties (`margin-inline-start`, `padding-inline-end`, etc. — never `margin-left`/`-right`) per the reusable standard's existing mandate, and `dir` is a single top-level attribute the whole layout already respects. Enabling a future RTL language (e.g., Arabic, Urdu, Hebrew) is a translation-bundle + `dir="rtl"` toggle addition, not a CSS rework. This closes the ambiguity as a policy statement — no RTL language ships at launch, and none needs to for this decision to be considered resolved.

---

## Currency (Decision Set)

Closes `kart-web/requirement-spec.md` Open Question #1's currency half. Supported: **USD**, **BDT**.

### Default Currency

USD globally, **except**: BDT is the first-visit default when the resolved locale is `bn` OR CDN/edge geo-header resolves the request to Bangladesh. First-visit default only — any explicit user choice (§"Currency Persistence" below) always wins on every subsequent visit, and is never silently overridden by a later geo/locale re-resolution.

### Currency Switching

Independent selector from the language switcher, same header control cluster. Switching currency triggers an immediate, synchronous re-quote via `kart-offer-service`'s `POST /pricing/quote` for every currently displayed price (PLP, PDP, cart) — `kart-web` **never computes a currency conversion client-side**; this matches `kart-offer-service/requirement-spec.md` §2's existing `/pricing/quote` responsibility ("tax and currency conversion"), so no new backend capability is invented here, only the client-side trigger for an already-owned server capability.

### Currency Persistence

| Actor | Mechanism |
|---|---|
| Authenticated user | `kart-user-service.preferredCurrency` — a field **separate from `preferredLocale`**, never derived from it after the first-visit default above (a Bangla-reading diaspora customer shopping in USD is a real, expected case this platform must not collapse into one axis) |
| Guest | `kart_currency` cookie (`Necessary` category) + `localStorage` mirror, same pattern as locale |

### Exchange Rate Strategy

The rate table is owned and refreshed server-side by `kart-offer-service` (already its documented responsibility — the specific FX-data vendor and refresh cadence are a backend/vendor decision, out of client-tier scope). `kart-web` treats every `/pricing/quote` response as valid for that response only:

- No client-side caching of a conversion rate beyond the single quote response that returned it.
- A cached quote older than **15 minutes** is never reused at checkout — the client always re-quotes before allowing payment submission, applying the *same* staleness rule `requirement-spec.md` Domain Invariant #2 already sets for promotion/price staleness, extended explicitly to cover currency conversion.

### Checkout Currency Behavior

The currency active on the cart at the moment **Place Order** is submitted becomes that order's fixed transaction currency (§"Order Currency Locking" below). Switching currency mid-checkout forces an immediate re-quote — never a stale cross-currency total carried forward. If the selected payment method is currency-restricted (e.g., a BDT-only local payment rail), the payment-method list at checkout is narrowed server-side to only the methods valid for the active currency; an invalid method/currency combination is never presented as choosable, let alone submitted.

### Order Currency Locking

Once `OrderCreated` fires, the order's currency is permanently fixed, stored alongside `amount` on the order/payment-intent record — the same `{amount, currency}` pair shape already used platform-wide (`kart-requirements.md`'s own example payload). Order history/detail always renders in the order's original locked currency regardless of the customer's *currently* active display-currency preference; if the two differ, a small "shown in original order currency" note is displayed. This is the same "never retroactively reinterpret a historical money value" principle the backend already applies to its own audit/event records, applied here to currency instead of just amount.

### Display Formatting

See §8 above (Currency Formatting) — identical rules apply, both sections describe the same mechanism from complementary angles (i18n-generic vs. currency-specific).
