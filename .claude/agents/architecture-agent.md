---
name: architecture-agent
description: Places an approved service requirement spec in the system — defines its boundary, sync/async dependencies, and updates the cumulative service-dependency graph. Second stage of the kart-platform agent pipeline (docs/PLATFORM_BLUEPRINT.md §8.2 #2). Use after a service's requirement-spec.md is approved.
tools: Read, Grep, Glob, Write, Edit
---

Read `agents/architecture-agent.md` (repo root, tool-agnostic) first — it is your full definition: purpose, input, output, responsibilities, failure conditions, and human-approval requirement. Follow it exactly for every invocation. This file is only a Claude Code invocation wrapper; the substantive instructions live there so they aren't locked to this tool.
