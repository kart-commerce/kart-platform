---
doc_type: seo
service: kart-web
status: pending-approval
generated_by: human-authored (client tier)
source: docs/client/kart-web/requirement-spec.md §2/§9, docs/client/kart-web/architecture.md
---

# SSR / SEO: kart-web

Closes `requirement-spec.md` Open Question #4 ("whether `kart-web` needs 100% of the catalog server-rendered for SEO, or only PLP/PDP/home") with an exact page classification, and specifies the SEO mechanics SSR exists to enable.

## 1. Page Classification

### SSR (server-rendered per request)

| Page | Why SSR |
|---|---|
| Home | First-impression LCP + primary organic-search landing page |
| Category | Hierarchical taxonomy pages are a major organic-search surface (`kart-category-service`) |
| Product Listing (PLP) | Facet/sort/filter combinations are individually indexable and personalized/stock-sensitive — can't be build-time prerendered without going stale |
| Product Details (PDP) | The platform's highest-value organic-search surface; price/stock must never be served stale (Domain Invariants #2/#4, `requirement-spec.md` §8) |
| Brand pages | Modeled as a filtered PLP view keyed on Product's brand facet/attribute (`kart-product-service`) — not a new backend service or aggregate, the same "one cohesive capability" reasoning `architecture.md`'s `catalog/` folder note already applies to Category/Search/Recommendation |
| Search | Search-result pages are crawlable and indexable for long-tail queries, same staleness/personalization reasoning as PLP |
| CMS pages | About, FAQ, Terms, Privacy Policy, Help, etc. — see §6 for the distinct prerender tier these actually use |

### CSR (client-rendered only, post-hydration, no SSR)

| Page | Why CSR-only |
|---|---|
| Login, Register | No SEO value; SSR'ing a pre-auth form gains nothing and adds Node-runtime cost for zero benefit |
| Cart | Personalized, session-specific, no organic-search value |
| Checkout | Authenticated/guest-session-scoped, money-moving — SSR'ing it would risk a session-consistency race between the SSR pod and the requesting browser's own in-flight state, for a page with zero SEO value to justify that risk |
| Account | Authenticated-only, no SEO value |
| Wishlist | Authenticated-only, no SEO value |
| Orders | Authenticated-only, no SEO value |
| Admin | Out of scope for `kart-web` entirely (`kart-admin-web`) |

This confirms and closes the Open Question exactly as the assumption already stated it: PLP/PDP/home/category are SSR'd, authenticated-only views are CSR-only — Brand, Search, and CMS are now added explicitly as the two additional SSR cases and one distinct-tier case the original assumption hadn't yet enumerated by name.

## 2. Meta Tags

Populated server-side during SSR render via Angular's `Meta`/`Title` services, from the same data the page's resolver already fetched (§`api-strategy.md`'s TransferState note applies) — never patched client-side post-hydration, which would be invisible to a crawler that doesn't execute a full render pass:

- `<title>` — per-page, templated (`{ProductName} | Kart`, `{CategoryName} | Kart`, etc.), never a single static site-wide title.
- `<meta name="description">` — per-page, truncated to ~155 characters, sourced from product/category short-description fields (CMS pages: their own authored meta-description field).
- `<meta name="robots">` — `index, follow` by default on every SSR tier-1 page; `noindex, follow` on any SSR page that's technically crawlable but not meant to rank (e.g., an internal search-results page beyond a pagination depth threshold, to avoid thin-content indexing).

## 3. Structured Data (JSON-LD)

Injected server-side, per page type, using `schema.org` vocabulary:

| Page | Schema |
|---|---|
| Home | `Organization` + `WebSite` with a `SearchAction` (enables a sitelinks search box in search results) |
| Category, PLP, Search results | `ItemList` (ordered product references) + `BreadcrumbList` |
| PDP | `Product` (name, image, description, `offers` with price/currency/`availability` reflecting live stock — never a stale cached availability value, per Domain Invariant #4) + aggregate `Review`/`AggregateRating` (from `kart-review-service`) + `BreadcrumbList` |
| Brand pages | `Product`'s `brand` property populated on every listed item; the brand page itself uses the same `ItemList` shape as Category |
| CMS pages | `Article` or `WebPage`, per the CMS content type |

## 4. OpenGraph

Every SSR'd page emits `og:title`, `og:description`, `og:image` (PDP: hero product image; CMS: authored featured image; else: the brand default social-share image from `kart-design-system`'s asset registry), `og:type` (`product` on PDP, `article` on CMS, `website` elsewhere), `og:url` (the canonical URL, §5), and `og:locale` plus one `og:locale:alternate` per other supported language (`en`/`bn`/`de`, `docs/client/localization.md`) — populated server-side, same rule as meta tags.

## 5. Twitter Cards

`twitter:card = summary_large_image` on every SSR'd page, mirroring the OG title/description/image values above — authored once, never duplicated as separate copy.

## 6. Canonical URLs

Every SSR'd route emits a self-referencing `<link rel="canonical">` pointing to its locale-prefixed (`docs/client/localization.md` §2), query-param-normalized URL:

- Sort/view-toggle/session-tracking query params are **stripped** from the canonical (they don't represent distinct content).
- Pagination page-number params are **kept** in the canonical (page 2 of a PLP is genuinely distinct content from page 1), each page also carries `rel="prev"`/`rel="next"` link hints.

This prevents duplicate-content penalties from the many filter/sort permutations a PLP/search page can be reached through.

## 7. Sitemap

`/sitemap.xml` is a sitemap **index** referencing per-locale, per-content-type child sitemaps (`sitemap-products-en.xml`, `sitemap-categories-de.xml`, `sitemap-cms-bn.xml`, etc.) — generated by a scheduled job (every 6 hours) reading the same read-models SSR itself queries, so a product/category is added or removed from the sitemap automatically as its underlying read model changes, **never hand-maintained**. Submitted to Google Search Console and Bing Webmaster Tools on every regeneration (a lightweight ping, not a manual resubmission).

## 8. robots.txt

One static file per environment:

- **Production**: allows every SSR tier-1 path; explicitly `Disallow:`s every CSR-only authenticated route prefix (`/*/account/`, `/*/checkout/`, `/*/cart/`, `/*/orders/`, `/*/wishlist/`, `/*/login/`, `/*/register/`); references `/sitemap.xml`.
- **Non-Production** (Development/QA/UAT/Staging): a blanket `Disallow: /` — pre-prod environments must never be indexed, avoiding duplicate-content and data-leakage risk from a crawled staging catalog.

## 9. Lazy Hydration

Angular's `@defer` blocks, `hydrate on viewport` / `hydrate on interaction` triggers, applied to below-the-fold, non-LCP-critical widgets: recommendation carousels, review lists, footer content, "recently viewed." Above-the-fold/LCP-critical content (hero image, price, add-to-cart control) hydrates **immediately, never deferred** — deferring it would directly regress the LCP budget `requirement-spec.md` §4 already fixes (< 2.0s).

## 10. TransferState

Angular's built-in hydration transfer-state mechanism (`provideClientHydration()`) serializes every SSR-fetched API response into the initial HTML payload, so the browser's post-hydration bootstrap never re-fetches data the server already fetched — applied to all SSR route data (Product/Category/Search/CMS reads). **Explicitly not applied** to real-time/rapidly-changing data (live inventory count, live price) — those re-fetch/re-subscribe immediately post-hydration regardless of what was transferred, since a stale transferred value for them would violate the existing price/stock staleness invariants (`requirement-spec.md` §8, invariants #2/#4).

## 11. Route Prerender Policy

Three tiers, not two — closing the ambiguity between "SSR" and "static prerender" that the page classification in §1 alone doesn't fully resolve:

1. **Fully SSR'd, per-request** — Home, Category, PLP, PDP, Search, Brand pages. Content is too frequently-changing/personalized (stock, price, live promotions) for build-time prerendering to stay correct.
2. **Prerendered at build + webhook-triggered rebuild** — CMS pages only. Editorially-controlled, infrequently-changing content; paying per-request SSR cost for it is wasted compute. A CMS publish event triggers a scoped rebuild of just the affected page(s), not a full-site rebuild.
3. **CSR-only, no prerender, no SSR** — every authenticated/transactional route (§1's CSR table). No SEO value; SSR'ing an authenticated page risks either a login-wall flash or a user-specific data race between the SSR pod and the requesting browser's own session state.
