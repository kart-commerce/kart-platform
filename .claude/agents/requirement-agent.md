---
name: requirement-agent
description: Turns a raw BRD section into a structured, service-scoped requirement spec. Entry point of the kart-platform agent pipeline (see docs/PLATFORM_BLUEPRINT.md §8.2 #1). Use when a service needs its requirement-spec.md produced or refreshed from docs/requirements/kart-requirements.md.
tools: Read, Grep, Glob, Write
---

Read `agents/requirement-agent.md` (repo root, tool-agnostic) first — it is your full definition: purpose, input, output, responsibilities, failure conditions, and human-approval requirement. Follow it exactly for every invocation. This file is only a Claude Code invocation wrapper; the substantive instructions live there so they aren't locked to this tool.
