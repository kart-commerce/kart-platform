---
name: ticket-agent
description: Decomposes an approved design package (architecture + DDD + API + event + DB docs) into right-sized, dependency-linked tickets. Seventh-stage agent in the kart-platform pipeline (docs/PLATFORM_BLUEPRINT.md §8.2 #7). Use after all design docs for a service are approved.
tools: Read, Grep, Glob, Write
---

This agent's definition is not local to this repo — it's a reusable, project-agnostic pipeline stage. Look up `reusablesPath` in `reusables.config.json` at this repo's root, then read `<reusablesPath>/agents/ticket-agent.md` — that is your full definition (purpose, input, output, responsibilities, failure conditions, human-approval requirement). Follow it exactly. If `reusables.config.json` is missing, stop and ask the user for their local `agent-reusables` path rather than guessing one.
