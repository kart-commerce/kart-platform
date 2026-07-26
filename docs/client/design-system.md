---
doc_type: design-system
service: null
status: pending-approval
generated_by: human-authored (client tier)
source: docs/client/kart-web/design-tokens.md, docs/client/kart-admin-web/architecture.md, docs/PLATFORM_BLUEPRINT.md §2
---

# Shared Design System Architecture: Kart Client Tier

Closes the "Shared Design System" decision — how `kart-web` and `kart-admin-web` (two independent repos, ADR-0022) stay visually and structurally consistent without sharing source code.

## Decision: Dedicated Shared NPM Package (`@kart/design-system`, repo `kart-design-system`)

Options considered:

| Option | Verdict | Reasoning |
|---|---|---|
| Shared NPM Package | ✅ **Chosen** | A narrow, versioned, publishable boundary — exactly the pattern `kart-shared` already establishes for the backend (`PLATFORM_BLUEPRINT.md` §2.1: "consumed as a versioned package, never as shared source"), applied to the frontend. |
| Shared UI Library folded into `kart-shared` | ❌ Rejected | `kart-shared` is explicitly scoped to backend contracts/libs (event schemas, OpenAPI, .NET NuGet packages) — a frontend npm-publish pipeline is a different toolchain, different versioning cadence, different consumers entirely; overloading `kart-shared` with it is exactly the "dumping ground" risk `PLATFORM_BLUEPRINT.md` §2.1 warns against. |
| Separate Design Token Repository (tokens only, components stay duplicated per app) | ❌ Rejected | Solves token drift but not component drift — two apps would still hand-build/maintain separate button/input/modal implementations against the same tokens, defeating the actual goal (visual *and* structural consistency, per this decision's own ask). |
| Monorepo Package (merge `kart-web`/`kart-admin-web` into one workspace) | ❌ Rejected | Directly contradicts ADR-0022's two-independent-repos decision — would re-couple release cadence, CI/CD, and blast radius for the sake of component sharing, when a package boundary achieves the same sharing without that coupling. |
| Hybrid (npm package for tokens/icons only, components duplicated) | ❌ Rejected | A half-measure that pays the publishing-pipeline cost of the npm-package option without its full consistency benefit — no concrete reason identified why components should be excluded once the package/publishing mechanism already exists. |

**Chosen: one dedicated repo, `kart-design-system`, publishing one npm package, `@kart/design-system`**, built as an Angular library (`ng-packagr`). This is the platform's 21st repo (`PLATFORM_BLUEPRINT.md` §2.5's repo list gains one entry), phased alongside Phase 4 (Client Applications) since neither client app can consume it before it exists.

## What Lives in the Package

| Category | Contents | Source of truth |
|---|---|---|
| **Theme tokens** | CSS custom properties (`--color-*`, `--font-*`, `--spacing-*`, `--radius-*`, `--shadow-*`, `--motion-*`) generated from one JSON token source via Style Dictionary — light/dark/system themes | `docs/client/kart-web/design-tokens.md`'s values are the authoritative *content* spec; this package is the *distribution* mechanism — a token value change is edited in the JSON source (mirroring `design-tokens.md`), never hand-edited independently in each consuming app |
| **Icons** | A tree-shakable icon-component set (one Angular component per icon, generated from a single SVG source directory) exposed via a typed `IconName` union | `design-tokens.md`'s Icon Registry section |
| **Typography** | Type-scale tokens + a small set of typography utility classes/directives (heading levels, body/caption) | `design-tokens.md` §Typography |
| **Spacing** | The 8px-based spacing scale as both CSS variables and a TS `Spacing` const object (for programmatic use, e.g. virtual-scroll row heights) | `design-tokens.md` §Spacing Scale |
| **Animations** | Motion-duration/easing tokens + shared Angular animation definitions (fade/slide/skeleton-shimmer) respecting `prefers-reduced-motion` globally | `design-tokens.md` §Radius/Elevation/Motion |
| **CSS variables** | The single canonical `:root` variable set both apps import — neither app redefines a token locally | All of the above |
| **Shared components** | Standalone Angular components for the atoms/molecules both apps genuinely share: buttons, form controls, modal/dialog shell, toast/snackbar, skeleton loaders, data-table primitives, empty-state illustration wrapper | Both apps' `shared/ui/` folders (`kart-web/architecture.md`, `kart-admin-web/architecture.md`) consume these instead of re-implementing them |

Feature-specific composite components (a PDP gallery, an admin data-grid's domain-specific column set) stay local to each app's own `features/` folder — the package holds only what is genuinely shared, per the same anti-premature-abstraction principle `kart-web/requirement-spec.md` §2 already applies to Module Federation.

## How Each App Consumes It

- Both `kart-web` and `kart-admin-web` add `@kart/design-system` as a normal npm dependency (private registry — **GitHub Packages**, free at the org's existing free-tier posture, `PLATFORM_BLUEPRINT.md` §2.5).
- `kart-admin-web` explicitly reuses `kart-web`'s brand token *values* (no second brand) but still consumes them through this package, not by importing `kart-web`'s repo directly — `kart-admin-web/requirement-spec.md` §2's "no separate token file" decision is satisfied by both apps depending on the same package version, not by one app depending on the other.
- Each app's own `shared/ui/` folder becomes thin — it holds only app-specific composition/wiring around the package's components, never a re-implementation of what the package already provides.

## Versioning Strategy

Strict **semver**, enforced by **Changesets** (a PR-authored change-file drives the version bump + changelog, avoiding manual version-number disputes):

- **Patch**: bug fixes, non-visual internal refactors.
- **Minor**: new component/token addition, backward-compatible.
- **Major**: a token rename/removal or a component's public API (inputs/outputs) breaking change.

Each consuming app pins an **exact-minor range** (`^x.y.0`) in its `package.json` — never a floating `latest` — and receives version bumps via a Dependabot/Renovate PR like any other dependency, reviewed and merged on that app's own schedule (ADR-0022's independent-release-cadence guarantee extends to this dependency too).

## CI Publishing

`kart-design-system`'s own pipeline (via `kart-devops`'s reusable workflows, same reuse mechanism as every other repo):

1. Build (`ng-packagr`).
2. Visual regression test (Storybook + Chromatic, or an equivalent open-source visual-diff tool) — a token/component change that visibly alters existing consumers' rendering must be caught here, before publish, not discovered by a consuming app's own CI.
3. Changesets-driven version bump + changelog generation.
4. Publish to GitHub Packages.
5. (Downstream, not part of this repo's own pipeline) Dependabot opens an update PR against `kart-web` and `kart-admin-web`.

## Backward Compatibility

A token or component scheduled for removal is marked `@deprecated` (JSDoc annotation + a build-time console warning when used) and must remain functional for **at least one full minor version cycle** before removal in the next major — consuming apps get one release cycle of visible warning before a breaking change actually lands. Both consuming apps' own CI runs a "deprecated-usage" lint rule (a small custom ESLint rule scanning for `@deprecated`-flagged imports) so a team doesn't silently keep depending on something already flagged for removal until the major-version cutover forces a scramble.
