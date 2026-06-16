# ADR-007 — Discipline-Neutral Foundation Through Week 20
**Status:** Accepted
**Date:** 2026-06-16
**Phase:** Phase 1 · Week 1 · Linux & Systems Foundations

## Context
NovaPay was conceived as an SRE learning environment. Before building, the
question arose: should the project commit to SRE (or DevOps, or Platform
Engineering) from the start, or defer that choice?

The three disciplines share a large common core — Linux, AWS, containers,
CI/CD, observability — and diverge mainly in emphasis after the foundation
is laid:
- SRE emphasises reliability engineering, SLOs, chaos, toil reduction
- DevOps emphasises deployment pipelines, IaC, developer experience
- Platform Engineering emphasises internal platforms, self-service, Backstage

Committing to one before operating the full stack is choosing a database
engine before understanding access patterns.

## Decision
Build the discipline-neutral common core through Week 20. At the **Week-20
Decision Checkpoint**, choose SRE / DevOps / Platform Engineering based on
evidence from 20 weeks of operating and hardening the stack. Weeks 21+ are
lane-specific.

A soft-lean pulse is logged at ~Week 10 (a one-line tilt, not a binding choice)
so the checkpoint is not a cold start.

## Alternatives considered
**Early SRE commitment** — rejected. SRE-specific work (chaos engineering,
SLO budgets, toil automation) presupposes a stable, observable, correctly
deployed stack. Building chaos tooling before the stack is correctly deployed
is premature. Additionally, committing to SRE before experiencing DevOps
workflows forecloses the possibility of discovering a stronger fit elsewhere.

**Early DevOps commitment** — rejected. Same reasoning. DevOps-specific depth
(pipeline design, gitops, developer platform) is most valuable after the
platform is built. Optimising for developer experience before the service
is reliable is building the wrong layer first.

**No decision ever (permanent neutrality)** — rejected. A generalised SRE/
DevOps/Platform portfolio has less signal value than a deep specialisation.
The Week-20 checkpoint is a deliberate, evidenced choice — not a forced
early commitment or indefinite deferral.

## Consequences
### What the system gains
- All three specialisation lanes remain viable through Week 20. The
  Week-20 choice is made from 20 weeks of hands-on evidence, not from
  upfront guesswork.
- The NovaPay system itself — payment-api, ledger, observability stack —
  can evolve into a showcase for any of the three lanes.
- The learning cadence (build-first, harden, publish weekly) is discipline-
  agnostic and produces a public record regardless of which lane is chosen.
- Certificates (SAA → CKA → Terraform Associate → DevOps Pro) are common
  prerequisites for all three lanes and are pursued in parallel.

### What the system gives up
- The focused narrative of a single-lane project from day one. Job postings
  may favour candidates with a visible lane commitment earlier. Mitigation:
  publish weekly deep-dives that demonstrate the relevant competencies in
  whichever lane the content naturally falls into.
- Post-checkpoint, Weeks 21–34 must execute the chosen lane's curriculum
  without extending the decision timeline further.

### CLAUDE.md constraint to add
"Discipline (SRE/DevOps/Platform) undecided until Week-20 checkpoint — see ADR-007"

## Related decisions
- All other ADRs are discipline-neutral technical decisions that hold
  regardless of the Week-20 choice.
