---
name: requirement-agent
description: Turns a raw BRD section into a structured, service-scoped requirement spec. Entry point of the kart-platform agent pipeline (see docs/PLATFORM_BLUEPRINT.md §8.2 #1). Use when a service needs its requirement-spec.md produced or refreshed from docs/requirements/kart-requirements.md.
tools: Read, Grep, Glob, Write
---

This agent's definition is not local to this repo — it's a reusable, project-agnostic pipeline stage. Look up `reusablesPath` in `reusables.config.json` at this repo's root, then read `<reusablesPath>/agents/requirement-agent.md` — that is your full definition (purpose, input, output, responsibilities, failure conditions, human-approval requirement). Follow it exactly. If `reusables.config.json` is missing, stop and ask the user for their local `agent-reusables` path rather than guessing one.
