---
doc_type: design-tokens
service: kart-web
status: pending-approval
generated_by: human-authored (client tier)
source: docs/client/kart-web/requirement-spec.md
---

# Design Tokens: kart-web

Concrete brand values layered on top of the *system* defined in `agent-reusables/docs/standards/frontend/design-system-standards.md` — that file owns the token categories, the theming mechanism, and the "no hardcoded values" rule; this file only owns Kart's actual numbers.

**Flag before treating this as final:** the palette/typeface below is a **structurally-complete placeholder**, not a signed-off brand identity — actual brand color/logo/typeface choice is a marketing/design decision the BRD never makes and this doc doesn't invent on its behalf (per `AGENTS.md` §2's "business/product judgment call → ask the human" rule). What *is* settled here, as an engineering default: the token *shape* (names, scale steps, theme structure) — swapping the values below for a real brand kit later is a data change to this file, not a restructuring of any component that consumes it.

## Color Tokens

| Token | Light theme (placeholder) | Dark theme (placeholder) | Usage |
|---|---|---|---|
| `--color-primary` | `#2A6DF4` | `#5B8DF9` | Primary CTA, active nav, links |
| `--color-secondary` | `#0F172A` | `#E2E8F0` | Secondary actions, headers |
| `--color-success` | `#16A34A` | `#4ADE80` | Confirmations (order placed, in stock) |
| `--color-warning` | `#D97706` | `#FBBF24` | Low-stock, expiring coupon |
| `--color-danger` | `#DC2626` | `#F87171` | Errors, out-of-stock, destructive actions |
| `--color-info` | `#0891B2` | `#67E8F9` | Informational banners |
| `--color-background` | `#FFFFFF` | `#0B1120` | Page background |
| `--color-surface` | `#F8FAFC` | `#111827` | Card/panel background |
| `--color-border` | `#E2E8F0` | `#1F2937` | Dividers, input borders |
| `--color-text` | `#0F172A` | `#F1F5F9` | Primary text |
| `--color-text-muted` | `#64748B` | `#94A3B8` | Secondary/caption text |
| `--color-disabled` | `#CBD5E1` | `#334155` | Disabled controls |

Every pair above must be re-verified for WCAG 2.2 AA contrast (per `agent-reusables/docs/standards/frontend/accessibility-i18n-standards.md`) once real brand colors replace these placeholders — contrast compliance is a property of the *actual* values chosen, not something this file can guarantee in advance.

## Theme List

- `light`, `dark`, `system` (OS-synced) — per `requirement-spec.md` §2. No second brand/white-label theme is defined — nothing in the BRD indicates Kart operates multiple brands (`requirement-spec.md` §9), so only one brand-token set exists today. The reusable standard's brand-token-layering structure means adding one later is additive, not a rework.

## Typography

| Token | Placeholder value | Usage |
|---|---|---|
| `--font-family-base` | Inter, system-ui, sans-serif | Body, UI text |
| `--font-family-display` | Inter, system-ui, sans-serif | Headings (same family, heavier weight — no separate display face chosen yet) |
| `--font-size-heading-1` … `-4` | 2.5rem / 2rem / 1.5rem / 1.25rem | Page/section headings |
| `--font-size-body` | 1rem | Default body text |
| `--font-size-caption` | 0.875rem | Secondary/meta text |
| `--font-weight-regular` / `-medium` / `-bold` | 400 / 500 / 700 | — |
| `--line-height-body` | 1.5 | — |
| `--line-height-heading` | 1.2 | — |

## Spacing Scale

`--spacing-xs: 4px`, `--spacing-sm: 8px`, `--spacing-md: 16px`, `--spacing-lg: 24px`, `--spacing-xl: 40px`, `--spacing-xxl: 64px` — an 8px-based scale (4px only at the `xs` step for fine adjustments), applied everywhere per the reusable standard's "no value off the scale without a documented exception" rule.

## Radius / Elevation / Motion

- Radius: `--radius-none: 0`, `--radius-sm: 4px`, `--radius-md: 8px`, `--radius-lg: 16px`, `--radius-pill: 999px`, `--radius-circle: 50%`.
- Elevation: `--shadow-level-1` (cards) through `--shadow-level-3` (dropdowns/popovers), `--shadow-modal` (dialogs) — concrete blur/spread values deferred to the design-system implementation, not fixed here.
- Motion: `--motion-duration-fast: 120ms`, `--motion-duration-base: 200ms`, `--motion-duration-slow: 320ms`; `--motion-easing-standard: cubic-bezier(0.4, 0, 0.2, 1)`. All respect `prefers-reduced-motion` per the reusable accessibility standard — motion tokens resolve to near-zero duration when that preference is set, app-wide, not per component.

## Breakpoints

`xs: 0`, `sm: 576px`, `md: 768px`, `lg: 1024px`, `xl: 1280px`, `xxl: 1536px` — mobile-first, matches `requirement-spec.md`'s mobile-first mandate.

## Asset Registry (`Assets.*`)

Concrete entries pending actual brand assets (logo files, illustrations) — the registry *keys* below are settled so components can be built against them now, with placeholder assets swapped for final ones without touching a single component:

```typescript
export const Assets = {
  Logo: '/assets/brand/logo.svg',
  LogoMark: '/assets/brand/logo-mark.svg',
  EmptyCart: '/assets/illustrations/empty-cart.svg',
  EmptyWishlist: '/assets/illustrations/empty-wishlist.svg',
  EmptySearchResults: '/assets/illustrations/empty-search.svg',
  ProductPlaceholder: '/assets/placeholders/product.svg',
  UserAvatarPlaceholder: '/assets/placeholders/avatar.svg',
  // Payment-provider logos, carrier logos, and social-login icons are added here
  // as concrete integrations are confirmed — never inlined ad hoc in a component.
} as const;
```

## Icon Registry

One icon library (final choice deferred to the scaffold stage — an SVG-sprite or a tree-shakable icon-component library, per the reusable standard), exposed through a typed `IconName` union generated from the actual icon set once chosen. No inline `<svg>` in feature code.
