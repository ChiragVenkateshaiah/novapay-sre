# NovaPay — Project Checkpoint

> **Purpose:** the single source of truth that carries state across weeks. Sonnet updates this as it executes; Opus reads it at the start of each weekly planning session so plans never scatter. Update the "Last updated" line every edit.

**Last updated:** 2026-06-22 (ADR-008/012/013 added; pre-flight guard in runbook + /check) · **Current phase:** Phase 1 (Linux & Systems Foundations) — *common core, discipline-neutral* · **Current week:** Week 2 · **Status:** D8 ☑ — **Day 9 next**

> **★ Decision pending:** discipline (SRE / DevOps / Platform) is deliberately **undecided** until the **Week-20 Decision Checkpoint**. The foundation is build-first and neutral until then. See the decision-gate section below.

---

## Locked decisions (carry forward; change only deliberately)
- Repo `novapay-sre`, public. Name retained for continuity — a **label, not a discipline commitment**.
- **Discipline deliberately undecided.** SRE vs DevOps vs Platform is chosen at the **Week-20 Decision Checkpoint**, from experience — not up front. Weeks 1–20 are the discipline-neutral **common core**.
- **Foundation orientation: build-first — build for correctness, depth-first.** Study failure modes only to **harden** against them (every timeout, retry cap, invariant check is a defense); do **not** manufacture incidents. Reproducibility + demonstrable correctness are the measure. (Break-on-purpose / chaos returns **post-checkpoint, mainly in the SRE lane**.)
- Build path: **minimal payments core, self-built, built for correctness.** No clone, no real PSP, no PCI scope. Reference Blnk + a Go/Postgres double-entry tutorial for patterns only.
- System: `payment-api` (Go) + `fake-psp` (Go) + Postgres double-entry ledger + Redis (later). Grows into the full AWS/EKS/observability/AI stack over the year.
- Core invariant: per payment, sum(debits) == sum(credits). Non-negotiable; do not slim the ledger to a single balances table. Deep concurrency treatment (isolation levels, row locking) is **Week 7**.
- **Dev→deploy workflow: build & test on WSL2 → deploy to EC2 via Ansible.** WSL2 = IDE/build box (Neovim, Go, local Postgres); EC2 = runtime/deploy target. No hand-copying — deployment goes through Ansible (platform-eng muscle from day one).
- **Planning workflow: Opus plans the week → Sonnet executes → checkpoint carries to next week.**
- **Scope ceiling:** build only what **deepens a core competency** (correctness, concurrency, systems, observability, reproducibility); post-checkpoint, also what serves the chosen lane. No payment features for their own sake.
- Cadence: build **daily**, publish **one deep-dive weekly** (build/learning through the foundation; lane-specific after the checkpoint), comment on 5–10 posts daily.
- Cert backbone: SAA → CKA → Terraform Associate → DevOps Pro (discipline-flexible); CCA-F as differentiator. End goal: Canada, NOC 21231.
- Day numbering: weeks run Day 1–7 at real pace, not weekday-locked.

Workflow and tooling decisions are recorded as ADRs in docs/decisions/ — see ADR-008 (Terraform), ADR-012 (Omnigent), ADR-013 (pre-flight validation).

---

## ★ Upcoming decision gate — end of Week 20
After Phase 4 (SAA + CKA + Terraform Associate earned, full stack built correctly), **the executing model STOPS and asks: SRE, DevOps, or Platform?** Do not plan Week 21+ until answered. The chosen lane sets the spine of Weeks 21–34, decides whether break-on-purpose/chaos becomes the model (SRE) or stress-testing (DevOps/Platform), and whether the scope ceiling stays tight (SRE) or relaxes (DevOps/Platform). **Soft-lean pulse ~Week 10:** log a one-line tilt (not a decision) so the gate isn't a cold start.

---

## Architecture build progress
| Component | Target | Status |
|---|---|---|
| `payment-api` | Go service, charge path, idempotency | scaffolded (`/healthz` ✓); charge path + idempotency = Day 2 |
| `fake-psp` | Go stub bank with latency/error/hang knobs | scaffolded; `/authorize` + latency/hang knobs ✓; error-rate knob = Day 4 |
| Ledger | Postgres double-entry (local this week → RDS Week 7) | Day 2 (local Postgres: WSL2 for dev, EC2 local for deploy) |
| Redis | idempotency/cache | deferred (DB unique-constraint handles idempotency this week) |
| systemd | both services managed | Day 3 |
| Ansible | provision + deploy (the IaC workflow) | provision ✓; deploy playbook = Day 3 |
| Observability | CloudWatch + Prom/Grafana + SLOs | Phase 2 |
| Terraform | whole stack as code | Phase 4 |
| AI agent | triage → MCP → gated remediation | post-checkpoint (AIOps, ~wk 29+) |

---

## Incident catalog (legacy) + foundation hardening
**Incident catalog (legacy + post-checkpoint):**
- 0001 — (existing, pre-v2) — logged
- 0002 — (existing, pre-v2) — logged
- **No new incidents during the foundation.** The former "planned incidents" (runaway CPU, zombies, stuck payment) are now **Week-1 hardening tasks**, not incidents. Incident/chaos work **resumes post-checkpoint, if the SRE lane is chosen.**

**Foundation hardening status (Week 1 resilience properties):**
- [ ] Idempotency real — repeated key moves no money (Day 2)
- [ ] Balance invariant holds, incl. under concurrent load (Day 2; deep treatment Week 7)
- [ ] Bounded retries — backoff + jitter + cap (Day 4)
- [ ] Correct goroutine/process lifecycle — no leaks/zombies (Day 5)
- [ ] Timeouts — context deadline + client timeout — + graceful shutdown (Day 6)

---

## Weekly log
### Week 1 — Phase 1: Build a correct payments core + harden it at the process boundary
- **Goal:** build `payment-api` + `fake-psp` on one EC2 box (deployed via Ansible) under systemd, with a correct local double-entry ledger; **harden** the service 3 ways at the process boundary (bounded retries; timeouts + graceful shutdown; correct goroutine lifecycle).
- **Day status:** D1 ☑ D2 ☑ D3 ☑ D4 ☑ D5 ☑ D6 ☑ D7 ☑
- **Built (so far):** WSL2 build env (Go 1.24.3, gopls, Ansible, Neovim); EC2 provisioned via Ansible (Go + Postgres + app/log dirs); `payment-api` (`/healthz`) + `fake-psp` (`/authorize` + latency/hang knobs) scaffolded, compiling, smoke-tested; binaries git-ignored; committed + pushed. `POST /charge` with double-entry ledger (pgx/v5, single transaction, two balanced ledger entries); idempotency enforced via `UNIQUE(idempotency_key)` — repeated key returns original result at latency_ms=0, moves no money; structured `slog` JSON logging (request_id, idempotency_key, latency_ms, psp_status); invariant query confirmed 0 rows; committed + pushed. systemd unit files for `payment-api` and `fake-psp` (restart-on-failure, journald logging, start-on-boot); Ansible `deploy.yml` (builds binaries locally via `delegate_to: localhost`, copies to `/opt/novapay/bin/`, installs unit files, sets up EC2 Postgres user + database via shell module, applies schema, `daemon-reload`, `enable --now`); both services deployed and active on EC2 via single Ansible command; ledger invariant holds on EC2 database (0 rows); committed + pushed. `PSP_ERROR_RATE` knob added to `fake-psp` (returns HTTP 500 on a random fraction of `/authorize` calls); bounded retry in `payment-api` (max 3 attempts, HTTP 5xx only, full-jitter exponential backoff: `random(0, min(1s, 100ms×2^attempt))`), `slog.Warn` on each retry; exhausted attempts return 503, DB transaction never opened — ledger invariant guaranteed on failure path; load-tested under `PSP_ERROR_RATE=0.5` (9/10 charges succeeded, 1 graceful 503, invariant 0 rows, failed charges wrote 0 DB rows); deployed to EC2 (commit `2eef3e9`); committed + pushed. In-process goroutine receipt worker: buffered channel (size 50) as work queue; single `receiptLoop` worker goroutine; non-blocking send from charge handler (`select { case ch <- id: default: }` — charge path never delayed); SIGTERM handler closes channel and waits for worker to drain before exit — clean shutdown without stranding receipts; zero child processes possible (no `exec.Command` in codebase); zombie accumulation eliminated structurally — 15 charges produced 0 defunct processes vs 15 with the shell-out; thread count stable at 9 across 20 charges; INC-004 opened and closed via GitHub MCP; committed `a68b831` and pushed. `context.WithTimeout(ctx, 5s)` derived inside `callPSP` and passed to `http.NewRequestWithContext`; `var pspClient = &http.Client{Timeout: 6 * time.Second}` package-level client (context fires first, client is backstop); retry backoff select updated to `pspCtx.Done()`; `runtime.NumGoroutine()` added to `/healthz` response — goroutine pile-up now visible without SSH; `errors.Is(err, context.DeadlineExceeded)` discriminates timeout (WARN) from other PSP errors (ERROR); goroutines 7→19 during 3 hung charges, back to 7 after 503s returned in ~5.01s each; zero DB rows on timeout (transaction never opens before PSP responds); INC-005 opened and closed via GitHub MCP; committed `c8be95e`.
- **EC2 baseline (D3):** `payment-api` 1.9MB RAM · `fake-psp` 1.1MB RAM · ports 8080/8081 · structured logs to journald (`SyslogIdentifier=payment-api/fake-psp`) · restart-on-failure with 5s backoff · enabled (survives reboot) · 0 payments, invariant clean.
- **Hardening built:** D4 ✓ — bounded PSP retry (backoff + jitter + cap); verified CPU at baseline under 50% error rate. D5 ✓ — correct goroutine/process lifecycle: in-process receipt worker, zero zombies, clean SIGTERM drain. D6 ✓ — context deadlines + HTTP client timeout: `context.WithTimeout(5s)` on PSP call, `http.Client{Timeout:6s}` package-level client as backstop; goroutine count added to `/healthz` response (`runtime.NumGoroutine()`); liveness ≠ healthy demonstrated and fixed; INC-005 opened and closed; commit `c8be95e`.
- **Published:** Week 1 deep-dive drafted (D7 consolidation). Article angle: three hardening properties built in Week 1 — retry resilience, goroutine/process lifecycle, context deadlines. Strongest hook: "liveness ≠ healthy."
- **Carryover / unfinished:** LinkedIn article publish (staged in Day_07 notes)
- **Notes for next planning session:** README is portfolio-quality. ADRs committed (7). Agentic workflow: /generate-questions and /new-adr commands added. Week 2 prereqs all met.

### Week 2 — Filesystems, disk, memory
**Goal:** structured transaction logging + harden against disk exhaustion and OOM kill.

**Build slice:**
- Add structured transaction logging to `payment-api` (writes a log entry per charge to `/var/log/novapay/transactions.log`)
- This sets up the disk-fill hardening work

**Hardening:**
- Bound disk use: log rotation + retention so a busy day cannot fill `/`
- Understand the OOM killer: set memory limits on the systemd units so the ledger writer degrades predictably under memory pressure rather than being killed at random

**Publish angle:** "Designing a payments box that can't fill its own disk."

**Finalized plan (Days 8–14)** — see `docs/plans/week-02-plan.md`:
- D8 ☑ Structured transaction (audit) logging — durable JSON stream, resilient write → ADR-009 ✓
- D9  Disk-fill incident: observe (INC-006) — bounded 64M loopback fs; root never touched
- D10 Disk-fill defence: logrotate + SIGHUP-reopen + journald cap (IaC) → ADR-010, close INC-006
- D11 OOM incident: observe (INC-007) — env-gated balloon, cgroup-v2 cap set first; Postgres safe
- D12 OOM defence: MemoryHigh/Max + OOMScoreAdjust + crash-loop backoff (IaC) → ADR-011, close INC-007
- D13 Integration: clean redeploy + 5-stage gauntlet (per-stage PASS/FAIL) + article draft
- D14 Publish + checkpoint + Week 3 handoff
- **Terraform: NOT this week** — deferred to Phase 4 as originally scoped; no light-touch version.
- **New ADRs:** 009 (audit log), 010 (rotation), 011 (memory). **ADR-008 reserved** for the Phase-4 Terraform boundary decision.
- **New workflow:** /tail-tx, /ec2-disk, /rotate-check, /ec2-mem, /gauntlet; scripts/{disk-fill-demo,oom-demo,gauntlet-week02}.sh.

**Prereqs before Week 2:**
- All Week 1 days complete ✓
- Both services live on EC2 ✓
- ADRs committed ✓
- README portfolio-quality ✓
- Week 1 LinkedIn article published (or drafted) ✓

**Day status:** D8 ☑ D9 ☐ D10 ☐ D11 ☐ D12 ☐ D13 ☐ D14 ☐

**Built (Week 2 so far):** D8 ✓ — structured transaction audit log: `auditWriter` wrapper (`*os.File`) surfaces write errors (ENOSPC etc.) to journald as `ERROR` without failing the charge; `initAuditLog()` reads `TRANSACTION_LOG_PATH` env var (default `/var/log/novapay/transactions.log`), logs single ERROR on open failure, leaves `txLog=nil`; `slog.NewJSONHandler` with `ReplaceAttr` (time→ts RFC3339, level+msg stripped); `event="charge"` written after `tx.Commit()`; `event="charge_idempotent"` at idempotency early-return (idempotency query extended to scan `psp_ref`); `txLogWriter *auditWriter` at package level for Day 10 SIGHUP-reopen; all 6 ACs verified (including AC5 write-resilience: unwritable path → charge 200, DB commits, invariant 0 rows, ERROR logged); deployed to EC2 (`224eafa`); audit log live at `/var/log/novapay/transactions.log`; ADR-009 committed; `/tail-tx` + `/ec2-tx` commands added.

---

## Agentic workflow evolution log
_Updated each day. Tracks how the Claude Code workflow grows alongside NovaPay._

### Week 1 foundation (Days 1–3)
- CLAUDE.md: project intelligence file, read every session
- Custom commands: `/check`, `/deploy-dry-run`, `/deploy`, `/ec2-status`, `/ec2-logs`, `/ec2-invariant`, `/day-start`, `/commit`, `/test-charge`, `/load-test`
- PreToolUse hook: blocks `ansible-playbook` without `--check` (exit 2)
- PostToolUse hook: logs every bash command to `~/.claude/novapay-activity.log`
- MCP: Postgres (dev queries), GitHub (issue + PR workflow)
- `settings.json`: absolute hook paths, permissions allow/deny list

### Day 4 additions
- GitHub MCP workflow: observe failure → create issue → fix → close issue
- `/load-test` command: concurrent charge test under `PSP_ERROR_RATE`, invariant check
- Incident catalog habit: every hardening day generates a GitHub Issue

### Rule: each day adds at least one workflow improvement
Before committing Day N, ask: what does the Claude Code workflow gain today that it did not have yesterday?

---

## Handoff to next Opus planning session (Week 2)
**Next week is Phase 1, Week 2 — Filesystems, disk, memory (build-first).**
- **Build slice:** structured, rotated transaction logging + a sane disk layout (logs vs. data).
- **Harden:** bound disk use (rotation + retention) so a busy day can't fill `/`; understand the OOM killer and set memory limits so the ledger writer degrades predictably under pressure. (No staged outages — these are defenses built in; reproduce a fill/OOM once only to verify the defense.)
- **Publish angle:** "Designing a payments box that can't fill its own disk."
- **Prereqs that must be true before Week 2 starts:** `payment-api` + `fake-psp` running under systemd on EC2 (deployed via Ansible); ledger invariant holding + idempotency real; Week 1 hardening (bounded retries, timeouts, graceful shutdown, goroutine lifecycle) committed.
- **Resolved this week:** Postgres location — **local on WSL2 for dev, local on EC2 for the deploy target; RDS deferred to Week 7.** Receipt generation — **in-process goroutine** (not a shelled-out child), decided on Day 5.
- **Open questions to resolve as they arise:** _(Sonnet logs here.)_
- **Resolved at planning (Week 2):** Terraform deferred to Phase 4 (no light-touch); INC-006 disk-fill bounded via 64M loopback fs (root safe); INC-007 OOM bounded via cgroup-v2 cap-first + env-gated balloon (Postgres safe); audit log is a dedicated resilient file, not journald.
- **Reminder:** discipline still undecided — **Decision Checkpoint at Week 20.**

---

## End-of-day ritual
Run these in order at the end of every day before stopping EC2:

1. `/check`                — final local correctness gate
2. `/commit "DN: ..."`     — commit with descriptive message
3. Deploy manually         — ansible-playbook (after `/deploy-dry-run`)
4. `/ec2-invariant`        — verify EC2 ledger is balanced
5. `/write-note N`         — generate Day_NN.md in notes/
6. Update checkpoint.md    — mark day complete, update Built section
7. stop-vm                 — never leave EC2 running overnight

`/write-note` reads checkpoint.md + the previous day's note + session
context. Run it while the session is still fresh — it cannot reconstruct
details from a cold start.

## Agentic workflow enhancement log
Last updated: 2026-06-19

Standing rule: every day (or every 2 days at minimum), ask:
"What does the Claude Code workflow gain today that it did not have yesterday?"
Enhancements can be: new custom command, MCP integration, hook improvement,
CLAUDE.md update, new ADR, checkpoint structure change.

If no enhancement was made, write "none — carried forward" and it becomes
a prompt to add one the next day.

Week 1 enhancements (summary):
- D1-D3: CLAUDE.md, 8 custom commands, PreToolUse/PostToolUse hooks,
  MCP (Postgres + GitHub), settings.json with permissions
- D4: /load-test command, GitHub Issue workflow (INC-003)
- D5: /write-note command, end-of-day ritual, INC-004 workflow
- D6: goroutine count in /healthz, INC-005 workflow
- D6 (post): 7 ADRs, /new-adr command, CLAUDE.md architectural constraints
  (a Terraform light-touch slice was floated here, then **declined** in Week-2
  planning — deferred to Phase 4; ADR-008 reserved. See Locked decisions.)

### Day 8 additions (2026-06-19)
- `/tail-tx`: tail + `jq`-pretty the local audit log (N lines, default 20)
- `/ec2-tx`: tail + `jq`-pretty the audit log on EC2 — bug caught and fixed
  mid-session (single-quoted SSH string so `wc -l` runs remotely, not locally)
- CLAUDE.md: ADR-009 architectural constraints added; `/tail-tx` + `/ec2-tx`
  listed in command inventory
- `docs/plans/` convention established: week plans committed here, day notes
  gitignored in `notes/` — structural fix applied before Day 8 execution

Week 2 enhancements (remaining):
- D9: /ec2-disk; scripts/disk-fill-demo.sh (structural guard: refuse if / free <1G)
- D10: /rotate-check; logrotate + journald cap as Ansible IaC
- D11: /ec2-mem; scripts/oom-demo.sh (guard: refuse unless MemoryMax set)
- D12: CLAUDE.md memory-limit policy + NOVAPAY_DEBUG demo-only rule
- D13: /gauntlet + scripts/gauntlet-week02.sh (5-stage per-stage reporting)
