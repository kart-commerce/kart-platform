---
doc_type: standard
service: null
status: accepted
layer: release-engineering
---

# Common Release Mistakes & Precautions

Enterprise release-engineering mistakes, organized by category, that `scripts/release.sh` pulls a release-specific subset from (`releases.json`'s `top_mistakes`) into every generated release doc. This file is the full catalogue; the generated docs only show the ones most relevant to that release's scope. Read the full list before any release that touches a new category for the first time (e.g., the first release with a money-moving endpoint, the first release with a DB migration).

## Data & Migrations

- **Non-backward-compatible migration deployed in the same release as the code that needs it.** Old pods still running the previous version must survive against the new schema during a rolling deploy. Use the expand-contract pattern: add the new column/table nullable or with a default first (release N), backfill, switch reads/writes (release N), drop the old column only in a later release once nothing references it.
- **Migration that isn't reversible.** Every migration needs a tested `down` script, even if you don't expect to use it — "we'll just roll forward" is not a rollback plan.
- **Load-testing against an empty or tiny staging dataset.** Bottlenecks that only appear at production data volume (index cardinality, query plan changes, connection pool exhaustion) will not reproduce against a 10-row table.

## Contracts & Compatibility

- **Breaking an API/event contract without a version bump.** Additive-only changes are a minor version; anything a consumer's existing deserialization could break on is a new major version path, old one deprecated on a documented timeline (`PLATFORM_BLUEPRINT.md` §15 Versioning standard).
- **Assuming "no consumers yet" instead of checking the actual consumer registry.** The Contract Compatibility Agent fails closed for a reason — an unknown/stale consumer registry must be treated as "assume breaking," never assumed safe.
- **Shipping a new published event without adding its row to the platform Event Catalog** (BRD §10) — this is exactly the class of gap ADR-0007/ADR-0008 had to retroactively fix platform-wide.

## Money-Path Specific (Payment, Order, Refunds)

- **Missing or incorrect `Idempotency-Key` handling on a money-moving POST.** This is the single most expensive mistake class on this platform — a client or gateway retry without idempotency protection means a double charge or a duplicate order, not just a duplicate log line.
- **Testing only the Saga's success flow, not its compensation flow.** BRD §12.2's failure/compensation path (Inventory release, Payment refund) needs the same load and chaos rigor as §12.1's success path — a compensation step that only works at low concurrency is not tested.
- **Reconciliation logic that assumes exactly-once delivery.** The platform's own NFR is at-least-once delivery + idempotent consumers (BRD §3) — any handler for a money-moving event must be safe to receive twice.

## Testing & Load

- **Calling a release done after only a happy-path load test.** A load test that never exceeds normal traffic proves nothing about the failure mode under stress — run the tier the release actually calls for (see each release's `load_test` block), not a lighter one because it's more convenient.
- **Not verifying HPA scaling triggers during a stress test.** The point of the High/Extreme tier tests is partly to prove autoscaling actually engages before a queue backs up or a DLQ fills — a stress test that only measures latency and ignores whether HPA fired hasn't tested the thing it claims to.
- **Running the BRD §26 chaos suite against Production instead of Staging by accident.** Confirm the target environment explicitly before every chaos experiment — this is a blast-radius mistake, not a logic bug.
- **Skipping the DLQ/retry-tier verification for a new event consumer.** A silently-dropped message is invisible until a customer or an audit notices — verify the retry/DLQ policy actually fires in a test, don't just read it off the design doc.

## Deployment & Rollback

- **No rollback/compensation plan documented before deploy.** "We'll just roll forward" is not a plan — the Incident/Rollback Agent's pattern (one rollback attempt, then page a human, never loop) needs an actual target to roll back to.
- **Skipping canary and going straight to 100% production traffic on a first deploy.** The Deployment Verification gate (`PLATFORM_BLUEPRINT.md` §11) exists specifically to catch a bad deploy before it's fully live — canary-then-ramp is the default, not an optional nicety.
- **Deploying interdependent services in the wrong order within a release.** "Approved on paper" is not the same as "the real contract is live in this environment" — verify the actual deployed dependency, not its design-doc status.
- **No tagged, versioned release commit.** Without a tag, a future rollback target is ambiguous — every release gets a semver tag at the point it's actually deployed, not just a documented plan.

## Security

- **Secrets or credentials committed accidentally.** Config vs. Secret confusion (a value that should be a K8s `Secret` ending up in a `ConfigMap` or, worse, a literal in source) is a recurring, entirely preventable mistake class — review every config diff in a release for this specifically.
- **Skipping the Security Review gate because "it's just a small change."** Gate ordering is fixed for a reason (`PLATFORM_BLUEPRINT.md` §11) — a later gate never runs before an earlier one has passed, regardless of how small the diff looks.
- **A system-wide security pass skipped because each service already passed its own review.** Cross-service authorization gaps (e.g., a service trusting a claim it should re-validate) are structurally invisible to a single-service review — this is why Release 9 has its own dedicated pass.

## Process / Governance

- **Merging without the human PR approval gate**, treating the Code Review Agent's advisory verdict as sufficient. It is explicitly advisory — human approval is required regardless of the agent's verdict.
- **Silently re-ordering a release's scope without updating both `DEVELOPMENT_PLAN.md` and `releases.json` in the same change.** These two files must never diverge — if one changes, the other does too, in the same PR.

## Frontend-Specific

- **A stale feature flag left in code past its feature's 100% production rollout.** `docs/client/api-strategy.md`'s own rule: delete the flag the same or next sprint — an accumulating pile of dead conditionals is tracked tech debt, not a free pass.
- **Flipping a flag to 100% Production without a Staging/UAT soak period with the contract-validation gate continuously green.** Stage 3 of the four-stage integration workflow is not optional, even under release-date pressure.
- **A `🚧`-flagged feature failing open with a broken call or console error instead of the documented "coming soon" empty state.** This is what actually confuses QA about whether something is a real bug — the empty-state fallback is mandatory, not a polish item.
