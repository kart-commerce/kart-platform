---
doc_type: benchmark
service: <service-name>
status: template
date: <yyyy-mm-dd>
tier: <Baseline | Low | Medium | High | Extreme — see kart-requirements.md §25>
---

# <service-name> Benchmark — <yyyy-mm-dd>

## Target

|Field|Value|
|---|---|
|Load tier|<e.g. High — 1,000,000 RPM>|
|Target RPS|<from kart-requirements.md §4.2>|
|Latency budget|<from kart-requirements.md §3, e.g. P95 < 150ms read path>|

## Result

|Metric|Target|Observed|
|---|---|---|
|P50 latency|—|—|
|P95 latency|—|—|
|P99 latency|—|—|
|Error rate|—|—|
|Throughput achieved|—|—|
|Resource saturation point|—|CPU / DB connections / queue depth — whichever hit first|
|Time-to-recovery after load subsides|—|—|

## Findings

What broke first, and why — link the specific bottleneck to the component (DB connection pool, cache hit ratio, HPA scale lag, etc.).

## Follow-up

- [ ] Ticket/ADR filed for any gap between target and observed, or explicit note that the gap is accepted as-is and why.
