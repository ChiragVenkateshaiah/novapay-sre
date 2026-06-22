# ADR-013 — Deterministic Pre-flight Checks Over a Validation Subagent
**Status:** Accepted
**Date:** 2026-06-22
**Phase:** Phase 1 · Week 2 · Linux & Systems Foundations

## Context

It was supposed to take ten seconds. During Day 9's INC-006 disk-fill observation,
five test charges were fired from WSL2 at the EC2 box — and then nothing. No
response, no error, no output. Eleven minutes and fifteen seconds later the curl
loop was still hanging, and the journald log on EC2 showed not a single matching
entry: the requests were not slow, they were never arriving.

The cause, once found, was almost banal. The EC2 security group still carried an
inbound rule for port 8080 pinned to a WSL2 public IP from whenever that rule was
first written — long since rotated out from under it. Port 22 had its own separate,
correctly-open rule, which is why SSH worked perfectly the entire time and quietly
sold a false promise: if I can reach the box, the app on it must be reachable too.
The two ports' rules had drifted apart independently, and every tool on hand was
blind to it by construction — `/healthz` reports the app, `systemctl status`
reports the unit, `journalctl` reports the logs, and each does so correctly. Not one
of them sits at the WSL2-to-EC2 network boundary, which is the exact seam where the
failure lived.

That eleven-minute hole raised a fair question: should NovaPay build a Claude Code
subagent to validate test preconditions — network reachability, environment state —
before any developer-initiated test run?

## Decision

No subagent. Close the gap with a deterministic pre-flight check baked into the
runbook that exposed it (`scripts/disk-fill-demo.sh`), plus an optional reachability
check folded into `/check`.

## Alternatives considered

**Build a validation subagent** — rejected. Nothing about this failure was a
judgment call. It was one binary fact — is port 8080 reachable from this machine —
answerable by one curl and an exit code. Reaching for an LLM to decide a question a
shell guard settles instantly and deterministically is the precise mismatch this
project has refused everywhere else: it is the same reason `disk-fill-demo.sh`
protects the root filesystem with a hard `df` check under `set -e` rather than asking
an agent whether there's enough space. Subagents earn their cost on genuinely
ambiguous interpretation — triaging whether a noisy spread of signals across several
log sources is a real incident or just noise. A reachability check is a fact with an
exit code, not a judgment with a prompt.

**Do nothing and treat it as a one-off** — rejected. The shape of this failure — a
silent multi-minute hang hiding an instantly checkable fact — is not specific to
INC-006. It can recur on any future day that fires requests from WSL2 at EC2, and a
guard that costs one line is cheaper than diagnosing the same hang twice.

## Consequences

### What the system gains
- The failure mode is closed by a one-line, zero-maintenance shell check, cut from
  the same cloth as every other guard already in the project.
- `/check`'s reachability step keeps the port 22 vs. port 8080 distinction visible on
  every routine run — surfaced on purpose, not rediscovered the next time a hang
  forces the diagnosis.
- No new infrastructure and no new failure surface of its own.

### What the system gives up
- Nothing meaningful — the change is strictly additive.

### Revisit condition
Revisit a subagent-based approach only if a future phase brings genuine multi-signal
interpretation into the workflow — not anticipated in Phase 1 or Phase 2.

## Related decisions
- ADR-008 — Terraform's drift detection would have caught the stale security-group
  rule behind INC-006; until Phase 4 introduces it, this pre-flight check is the
  manual-provisioning stopgap.
