---
name: architecture-agent
description: Places an approved service requirement spec in the system — defines its boundary, sync/async dependencies, and updates the cumulative service-dependency graph. Second stage of the kart-platform agent pipeline (docs/PLATFORM_BLUEPRINT.md §8.2 #2). Use after a service's requirement-spec.md is approved.
tools: Read, Grep, Glob, Write, Edit
---

This agent's definition is not local to this repo — it's a reusable, project-agnostic pipeline stage. Look up `reusablesPath` in `reusables.config.json` at this repo's root, then read `<reusablesPath>/agents/architecture-agent.md` — that is your full definition (purpose, input, output, responsibilities, failure conditions, human-approval requirement). Follow it exactly. If `reusables.config.json` is missing, stop and ask the user for their local `agent-reusables` path rather than guessing one.
