---
doc_type: standard
service: kart-platform
status: accepted
layer: observability
---

# Postmortems

Blameless, dated write-ups of production incidents and significant chaos-engineering findings — the record of *what actually broke*, as distinct from the runbook of *how to respond while it's breaking* (that lives in `docs/runbooks/`, per [PLATFORM_BLUEPRINT.md §3](../PLATFORM_BLUEPRINT.md)) and the *hypothesis being tested* (BRD [§26 Chaos Engineering](../requirements/kart-requirements.md)).

This mirrors what the platform blueprint already assigns to the Monitoring Agent and Incident/Rollback Agent (§8.2 #20, #24): a monitoring breach or chaos experiment produces an incident record written to Decision Memory. A postmortem file here is the human-readable, git-durable counterpart of that record.

## Naming

`<service-name>-<yyyy-mm-dd>-<short-slug>.md`, e.g. `kart-payment-service-2026-07-21-charge-double-retry.md`.

## What Belongs Here

- Any incident that breached an NFR target in [kart-requirements.md §3](../requirements/kart-requirements.md) (availability, latency, data-loss).
- A chaos-engineering experiment (BRD §26) whose observed behavior *diverged* from the hypothesis — a confirmed hypothesis doesn't need a postmortem, a surprising one does.
- Any production rollback executed by the Incident/Rollback Agent.

## What Doesn't Belong Here

- Routine load-test results, even ones that find a bottleneck — see [../benchmarks/](../benchmarks/).
- Step-by-step response procedures — those are runbooks, kept current *before* an incident, not written after one.

## Template

See [0000-postmortem-template.md](0000-postmortem-template.md).
