---
doc_type: adr
status: accepted
---

# ADR-0022: Client Tier Ships as Two Independent Angular Applications, Not One Shell

## Status

Accepted

## Context

`docs/client/README.md` already draws the `Customer`/`Support Agent`+`Admin` actor line into two planned repos, `kart-web` and `kart-admin-web`, citing `system-context.md`'s existing two-consumer model of the API Gateway. That reasoning was never closed out as a formal, citable decision with its deployment/scaling/CI-CD/security consequences spelled out — this ADR is that closure, requested explicitly as part of bringing the client-tier documentation set to implementation-ready completeness.

Two shapes were considered:

1. **Single Shell** — one Angular workspace/repo, one deployable, with `Customer` and `Support Agent`/`Admin` as role-gated route trees behind one router (optionally using Angular's native lazy-loaded feature modules or Module Federation remotes to keep the two experiences code-split within the one shell).
2. **Two independent applications** — `kart-web` and `kart-admin-web`, each its own repo, its own deploy unit, its own pipeline, consuming a shared component/token package (`kart-design-system`, see `docs/client/design-system.md`) rather than shared source.

## Decision

**Two independent Angular applications.** `kart-web` (public storefront, `Customer`) and `kart-admin-web` (back-office console, `Support Agent`/`Admin`) ship as separate repos, separate deploy units, separate pipelines — confirming `docs/client/README.md`'s existing default rather than revisiting it.

### Why

| Factor | Single Shell | Two Apps (chosen) |
|---|---|---|
| Traffic profile | One deployable must scale for both millions of anonymous customers *and* a few hundred internal staff — the anonymous load ceiling (BRD §3: 10M RPM) forces every pod to carry admin-console code it never serves at that scale | Each app scales to its own actual load — `kart-web`'s SSR tier scales to the BRD's public ceiling; `kart-admin-web` scales to a low-hundreds internal-user ceiling, at a fraction of the infrastructure cost |
| Rendering strategy | `kart-web` requires mandatory SSR (SEO, anonymous-traffic LCP); `kart-admin-web` has no SEO surface and gains nothing from SSR's Node-runtime cost — one shell would force one rendering strategy on both, or fork the build into two rendering modes inside one repo (equivalent complexity to two repos, minus the deploy isolation) | Each app picks the rendering strategy its own traffic actually needs — `kart-web` SSR, `kart-admin-web` plain SPA |
| Blast radius | A bug, dependency vulnerability, or bad deploy in either surface risks the other — an admin-console regression could take down the storefront's build/deploy pipeline it shares, and vice versa | A `kart-admin-web` incident (bad deploy, dependency CVE, outage) has zero blast radius on the public storefront's availability, and vice versa — matches the platform's own 99.99%-order-path posture, which cannot depend on an internal tool's health |
| Release cadence | Coupled release trains — an internal-tool hotfix (e.g., a new admin permission screen) forces a full storefort regression pass before it can ship, or the shell needs its own internal feature-flagging to decouple releases, again reinventing what two repos give for free | Fully independent release cadence — `kart-admin-web` ships an internal-tool fix same-day with no storefront regression risk, `kart-web` ships a storefront change with no admin-console coordination |
| Security posture | `Admin`/`Support Agent` credentials are a materially higher-value target (`kart-admin-web/requirement-spec.md` §5: "an internal tool with elevated privilege is a *higher*-value attack target per credential, not a lower one") — bundling its code into the same deployable as the public, anonymous-traffic-facing app widens that surface's exposure (the admin bundle's client-side code, even role-gated, still ships to every anonymous visitor's browser in a single-shell build unless Module Federation remote-loading is added — which reintroduces two independently-versioned deployables in practice) | The admin-console's code, dependencies, and CSP never reach an anonymous customer's browser at all — it isn't part of `kart-web`'s bundle, isn't part of `kart-web`'s CSP/allow-list, and isn't reachable at `kart-web`'s domain |
| Consistency mechanism | N/A — one repo makes shared UI trivially consistent by construction, but at the cost above | Consistency is enforced by both apps consuming the same versioned `@kart/design-system` package (`docs/client/design-system.md`), the same pattern the backend already uses for cross-service consistency (shared standards + a narrow published-package boundary, never shared source) — proven at platform scale already, not a new risk |

This is the same "independent repo, independent deploy, independent CI/CD" non-negotiable the BRD already applies to every backend service (`PLATFORM_BLUEPRINT.md` §2.1), applied to the client tier for the same reason: two consumers with materially different scaling, security, and release-cadence profiles are never merged into one deployable anywhere else in this platform, and the client tier is not a special case.

## Deployment Implications

- Two container images, two K8s Deployments, two Helm charts (reusing `kart-infra`'s existing per-service chart template, parameterized the same way any 19th/20th deployable already is).
- `kart-web`: stateless SSR pods behind HPA on request-latency/queue-depth (per `kart-web/architecture.md`'s existing Hosting section), CDN in front for static assets, deployed to the full multi-region/CDN-edge posture the BRD's 10M-RPM ceiling requires.
- `kart-admin-web`: a single-region (or the platform's primary region only) static-SPA deployment behind a lightweight origin/CDN, no SSR runtime tier, no multi-region requirement — a materially cheaper topology, appropriate to its internal traffic profile.
- Neither app's deploy pipeline can block the other's — a `kart-admin-web` rollback never touches `kart-web`'s running pods or vice versa.

## Scaling Implications

- `kart-web` scales horizontally on its own SSR-render-time metric, independent of `kart-admin-web`'s load entirely — an admin-console traffic spike (e.g., a mass support incident) cannot starve storefront capacity, and a Black-Friday storefront spike never forces the admin console to over-provision defensively.
- `kart-admin-web`'s ceiling is staff headcount, not customer count — it never needs to plan for the BRD's 10M-RPM figure, and its infrastructure budget reflects that instead of being sized to the larger app's numbers by association.

## CI/CD Implications

- Two `.github/workflows/ci.yml` pipelines, both calling `kart-devops`'s shared reusable workflows (same reuse mechanism every backend repo already uses) but instantiated with app-appropriate gates — `kart-web`'s pipeline includes a Lighthouse CI budget gate and an SSR smoke test that `kart-admin-web`'s does not need; `kart-admin-web`'s pipeline is correspondingly lighter and faster, which matters for an internal tool's iteration speed.
- A `kart-design-system` version bump triggers a Dependabot/Renovate PR independently against each consumer repo (`docs/client/design-system.md`) — each app upgrades on its own schedule, reviewed like any other dependency bump, never a forced simultaneous cutover.
- Independent `CODEOWNERS`, independent required-status-checks, independent branch-protection rules per repo, matching every other Kart repo (`PLATFORM_BLUEPRINT.md` §2.5).

## Security Implications

- Separate CSPs, separate allow-lists, separate origin/domain — `kart-admin-web` is never reachable from `kart-web`'s origin and vice versa, so a CSP or CORS misconfiguration in one cannot be exploited to pivot into the other.
- `kart-admin-web`'s elevated-privilege session policy (`docs/client/security.md`) applies uniformly to 100% of that app's code, with no lower-privilege anonymous code path sharing the same bundle/runtime to reason about.
- Dependency vulnerability scanning (Dependabot, per `PLATFORM_BLUEPRINT.md` §2.5) surfaces and is remediated per repo — a vulnerable transitive dependency pulled in by an admin-only library never becomes a live CVE in the public storefront's bundle.
- Enterprise SSO/SAML federation (`kart-admin-web/requirement-spec.md` §5) is configured and scoped to exactly one app's domain — it is not a credential/redirect surface the public storefront's domain needs to be aware of or defend against at all.

## Consequences

- `docs/client/README.md`'s existing "why two client apps" rationale is now backed by this ADR rather than standing as an unreferenced doc-local argument — update its "Relationship to the standards this is built on" section to cite ADR-0022.
- No change to either app's already-drafted `requirement-spec.md`/`architecture.md` boundary decisions — this ADR formalizes what those docs already assumed, it does not revise them.
- Future proposals to merge the two apps (e.g., "just add an `/admin` route to `kart-web`") must supersede this ADR explicitly, not be decided ad hoc inside either app's own docs.
