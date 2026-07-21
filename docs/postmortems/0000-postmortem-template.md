---
doc_type: postmortem
service: <service-name>
status: template
date: <yyyy-mm-dd>
severity: <SEV1 | SEV2 | SEV3>
---

# <service-name> Postmortem — <short title> (<yyyy-mm-dd>)

## Summary

One or two sentences: what broke, for how long, and who/what was affected.

## Impact

|Field|Value|
|---|---|
|NFR breached|<from kart-requirements.md §3, e.g. "Availability 99.99% order path">|
|Duration|—|
|Customer-visible effect|—|
|Data integrity impact|—|

## Timeline

|Time (UTC)|Event|
|---|---|
|—|Detected — how (alert, Monitoring Agent breach, customer report)|
|—|Diagnosed|
|—|Mitigated|
|—|Resolved|

## Root Cause

The actual mechanism, not just the trigger — trace it to the specific component/decision, and note if it traces back to an existing ADR or design doc that missed this case.

## Detection

How the breach was caught — which alert/metric fired, or how long it went undetected if it wasn't automatic. If detection was slow, that's a finding in its own right.

## Resolution

What was done to mitigate, and what (if anything) was rolled back.

## Action Items

- [ ] Fix filed as a ticket (link it) — every action item needs an owner and a ticket, not just a bullet here.
- [ ] Runbook updated, if the response procedure itself was found lacking.
- [ ] Business Rule Memory / Decision Memory updated, if this incident reveals an invariant that wasn't previously documented.
