# Day 12 — OOM Defence: Permanent systemd Memory Limits (Close INC-007)

**Date:** 2026-06-28
**Phase:** Phase 1 · Week 2 · Linux & Systems Foundations
**Status:** complete ✓
**Commits:** `ad94642` (unit files + checkpoint + plan), `c9cd817` (ADR-011)

---

## Goal

Day 11 observed and contained a cgroup-scoped OOM kill using a transient
`systemctl set-property` that set `MemoryMax=128M` at runtime. That transient cap
is wiped by `systemctl revert` and is not reproduced by a fresh deploy from the
committed repo — it proved the values work, but it is not IaC. Day 12's objective
was to bake `MemoryHigh`, `MemoryMax`, `OOMScoreAdjust`, and `StartLimit*`
permanently into the committed systemd unit files so that every deploy from the
repo carries the same containment guarantee without any post-deploy manual step.

The secondary objective was to verify two properties that the Day 11 transient test
did not cover: (1) that `OOMScoreAdjust=+200` appears in the dmesg kill record
(confirming it is read from the committed unit file, not a transient override), and
(2) that the `StartLimitBurst=5` crash-loop guard actually fires — stopping systemd
from restart-looping indefinitely after repeated OOM kills.

Closing INC-007 and committing ADR-011 were the formal completion gates.

---

## What was actually built

### `infrastructure/systemd/payment-api.service`

Added to `[Unit]`:
```ini
StartLimitIntervalSec=60
StartLimitBurst=5
```

Added to `[Service]`:
```ini
MemoryHigh=128M
MemoryMax=192M
OOMScoreAdjust=200
```

`StartLimitIntervalSec` and `StartLimitBurst` were deliberately placed in `[Unit]`,
not `[Service]`. These directives moved to `[Unit]` in systemd v229; on systemd 255
(the version on EC2), placing them in `[Service]` is silently ignored and the
crash-loop guard never fires. The day-start review of the unit files caught this
before the deploy.

### `infrastructure/systemd/fake-psp.service`

Added to `[Unit]`:
```ini
StartLimitIntervalSec=60
StartLimitBurst=5
```

Added to `[Service]`:
```ini
MemoryHigh=64M
MemoryMax=96M
OOMScoreAdjust=200
```

Tighter values than payment-api: fake-psp's observed idle RSS is 3.9 MB; 64M/96M
is still ~24× headroom over baseline while using less of the box's 911 MB budget.

### `checkpoint.md`

Day status line corrected from `D8 ☑ — Day 9 next` (stale since the pre-session
state) to `D8 ☑ D9 ☑ D10 ☑ D11 ☑ — Day 12 next`. The weekly Day status row
updated to match. The header's `Last updated` date bumped to 2026-06-28 with a
note explaining the correction.

### `docs/plans/week-02-plan.md`

Added a one-line note to the Day 10 journald cap bullet:
```
*(Originally estimated at 100M; 200M was the value actually implemented and
deployed in ADR-010 — plan updated to match reality.)*
```
The plan already showed `200M` in the Harden section and AC4 (it was updated at
deploy time); this note documents the discrepancy for future readers rather than
leaving them to wonder if `200M` was a typo of the original `100M` estimate.

### `docs/decisions/ADR-011-systemd-memory-limit-strategy.md`

New file. Covers: two-stage containment rationale (MemoryHigh throttle vs MemoryMax
hard kill), OOMScoreAdjust ordering for Postgres protection under system-wide
pressure, crash-loop guard rationale, budget arithmetic from live EC2 measurements,
alternatives rejected, consequences. 186 lines.

---

## Core concept — cgroup v2 memory containment as permanent IaC

### The concept explained from first principles

The previous day's note covers cgroup v2 mechanics from first principles. The
Day 12 addition is the distinction between **transient** and **persistent** cgroup
configuration in systemd, and why that distinction is operationally critical.

**Two ways to set a cgroup property in systemd:**

`systemctl set-property <unit> MemoryMax=128M` writes a drop-in to
`/etc/systemd/system.control/<unit>.d/50-MemoryMax.conf`. This directory is
systemd's runtime control hierarchy — it survives service restarts but is wiped
by `systemctl revert <unit>`. It is also invisible to anyone reading the
committed repo: the deployed limits are not reproducible from source.

Editing the unit file in `infrastructure/systemd/payment-api.service` and
deploying it via Ansible writes the same value to
`/etc/systemd/system/payment-api.service`, which is the persistent unit file
hierarchy. This survives reboots, `systemctl revert`, and instance replacement.
Any box provisioned from the committed repo has the same limits — no post-deploy
manual step.

`systemctl show payment-api -p MemoryMax` returns the same value in both cases
(the runtime hierarchy takes precedence when both are set), which is why it is
essential to verify limits via `systemctl show` *after* `systemctl revert` to
confirm you are reading the persistent file and not a transient override.

**`StartLimitBurst` and `StartLimitIntervalSec` — section placement matters:**

These two directives have a history: in systemd versions before v229, they lived
in `[Service]`. In v229 they were moved to `[Unit]`. The systemd parser accepts
them in either section for backwards compatibility with old unit files but only
*applies* them from `[Unit]` in modern versions. A unit file that puts these in
`[Service]` on a v229+ system passes `systemd-analyze verify` without complaint
but the crash-loop guard silently does nothing.

The verification: `systemctl show payment-api -p StartLimitBurst,StartLimitIntervalUSec`
returns the correct values if and only if they are read from `[Unit]`.

**`NRestarts` vs the StartLimit activation counter:**

`NRestarts` (visible in `systemctl show -p NRestarts`) is a cumulative restart
counter: it counts how many times `Restart=on-failure` has been used since the
service was last manually started. It does not reset between activations.

The `StartLimitBurst` counter is a separate sliding-window counter maintained
internally by systemd. It counts activation attempts (starts) within the
`StartLimitIntervalSec` window. When this counter exceeds `StartLimitBurst`,
systemd refuses the next restart and enters `failed`. The `NRestarts` value at
the moment of failure can be much higher than `StartLimitBurst` if prior
restarts happened outside the window.

In the Day 12 crash-loop test: `NRestarts=10` when the burst limit fired. This
reflects restarts from Part 4 (1 restart), Part 5 loop 1 (2 restarts), and
Part 5 loop 2 (7 restarts), accumulated across the whole session. The burst
limit fired because 5+ OOM kills accumulated within a single 60-second window
during the tight loop — visible in journald as `"Start request repeated too
quickly."` The high `NRestarts` total is a session artifact, not evidence the
burst guard was ignored.

### Why it matters for a payments service specifically

A service with `Restart=on-failure` and no `StartLimit*` will restart-loop
indefinitely after an OOM kill if the root cause is not transient (e.g., a
genuine memory leak). On a co-resident Postgres box, a payment-api that crashes
and restarts every 5 seconds is generating reconnection traffic, acquiring and
dropping DB connections, and filling journald — while the operator has no clean
signal that the box is in a degraded state. The charge path continues returning
5xx during each restart window. With `StartLimitBurst=5 / StartLimitIntervalSec=60`,
after 5 kills within 60 seconds the service enters `failed` — silent only if
monitoring is absent, but requiring explicit `systemctl reset-failed` to restart.
This forces operator acknowledgement, which is the right behaviour when a service
is repeatedly crashing.

`OOMScoreAdjust=+200` matters specifically because the `MemoryMax` cap handles
the nominal case (a single runaway service, cgroup-scoped kill). The tail case
is genuine system-wide pressure: both services approaching their caps
simultaneously, or a third process introduced later. In that scenario the
system-wide OOM killer fires, and without a score adjustment it makes a
non-deterministic choice from all processes. `OOMScoreAdjust=+200` on both
app services ensures they are scored above Postgres (which runs at `oom_score_adj=0`)
under any system-wide scenario — the ledger survives regardless of the kill pathway.

### The broken pattern — what was demonstrated

At Day 11 startup, `systemctl show payment-api -p MemoryMax,MemoryHigh` returned:
```
MemoryHigh=infinity
MemoryMax=infinity
```
No cap. Under `MemoryHigh=infinity`, the process's page faults are never throttled.
Under `MemoryMax=infinity`, the cgroup OOM killer's hard ceiling is absent. A
memory leak or a balloon call for `mb=400` on an 911 MB / zero-swap box would
push RSS toward total available RAM — at which point the system-wide OOM killer
fires and selects victims by `oom_score`. Postgres's shared buffer pool gives it
a naturally high score.

Day 11 reasoned through this counterfactual without executing it (the transient
cap went on first). Day 12 verified the defence is permanent.

### The correct pattern — what replaced it

The committed unit files now carry:

```ini
[Unit]
StartLimitIntervalSec=60    # } must be in [Unit] on systemd v229+
StartLimitBurst=5           # } silently ignored in [Service]

[Service]
MemoryHigh=128M             # soft throttle: slows page faults, no kill
MemoryMax=192M              # hard ceiling: cgroup OOM kill if exceeded
OOMScoreAdjust=200          # system-wide OOM score bias: die before Postgres
```

Value selection rationale:
- `MemoryMax=192M`: ~21× the 8.8 MB observed idle RSS of payment-api. Generous
  headroom for goroutine accumulation under load and the Day 7 deep concurrency
  work in Week 7. Revisit if steady-state RSS materially increases.
- `MemoryHigh=128M`: ~67% of MemoryMax, giving the kernel a 64 MB reclaim window
  before the hard kill. If `MemoryHigh == MemoryMax`, the throttle phase is absent.
- `OOMScoreAdjust=200`: a positive value in the kernel's +/- 1000 range; raises
  the process's OOM score so it is selected before Postgres under system-wide
  pressure. Postgres runs at `oom_score_adj=0` (systemd default).
- `StartLimitBurst=5 / StartLimitIntervalSec=60`: allows 4 transient OOM kills
  within a minute (burst tolerance) before declaring a crash loop, matching
  `Restart=on-failure`'s `RestartSec=5s` cadence.

Budget arithmetic (from live EC2 measurement, Day 12):
```
payment-api  MemoryMax:   192 MB
fake-psp     MemoryMax:    96 MB
Postgres RSS (all workers):  75 MB
OS + kernel + journald:      80 MB
Safety margin:               50 MB
──────────────────────────────────
Total:                      493 MB   (of 911 MB)
Remaining headroom:         418 MB   (46% of box free at both service MemoryMax)
```

### The failure cascade — what happens at scale

Without `MemoryMax`: a memory leak in payment-api on a box serving 10k charges/day
(each charge holding goroutine state for 5s) could accumulate RSS over hours. On
a 911 MB / zero-swap box, crossing ~830 MB available triggers the system-wide OOM
killer. The kernel scores Postgres at a high badness value due to its shared buffer
pool. Postgres is killed mid-WAL write. Uncommitted transactions are rolled back
(invariant safe), but in-flight charges receive connection errors and the ledger
is unavailable until Postgres recovers. On this single-node deployment: full outage.

Without `OOMScoreAdjust`: even with `MemoryMax` per service, if both services hit
their caps simultaneously (possible under a traffic spike) and the total exceeds
available RAM, the system-wide OOM killer fires. Without score adjustment, it
could still choose Postgres over an app service if Postgres's footprint is larger
than either individual service's footprint at that moment.

Without `StartLimit*`: a memory leak that persists across restarts (the root cause
is not fixed) produces a silent restart loop. The service thrashes at 5s intervals
indefinitely. Journald fills with OOM kill records. DB connection pool churns.
The operator has no clean alert — `systemctl status` shows `active` between kills.

---

## What was observed

### Pre-deploy: live limits on EC2 (before Ansible deploy)

The Ansible dry-run showed the diff between the live unit files and the committed
versions:

```diff
 [Unit]
 Description=NovaPay Payment API
 After=network.target postgresql.service
+StartLimitIntervalSec=60
+StartLimitBurst=5

 [Service]
+MemoryHigh=128M
+MemoryMax=192M
+OOMScoreAdjust=200
```

### Post-deploy: limits confirmed live via systemctl show

```
MemoryHigh=134217728    (= 128 MB)
MemoryMax=201326592     (= 192 MB)
OOMScoreAdjust=200
StartLimitBurst=5
StartLimitIntervalUSec=1min
```
Values are in bytes internally; the readable form confirms the unit file was read.

### Part 1 — Budget arithmetic (live process data)

```
USER     PID  %MEM    RSS COMMAND
postgres 672   2.9  27344 /usr/lib/postgresql/16/bin/postgres
postgres 762   1.0  10168 postgres: walwriter
ubuntu   855   0.9   9020 /opt/novapay/bin/payment-api
postgres 749   0.9   8756 postgres: checkpointer
postgres 763   0.9   8508 postgres: autovacuum launcher
postgres 764   0.8   7924 postgres: logical replication launcher
postgres 750   0.7   7164 postgres: background writer
ubuntu   520   0.4   4036 /opt/novapay/bin/fake-psp
```

payment-api idle RSS: 8.8 MB (up from 1.9 MB at Day 3 — audit log fd, SIGHUP
signal goroutine, and debug.go compiled in account for the increase).
fake-psp idle RSS: 3.9 MB (up from 1.1 MB at Day 3).
Postgres total RSS (all workers): ~75 MB.

### Part 4 — Balloon test under permanent config

**BEFORE:**
```
               total        used        free      shared  buff/cache   available
Mem:           911Mi       440Mi        76Mi        17Mi       584Mi       470Mi
Swap:             0B          0B          0B
```

**MemoryHigh throttle observed:**
`curl -m 30 'http://localhost:8080/debug/balloon?mb=400'` → `curl exit: 28`
RSS climbed slowly from 9 MB → 128 MB → stalled at MemoryHigh throttle.
MemoryCurrent progression over ~2 minutes: 162 MB → 169 → 174 → 177 → 181 → 187 MB.
Throttle visible as stalled page-fault loop, not as an error.

**OOM kill (dmesg):**
```
[15847.787299] payment-api invoked oom-killer: gfp_mask=0x100cca, order=0, oom_score_adj=200
[15847.787503] oom-kill:constraint=CONSTRAINT_MEMCG,
               oom_memcg=/system.slice/payment-api.service,
               task=payment-api,pid=13857,uid=1000
[15847.787540] Memory cgroup out of memory: Killed process 13857 (payment-api)
               total-vm:2287112kB, anon-rss:195584kB, file-rss:10188kB
```
`constraint=CONSTRAINT_MEMCG` — cgroup-scoped kill. `oom_score_adj=200` —
the committed value is visible in the kill record itself.
`anon-rss:195584kB` (~191 MB) — right at the MemoryMax=192M ceiling.

**systemd restart (journald):**
```
Jun 28 08:23:16 payment-api.service: A process of this unit has been killed by the OOM killer.
Jun 28 08:23:16 payment-api.service: Main process exited, code=killed, status=9/KILL
Jun 28 08:23:16 payment-api.service: Failed with result 'oom-kill'.
Jun 28 08:23:16 payment-api.service: Consumed 1.812s CPU time, 186.7M memory peak, 0B memory swap peak.
Jun 28 08:23:21 payment-api.service: Scheduled restart job, restart counter is at 1.
Jun 28 08:23:21 payment-api.service: Started payment-api.service - NovaPay Payment API.
Jun 28 08:23:21 payment-api[14363]: INFO database connected
Jun 28 08:23:21 payment-api[14363]: INFO payment-api starting port=8080
```
5-second gap (RestartSec=5s). New PID 14363.

**Postgres throughout:**
```
● postgresql.service
   Active: active (exited) since Sun 2026-06-28 03:59:20 UTC; 4h 51min ago
   Main PID: 853
```
Running continuously since boot. Absent from all OOM output.

**AFTER:**
```
               total        used        free      shared  buff/cache   available
Mem:           911Mi       426Mi       279Mi        17Mi       394Mi       484Mi
Swap:             0B          0B          0B
```
Available went 470 Mi → 484 Mi. Balloon pages returned to OS on cgroup teardown.

**Recovery charge:**
```
{"payment_id":"db29ee70-d828-4463-b1ec-e43c7366665e","status":"approved"}
```

**EC2 invariant:** 0 rows, 12 payments.

### Part 5 — Crash-loop guard

Transient `MemoryMax=20M` set via `set-property` for rapid-kill test.
Balloon fired every 2 seconds until burst limit triggered.

NRestarts progression: 1 (from Part 4) → 3 (Part 5 loop 1) → 10 (Part 5 loop 2).
`StartLimitBurst` counter (separate internal sliding-window counter) accumulated
5+ kills within a 60-second window during the tight loop.

**systemctl status output when burst limit fired:**
```
× payment-api.service - NovaPay Payment API
     Active: failed (Result: oom-kill) since Sun 2026-06-28 09:01:34 UTC
   Duration: 2.915s
    Process: 15306 ExecStart=/opt/novapay/bin/payment-api (code=killed, signal=KILL)
```

**journald at the burst limit:**
```
payment-api.service: Scheduled restart job, restart counter is at 10.
payment-api.service: Start request repeated too quickly.
payment-api.service: Failed with result 'oom-kill'.
Failed to start payment-api.service - NovaPay Payment API.
```
Service entered `failed` state. No further automatic restart. Operator must run
`systemctl reset-failed` to resume.

Post-revert confirmation:
```
MemoryMax=201326592   (192 MB — permanent config restored)
MemoryHigh=134217728  (128 MB)
OOMScoreAdjust=200
ActiveState=active
NRestarts=0
```
`/debug/balloon` → 404. `NOVAPAY_DEBUG` absent from unit and journald startup line.

---

## Acceptance criteria — all met ✓

- [x] Unit files in repo carry `MemoryMax`/`MemoryHigh`/`OOMScoreAdjust`/`StartLimit*` in correct sections; deployed via Ansible (dry-run gate first); `systemctl show` reflects values on EC2
- [x] `StartLimitIntervalSec` and `StartLimitBurst` in `[Unit]`, not `[Service]` — verified via `systemctl show -p StartLimitBurst,StartLimitIntervalUSec`
- [x] With caps baked in, Day 11 balloon produces contained cgroup OOM kill (`constraint=CONSTRAINT_MEMCG`) from committed config — not a transient `set-property`
- [x] `oom_score_adj=200` visible in dmesg kill record — proves value is read from committed unit file
- [x] Budget arithmetic recorded: `sum(MemoryMax) + Postgres + OS reserve = 493 MB`, headroom = 418 MB (46% of 911 MB)
- [x] Crash-loop guard: repeated OOM kills → systemd enters `failed` state, `"Start request repeated too quickly."` in journald, requires `reset-failed` to recover
- [x] `NOVAPAY_DEBUG` is OFF in deployed config (`/debug/balloon` → 404 on deployed service)
- [x] INC-007 closed via GitHub MCP (issue #6) with full resolution comment
- [x] ADR-011 committed
- [x] `/check` clean (build + vet + local invariant 0 rows)
- [x] `/ec2-invariant` 0 rows, 12 payments — ledger balanced throughout all testing

---

## Problems hit

**`StartLimitBurst` / `StartLimitIntervalSec` section placement.**
The user's Day 12 specification listed these under "add to [Service]". On systemd
v229+, placing them in `[Service]` is silently accepted but has no effect —
the crash-loop guard never fires. Caught during the pre-edit review before any
file was written. Both directives were placed in `[Unit]`. Lesson: systemd's
backwards-compatibility shim for these directives masks the error silently;
always verify with `systemctl show -p StartLimitBurst` after deploy.

**Crash-loop guard did not fire at NRestarts=5 as intuitively expected.**
With MemoryMax=20M and balloon at mb=15, the NRestarts counter reached 9 before
the burst limit fired. Root cause: `NRestarts` is a cumulative lifetime counter,
not the sliding-window counter that `StartLimitBurst` tracks. The 60-second window
counter started fresh at each new window; the burst limit fired when 5+ activations
accumulated within a single window during the tight-loop phase. `NRestarts=10` at
failure reflects the whole session, not just Part 5. Lesson: do not confuse
`NRestarts` with the StartLimit activation counter — they are separate mechanisms.

**MemoryMax not breached during initial balloon calls (multiple timeouts).**
With MemoryMax=192M and MemoryHigh=128M, the 64 MB gap between the two is
traversed extremely slowly under heavy kernel reclaim throttle. Three successive
balloon calls (`mb=400`, `mb=50`, `mb=30`) all timed out without producing an
OOM kill — the process stalled at ~162–187 MB for several minutes while the
goroutines inched through page faults under throttle. The OOM kill eventually
occurred naturally as the accumulated goroutines from all calls slowly pushed
past MemoryMax. Lesson: `MemoryHigh` throttle can be severe enough that a balloon
aimed at far above `MemoryMax` never completes within any reasonable HTTP timeout —
the kill comes from accumulated goroutines, not from a single call completing.

---

## Commands worth keeping

```bash
# --- Permanent memory limits (unit file approach, IaC) ---

# Verify committed limits are live after deploy (not overridden by transient set-property)
systemctl show payment-api -p MemoryMax,MemoryHigh,OOMScoreAdjust

# Confirm StartLimit directives are active (will return values only if in [Unit])
systemctl show payment-api -p StartLimitBurst,StartLimitIntervalUSec

# View full cgroup memory accounting including current RSS and peak
systemctl status payment-api --no-pager
# Look for: Memory: X.XM (high: 128.0M max: 192.0M available: NM peak: X.XM)

# --- Transient overrides (for testing only — always revert after) ---

# Set a transient MemoryMax for rapid-kill testing
sudo systemctl set-property payment-api.service MemoryMax=20M

# Revert all transient set-property overrides (restores committed unit file values)
sudo systemctl revert payment-api.service

# After revert, verify permanent values are restored
systemctl show payment-api -p MemoryMax,MemoryHigh

# --- Crash-loop recovery ---

# Clear failed state after burst limit fires (requires operator intervention)
sudo systemctl reset-failed payment-api.service
sudo systemctl start payment-api.service

# --- OOM kill forensics ---

# Confirm a kill was cgroup-scoped (CONSTRAINT_MEMCG) not system-wide (CONSTRAINT_NONE)
sudo dmesg | grep -i -E '(oom|constraint|out of memory|killed process)' | tail -20

# Check OOM score adjustment for a live process (verify it matches unit file)
cat /proc/$(pgrep payment-api)/oom_score_adj

# Box-wide memory snapshot — capture before/during/after any memory experiment
free -h

# --- Ansible verification ---

# Verify live EC2 unit file matches committed version (show the runtime value, not file)
ansible novapay -i infrastructure/ansible/inventory.ini -m shell \
  -a "systemctl show payment-api -p MemoryMax,MemoryHigh,OOMScoreAdjust,StartLimitBurst"
```

---

## Agentic workflow addition

**Precise counter disambiguation documented in day notes:**
The distinction between `NRestarts` (cumulative) and the `StartLimitBurst`
sliding-window counter was caught and documented precisely because the user asked
for the exact scenario before writing up the day note. The day note now states
definitively: cumulative across the session, not fresh within Part 5. This
pattern — "verify the claim before writing the permanent record" — is worth
carrying forward for all Day N notes where observed numbers could be misleading.

**Section-placement correctness check before any edit:**
The `[Unit]` vs `[Service]` placement catch for `StartLimitBurst`/`StartLimitIntervalSec`
happened because the unit files were read before writing. Reading the target file
before editing (not after) is the agentic workflow habit that caught this — the
diff was shown to the user before the edit was made, and the correction was
explained inline.

**INC-007 lifecycle (GitHub MCP):**
Issue #6 opened on 2026-06-26 before Day 11's balloon code was written.
Closed on 2026-06-28 (Day 12) with a full resolution comment documenting:
permanent limits, balloon re-test results, crash-loop guard evidence, teardown
verification, EC2 invariant. The comment is the permanent forensic record on GitHub.

**Pre-deploy journal verification added as habit:**
Before any deploy, `journald SystemMaxUse` was verified against both the
committed repo file and the live EC2 file via Ansible ad-hoc. They agreed (200M
each); the discrepancy with the week plan's original 100M estimate was documented.
This is the right pre-deploy check pattern: don't trust checkpoint.md, verify
the actual files.

---

## LinkedIn article notes

- **Hook:** "I set `oom_score_adj=200` on my payment service so the kernel kills it
  before Postgres — here's the exact dmesg line that proves it worked."
- **Strong numbers:**
  - `constraint=CONSTRAINT_MEMCG` vs `constraint=CONSTRAINT_NONE` — one token in
    dmesg that separates "your app died" from "your database died"
  - `oom_score_adj=200` visible in the dmesg kill record itself — proves the
    value was read from the committed unit file, not asserted
  - `anon-rss:195584kB` (~191 MB) — right at the 192M ceiling, demonstrating
    the cgroup killed at exactly the right threshold
  - free -h after kill: available went 470 Mi → 484 Mi — the pages were returned
    to the OS; box never stressed
  - NRestarts=10 when crash-loop guard fired — and why 10 ≠ 5, the honest
    explanation of what the counter actually measures
  - `StartLimitIntervalSec` silently ignored in `[Service]` on systemd 255 —
    the kind of silent failure that makes production incidents hard to diagnose
- **What NOT to make it about:** Kubernetes resource limits (too obvious), generic
  "always set memory limits" advice (too shallow), the balloon endpoint as a
  feature (it's scaffolding, not product)
- **What resonates for senior engineers:** the `[Unit]` vs `[Service]` placement
  trap — it passes `systemd-analyze verify` silently, so you'd deploy it, think
  you have a crash-loop guard, and discover you don't only when the loop runs.
  And the NRestarts/StartLimit counter distinction — both numbers appear in
  `systemctl show` and look related; they are not.

---

## Handoff to Day 13

**Status:** Day 12 complete ✓ · deployed `ad94642`, ADR-011 `c9cd817`

Day 13 is the integration day: prove all Week 2 defences hold **together** and
are reproducible from IaC via a clean redeploy, then run the full 5-stage gauntlet
(`scripts/gauntlet-week02.sh`), and draft the LinkedIn deep-dive. It mirrors
Week 1's Day 7 but with the publish explicitly split to Day 14 to avoid the
Week 1 carryover failure.

**Day 13 starts with:**
1. `/check` — build + vet + local invariant 0 rows (gate before anything else)
2. Confirm all Week 2 defences are present on EC2 from the committed repo:
   audit logging, logrotate config, journald cap (200M), memory limits + OOMScoreAdjust
3. Write `scripts/gauntlet-week02.sh` with 5 independently-reported stages,
   each emitting its own `PASS`/`FAIL` line with captured state
4. Run the gauntlet end-to-end; verify all 5 stages pass, root untouched throughout
5. Capture Week 2 EC2 baseline (RSS, MemoryMax/High, disk usage, journald usage)
6. Draft the LinkedIn article "Designing a payments box that can't fill its own disk"
   with real captured output; save to `notes/`
7. `/generate-questions 13` (Go file I/O + signals, loop devices + ext4, cgroup v2 +
   systemd memory accounting, logrotate, OOM killer)
