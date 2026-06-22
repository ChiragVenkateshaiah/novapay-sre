# ADR-012 — No Meta-Harness (Omnigent) for the NovaPay Agentic Workflow
**Status:** Accepted
**Date:** 2026-06-22
**Phase:** Phase 1 · Week 2 · Linux & Systems Foundations

## Context

Day 8 had just closed when a question surfaced about the workflow itself rather than
the code: should NovaPay adopt a meta-harness? The specific candidate was Omnigent, a
recently released open-source framework that runs several distinct AI coding agents —
Claude Code, Codex, Cursor, and others — under one unified runtime, routing each kind
of task to whichever agent handles it best. Nothing was broken. No pain point forced
the question; it came from encountering the idea and wanting to test it honestly
against what NovaPay actually needs rather than what sounds sophisticated.

What NovaPay actually runs today is deliberately small: one agent, Claude Code CLI,
on a two-model strategy — Sonnet for daily execution, Opus for the weekly
architectural planning sessions. The weight of the workflow does not live in the
agent at all. It lives in the layer hand-built around it: a PreToolUse hook that
blocks an unguarded deploy, the ADR-driven architectural constraints loaded into
CLAUDE.md every session, a GitHub-issue-driven incident lifecycle, and a set of custom
commands that turn the project's operating discipline into first-class tools. That
layer is the asset. The question, properly framed, was whether a meta-harness would
add to it or merely sit underneath it.

## Decision

Do not adopt a meta-harness. Keep running a single Claude Code CLI agent on the
existing Sonnet/Opus split.

## Alternatives considered

**Adopt Omnigent to route different task types across different models or tools** —
rejected. A meta-harness earns its keep when different agents have genuinely
different strengths across genuinely different subsystems; it is an answer to a
question NovaPay has not asked. NovaPay has one codebase, one operator, and a
two-model split that already captures the only distinction that has ever mattered
here — execution versus reasoning a decision from scratch. Routing work between
several agents optimizes the one part of the workflow that was never the bottleneck,
while adding a second infrastructure layer to keep alive — a session backing store,
orchestration-level debugging — and unlocking no capability the project currently
lacks.

**Adopt it speculatively, in case it proves useful later** — rejected. This is the
scope ceiling from ADR-007 pointed at tooling instead of code: do not stand up
infrastructure that does not unlock something the project needs today. The part of
the NovaPay agentic story worth showing is the hand-built guardrails; bolting a
meta-harness underneath them adds a layer and subtracts focus.

## Consequences

### What the system gains
- No second infrastructure layer to maintain — no orchestration runtime, no session
  store — on a project run by one person around a full-time learning schedule.
- The guardrails — deploy-blocking hook, ADR constraints, incident lifecycle — stay
  the visible, defensible center of the workflow, not something half-hidden beneath a
  framework that isn't carrying its weight.

### What the system gives up
- No early hands-on exposure to multi-agent orchestration patterns.
- If a real need for multi-agent routing ever arrives, the evaluation starts cold
  rather than from a foundation already in place.

### Revisit condition
Reconsider only if the workflow grows to need genuinely different agents for
genuinely different subsystems — for example, a future frontend or dashboard
component distinct enough from the backend Go work to reward a specialized agent.
Not anticipated before Phase 4 at the earliest, if ever.

## Related decisions
- ADR-007 — the scope-ceiling and build-first principle whose logic this decision
  extends from code into tooling.
