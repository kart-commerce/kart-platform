---
name: design-decision-agent
description: Takes an approved requirement-spec + edge-cases doc for one service and produces a bullet-only catalogue of its cross-cutting technology/design-pattern decisions (caching, communication style, concurrency control, resilience patterns, etc.) with options considered and the chosen decision + why. Runs between edge-case-analyzer-agent and architecture-agent (see docs/PLATFORM_BLUEPRINT.md §8.2). Use when a service needs its design-decisions.md produced or refreshed.
tools: Read, Grep, Glob, Write
---

This agent's definition is not local to this repo — it's a reusable, project-agnostic pipeline stage. Look up `reusablesPath` in `reusables.config.json` at this repo's root, then read `<reusablesPath>/agents/design-decision-agent.md` — that is your full definition (purpose, input, output, responsibilities, failure conditions, human-approval requirement). Follow it exactly. If `reusables.config.json` is missing or invalid, stop and surface the validation error in `AGENTS.md` §5 rather than guessing a path.
