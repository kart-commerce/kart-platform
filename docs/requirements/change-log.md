---
doc_type: change-log
service: kart-platform
status: accepted
layer: requirements
---

# BRD Change Log

Tracked amendments to `kart-requirements.md` made after its initial approval, per `PLATFORM_BLUEPRINT.md` §3's directory design. Each entry is dated, states what changed and why, and cross-references any cascading updates made elsewhere in the platform docs.

## 2026-07-25 — Observability stack named concretely

**What changed:** §23 Observability and the top-level **Stack** line now name the concrete tools implementing each pillar, instead of describing the pillars generically:

- Structured Logging → **Serilog** → OpenTelemetry Collector (OTLP) → **Grafana Loki**
- Metrics → **Prometheus**
- Distributed Tracing → **OpenTelemetry SDK** → **Grafana Tempo**
- Visualization & Alerting (new row) → **Grafana** (the LGTM stack's single pane of glass)

**Why:** the BRD previously mandated the *pattern* (structured logs, RED metrics, W3C trace propagation) but left tool choice open. The platform has now standardized on the Grafana LGTM stack for every microservice so dashboards, alerting, and cross-service trace correlation work identically across all 18 services rather than per-service tool sprawl.

**Cascading updates made in the same pass:**

- New reusable, project-agnostic standard: `agent-reusables/docs/standards/observability-standards.md` (full pillar detail, package choices, sampling policy, dashboard/alerting conventions).
- `docs/standards/kart-conventions.md` — new **Observability** section: `Kart.Shared.Observability` package, the 100%-trace-coverage service tier (Order/Inventory/Payment/Shipping), per-service correlation-id field convention, platform stack ownership (`kart-infra`/`kart-devops`).
- `docs/PLATFORM_BLUEPRINT.md` §8.2 Monitoring Agent — Tools row now names Prometheus/Tempo/Loki query APIs explicitly.
- Every `docs/services/<name>/requirement-spec.md` — Observability NFR row added or updated to name the concrete stack and reference the standards above.
- Every `docs/services/<name>/design-decisions.md` — new "Observability & Instrumentation" decision entry recording the per-service correlation field and trace-sampling tier.

No BRD scope, domain rule, or NFR *target* changed — this is a tooling concretization of an existing requirement, not a new requirement.
