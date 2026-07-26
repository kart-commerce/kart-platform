---
doc_type: api-strategy
service: null
status: pending-approval
generated_by: human-authored (client tier)
source: docs/client/kart-web/api-integration-map.md, docs/PLATFORM_BLUEPRINT.md §8.2
---

# Backend Dependency Strategy: Kart Client Tier

Answers "how does frontend development proceed before all 18 backend services' APIs exist," operationalizing `api-integration-map.md`'s existing `✅`/`🚧` status key into a concrete workflow rather than leaving `🚧` as prose-only.

## 1. OpenAPI Generation

Every backend service publishes an approved `api-contract.yaml` (already the platform's existing per-service deliverable, `docs/services/<name>/api-contract.yaml`). A CI job in each client app (`core/http/` per `kart-web/architecture.md`) runs `openapi-generator-cli` against each consumed service's published contract, emitting a typed Angular `HttpClient`-based client into `core/http/generated/<service>/` — **no feature code ever hand-writes an HTTP call**; every request goes through a generated, typed method. Regeneration is triggered by a `kart-devops` reusable workflow step watching each service's `api-contract.yaml` for changes; a regenerated client that doesn't compile against existing call sites fails CI immediately, surfacing a contract-breaking change at build time rather than at runtime.

## 2. Mock Server Strategy (MSW)

**Mock Service Worker (MSW)** is the primary mocking mechanism, for three overlapping needs: local development against a `🚧` (not-yet-approved) endpoint, deterministic unit/component tests, and CI component-test runs with no live backend dependency.

- Mock handlers are colocated per feature module (`features/<feature>/testing/handlers.ts`), one handler file per consumed service-slice.
- Handler response shapes are generated skeletons from the **same OpenAPI schema** used for the real client (§1) wherever a contract already exists (even a `🚧` one, if a draft `api-contract.yaml` exists but isn't yet approved) — this guarantees a mock can never silently drift from the contract it's standing in for. Where no contract exists at all yet, a hand-authored handler is written against the requirement-spec's documented shape and flagged for replacement once a real contract lands.
- MSW runs in three contexts identically: local dev server (`npm run start:mock`), component/unit tests, and Storybook (shared with `kart-design-system`, `docs/client/design-system.md`) — one handler set, three consumers, never three separate fixture sets to keep in sync.

## 3. Mock Data

Fixtures are derived from each service's own documented example payloads (`ddd-model.md` aggregate shapes, `event-contract.md` payload examples) — never invented ad hoc per component. A shared `testing/fixtures/` folder per app holds one fixture module per bounded context (`catalog.fixtures.ts`, `cart.fixtures.ts`, etc.), imported by both MSW handlers and component tests so a test and its mock server never disagree about what "a product" looks like.

## 4. Feature Flags

A lightweight, self-hosted flag service (**Unleash**, open-source, avoids a paid-vendor dependency for what is fundamentally a build-gating mechanism) gates every feature whose backend endpoint is still `🚧`:

- Flag naming: `ff-<feature>-<service>` (e.g., `ff-wishlist-price-alerts-wishlist-service`), one flag per `🚧` row in `api-integration-map.md`.
- Default state: **OFF** in Production; **ON** in Development/QA against MSW mocks (§2); flipped ON in Staging/UAT only once that service's real endpoint is deployed there; flipped ON in Production only after a Staging/UAT soak period with no contract-validation failures (§7).
- A flag deleted the same sprint its guarded feature reaches 100% Production rollout — flags are not allowed to accumulate as permanent conditionals (a stale flag still present after its feature is fully live is a tracked tech-debt item, checked in the Deployment Readiness checklist, `docs/client/approval-checklist.md`).

## 5. API Versioning

Client-side, matching each service's own URL-path versioning convention (`/v1/...`, per `docs/standards`'s api-standards.md convention already used platform-wide): generated clients (§1) are versioned per major API version — a service's breaking `v2` change generates a parallel `core/http/generated/<service>/v2/` client alongside the existing `v1/`, and call sites migrate feature-by-feature behind their own flag (§4), never a single big-bang cutover forced by the generator alone.

## 6. Fallback Behavior

Any `🚧`-flagged feature whose flag is OFF renders a graceful **"coming soon"** empty state (reusing the design system's empty-state component, `docs/client/design-system.md`) — never a broken call, a console error, or a silently-missing nav item that confuses QA about whether it's a bug. This matches the platform's existing fail-open philosophy already documented for Recommendation Service's own degraded-mode behavior (`api-integration-map.md`), generalized to "any dependency that isn't ready yet," not only "any dependency that's temporarily down."

## 7. Contract Validation

A CI gate (`kart-devops` reusable workflow step) runs schema-conformance tests — the generated client's actual request/response shapes checked against the live-deployed service's OpenAPI schema in the target environment (Dredd- or Schemathesis-style contract testing) — before a flag can be flipped ON in Staging/UAT or Production. A mismatch (the deployed service's real shape has drifted from its published `api-contract.yaml`) fails the gate and blocks the flag flip, not just the generated-client regeneration step in §1 — this is the platform's existing Quality Gate pattern (`PLATFORM_BLUEPRINT.md` §11), applied to the frontend-backend contract boundary specifically.

## 8. Frontend Integration Workflow

A concrete four-stage lifecycle per `🚧` feature, closing "how frontend development proceeds before all APIs exist":

1. **Mocked** — built entirely against MSW (§2/§3), flag OFF everywhere except Development/QA. Feature is fully implemented, tested, and demoable with zero live-backend dependency.
2. **Contract-Tested** — the service's real `api-contract.yaml` is approved; the generated client (§1) replaces the mock in a non-flag-gated integration-test lane; contract validation (§7) passes against a deployed instance (at minimum a Staging deployment). Flag remains OFF in Production.
3. **Staged** — flag flipped ON in Staging/UAT against the real deployed service; soak period (minimum one full QA cycle) with contract-validation gate (§7) continuously green.
4. **GA** — flag flipped ON in Production; the flag itself is deleted the same or next sprint (§4) once rollout is confirmed at 100%.

Every `🚧` row in `api-integration-map.md` is expected to move through exactly these four stages — the map is updated (status flipped from `🚧` to `✅`, endpoint path/method recorded) at the transition from stage 1 to stage 2, not left stale once a contract exists, per that document's own existing "Open Questions Carried From This Map" note.
