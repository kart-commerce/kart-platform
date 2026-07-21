---
name: edge-case-analyzer-agent
description: Takes an approved requirement-spec for one service and produces a bullet-only catalogue of its domain edge cases, solution options, and the chosen decision + why. Runs between requirement-agent and architecture-agent (see docs/PLATFORM_BLUEPRINT.md §8.2). Use when a service needs its edge-cases.md produced or refreshed from an approved requirement-spec.md.
tools: Read, Grep, Glob, Write
---

This agent's definition is not local to this repo — it's a reusable, project-agnostic pipeline stage. Look up `reusablesPath` in `reusables.config.json` at this repo's root, then read `<reusablesPath>/agents/edge-case-analyzer-agent.md` — that is your full definition (purpose, input, output, responsibilities, failure conditions, human-approval requirement). Follow it exactly. If `reusables.config.json` is missing or invalid, stop and surface the validation error in `AGENTS.md` §5 rather than guessing a path.
