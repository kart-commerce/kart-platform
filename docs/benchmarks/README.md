---
doc_type: standard
service: kart-platform
status: accepted
layer: observability
---

# Benchmarks

Dated, per-service load-test results — the executed counterpart to the load-testing tiers defined in [kart-requirements.md §25](../requirements/kart-requirements.md). A benchmark record is evidence a target was met (or a documented gap), not a design decision — design intent for capacity lives in the BRD (§4 Capacity Planning); this folder is what actually happened when a service was run against that plan.

## Naming

`<service-name>-<yyyy-mm-dd>.md`, e.g. `kart-order-service-2026-07-21.md`. One file per benchmark run; never overwrite a prior run's file — a re-run against the same tier is a new dated file, so regressions are visible in the file history rather than lost.

## What Belongs Here

- Load-test results against the tiers in BRD §25 (100 RPM smoke → 10M+ RPM flash-sale stress).
- Any run that changes the "current known ceiling" for a service (first bottleneck found, breaking point discovered).

## What Doesn't Belong Here

- Chaos-engineering experiment outcomes or incident analysis — see [../postmortems/](../postmortems/).
- Capacity *planning* assumptions (DAU, orders/day, catalog size) — those stay in BRD §4 and only change via the BRD's own change process.

## Template

See [0000-benchmark-template.md](0000-benchmark-template.md) for the report structure — it mirrors the fields BRD §25 already specifies (P50/P95/P99 latency, error rate, throughput achieved vs. target, resource saturation point, time-to-recovery), so a filled-in report is directly comparable across services and across runs of the same service.
