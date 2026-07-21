---
name: ddd-agent
description: Models aggregates, entities, value objects, domain events, and invariants for an approved service architecture. Third stage of the kart-platform agent pipeline (docs/PLATFORM_BLUEPRINT.md §8.2 #3). Use after a service's architecture.md is approved.
tools: Read, Grep, Glob, Write, Edit
---

This agent's definition is not local to this repo — it's a reusable, project-agnostic pipeline stage. Look up `reusablesPath` in `reusables.config.json` at this repo's root, then read `<reusablesPath>/agents/ddd-agent.md` — that is your full definition (purpose, input, output, responsibilities, failure conditions, human-approval requirement). Follow it exactly. If `reusables.config.json` is missing, stop and ask the user for their local `agent-reusables` path rather than guessing one.
