# ADR-008 — Terraform Deferred to Phase 4
**Status:** Accepted
**Date:** 2026-06-22
**Phase:** Phase 1 · Week 2 · Linux & Systems Foundations

## Context

Week 2 is about filesystems, disk exhaustion, and memory pressure — one operating-
system layer, studied until it is understood. Partway into planning it, a tempting
detour appeared: a "light-touch" Terraform slice that would put the EC2 instance,
its security group, and its key pair under Terraform now, instead of waiting for
the full infrastructure rewrite in Phase 4. The pitch was muscle memory — get the
hands used to HCL early so Phase 4 starts from familiarity rather than a blank file.

The idea was taken seriously enough to reach three concrete implementation
questions before anyone stopped to ask whether it belonged in Week 2 at all: how to
adopt (greenfield resources vs. importing the existing instance), how far to scope
(compute-only vs. pulling the VPC in too), and how a Terraform-managed box would
interact with the disk-fill and OOM incident work already planned for the week.
Today, that provisioning is entirely manual — the instance, security group, and key
pair were created by hand in the console, with Ansible owning everything from the OS
up. Terraform would be a brand-new tool, with its own mental model, dropped into the
middle of a week reserved for something else.

## Decision

Defer Terraform entirely to Phase 4. No light-touch version in Week 1 or Week 2.
Infrastructure provisioning — EC2, security groups, key pairs — stays manual and
Ansible-managed until Phase 4 picks it up deliberately. This ADR is the boundary
record for that deferral; it will be superseded in Phase 4 by an ADR that draws the
real line between the two tools — Terraform owning infrastructure, Ansible owning
configuration and deploy.

## Alternatives considered

**Light-touch Terraform now, scoped to three resources on the default VPC with
local state** — rejected. Everything that makes Terraform worth learning — modules,
remote state, drift detection, composing multiple environments — is invisible at
three resources. At that scale Terraform teaches you its syntax and hides its
purpose: you would come away fluent in HCL and innocent of every problem HCL exists
to solve, which is precisely the false confidence that has to be unlearned in
Phase 4 anyway.

**Full Terraform now, replacing Ansible outright** — rejected. Far too large a
swing to take mid-project, and it inverts the order this project insists on: get the
stack correct first, overhaul the toolchain second. That is the build-first
discipline ADR-007 already committed to, applied to infrastructure tooling.

**Defer entirely to Phase 4** — accepted, for the reasons above.

## Consequences

### What the system gains
- Week 2 stays on one dominant concept — Linux filesystems, disk exhaustion, memory
  pressure — without splitting attention into an unrelated tool's mental model in
  the same week.
- The one-dominant-concept-per-day rhythm held since Week 1 stays intact.
- Terraform arrives when there is real work for it to do — multi-resource stacks,
  remote state, module composition — so the learning budget is spent on what
  Terraform is *for*, not on its grammar.

### What the system gives up
- No early Terraform exposure; EC2, security-group, and key-pair provisioning stay
  manual through Phase 3.
- Drift in those hand-made resources has no `terraform plan` to catch it. The cost
  of that gap is not hypothetical — the stale security-group rule behind INC-006
  (see ADR-013) is exactly the kind of drift Terraform would surface, and until
  Phase 4 it has to be caught by runbook checks instead.

### CLAUDE.md constraint
"Terraform is not introduced before Phase 4. Infrastructure provisioning (EC2,
security groups, key pairs) remains manual + Ansible-managed until then — see ADR-008."

## Related decisions
- ADR-007 — the discipline-neutral, build-first orientation that this deferral is an
  application of.
- ADR-013 — the INC-006 security-group drift that manual provisioning left
  undetected until an 11-minute hang exposed it; the runbook pre-flight check is the
  stopgap until Terraform drift detection exists in Phase 4.
