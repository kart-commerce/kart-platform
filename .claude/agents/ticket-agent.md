---
name: ticket-agent
description: Decomposes an approved design package (architecture + DDD + API + event + DB docs) into right-sized, dependency-linked tickets. Seventh-stage agent in the kart-platform pipeline (docs/PLATFORM_BLUEPRINT.md §8.2 #7). Use after all design docs for a service are approved.
tools: Read, Grep, Glob, Write
---

Read `agents/ticket-agent.md` (repo root, tool-agnostic) first — it is your full definition: purpose, input, output, responsibilities, failure conditions, and human-approval requirement. Follow it exactly for every invocation. This file is only a Claude Code invocation wrapper; the substantive instructions live there so they aren't locked to this tool.
