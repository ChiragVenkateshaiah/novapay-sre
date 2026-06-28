# Week 2 Plan — Filesystems, Disk, Memory

> Phase 1 · Week 2 · Days 8–14 · build-first, discipline-neutral.
> **Terraform is NOT in Week 2.** The full Terraform introduction stays deferred to
> Phase 4 as originally scoped in checkpoint.md. No light-touch version this week.
> **ADR-008 is reserved** for the future Terraform boundary decision (Phase 4) and is
> not created now; this week's three ADRs are **009, 010, 011**.

## Context
Week 1 built a correct payments core and hardened it at the *process* boundary
(retries, goroutine lifecycle, timeouts). Week 2 moves down a layer to the
*operating system* boundary: the filesystem, the disk, and memory. The system
must keep taking payments and keep the ledger balanced even when its log disk
fills or a process tries to eat all of RAM — and it must do so on a real
**t3.micro** with hard limits, verified against the live box:

- **Disk:** single `/dev/root`, 6.8G total, **2.8G free**, *no separate log partition*. `/var/log/novapay` already exists (created by `provision.yml`, owned by `ubuntu`).
- **Memory:** 911MB total, **zero swap**, ~489MB available, 2 vCPU. cgroup **v2** (`cgroup2fs`), systemd **255** → `MemoryMax`/`MemoryHigh` accounting is reliable.
- **Logging today:** `payment-api` logs via slog's default handler to journald (operational). The receipt worker writes `/tmp/novapay-receipts.txt`. **No `/var/log/novapay/transactions.log` exists yet** — Day 8 builds it.
- **logrotate 3.21** present; journald has **no `SystemMaxUse` cap** set.
- Postgres runs **on the same box** and holds the ledger → every safety design must prove Postgres survives.

Both incidents are **bounded, reversible, and structurally incapable of harming
the root volume or Postgres** — the safety is built into the mechanism, not into
arithmetic.

---

## Week goal
Build a durable, structured transaction (audit) log; then harden the box so that
(1) no volume of charges can fill the disk, and (2) no process can OOM-kill the
box or take Postgres down with it. Two incidents (INC-006 disk-fill, INC-007 OOM),
each observed safely and then defended, every defence reproducible as IaC.
**Publish angle:** "Designing a payments box that can't fill its own disk."

---

## Day 8 — Structured transaction (audit) logging
### Goal
Add a durable, structured, per-charge transaction log to `payment-api`, written
as one JSON object per line to `/var/log/novapay/transactions.log` — a dedicated
**audit** stream, separate from journald **operational** logs. The audit write
must be **resilient**: a log-write failure must never fail a charge or break the
invariant. This is the substrate Day 9 will stress.

### Build
- Add a second, dedicated `*slog.Logger` using `slog.NewJSONHandler` writing to an
  `*os.File` opened on the audit path (`O_APPEND|O_CREATE|O_WRONLY`, `0644`).
  Path from env `TRANSACTION_LOG_PATH` (default `/var/log/novapay/transactions.log`;
  dev/WSL2 fallback to a repo-local path).
- After `tx.Commit(ctx)` in `handleCharge`, write exactly one JSON line, fixed schema:
  `ts` (RFC3339), `event` (`"charge"`), `payment_id`, `idempotency_key`,
  `amount_minor`, `currency`, `customer_id`, `psp_status`, `psp_ref`, `latency_ms`.
- Idempotent replays also write one audit line with `event="charge_idempotent"`
  (records the replay; no money moved) so the audit trail is complete.
- **Resilience (ADR-005 spirit):** the audit write is synchronous on the charge
  path but error-swallowing — on open/write failure, emit an operational `ERROR`
  to journald and continue; the charge still returns 200 and the ledger still
  commits. The audit line may be lost; the money is never wrong.

### Acceptance criteria
1. `go build ./...` + `go vet` clean; invariant query returns **0 rows** after a test charge.
2. One test charge appends **exactly one** line; valid JSON: `tail -1 transactions.log | jq -e '.payment_id and .amount_minor and .psp_status and .ts'` exits 0.
3. 10 charges → exactly 10 lines (`wc -l`); line count == `SELECT count(*) FROM payments`.
4. Idempotent replay (same key twice) → DB still one payment; audit log shows one `charge` + one `charge_idempotent`; invariant 0 rows.
5. **Write-resilience:** point `TRANSACTION_LOG_PATH` at an unwritable path (missing dir / `chmod 000`) → charge returns 200, ledger commits, invariant 0 rows, operational `ERROR` logged. Proves the audit write never breaks a charge.
6. Deployed to EC2 via Ansible (dry-run gate first); a charge on EC2 appends to `/var/log/novapay/transactions.log`; `/ec2-invariant` 0 rows.

### ADR
**ADR-009 — Transaction/audit log as a dedicated, resilient file stream.**
Decisions: separate durable file (not journald-only); resilient write (never fails
a charge); line-buffered append, **no per-write fsync this week** (DB + journald are
the durable backstop). Rejected: journald-only (not a durable, queryable audit
trail; journald vacuums/rotates); DB audit table (couples audit growth to the
ledger DB — and this week is about the *filesystem*); per-write fsync (charge-path
latency cost, deferred).

### Workflow addition
`/tail-tx` (and `/ec2-tx`): tail + `jq`-pretty the last N audit lines locally and on
EC2. CLAUDE.md: add the audit-log path convention + "audit write must never fail a charge".

---

## Day 9 — Disk-fill incident: observe the break (INC-006)
### Goal
Safely demonstrate what `payment-api` does when the filesystem holding its
transaction log fills (ENOSPC) — **without ever threatening the root volume or
Postgres**, given only 2.8G free on a single volume.

### Break — safety design (structural bound, not arithmetic)
Never fill `/`. Host the audit log on a **bounded loopback filesystem** for the test:
```bash
# 64MB backing file (tiny vs 2.8G free) — the fill is physically capped at 64MB
fallocate -l 64M /opt/novapay/disktest.img
mkfs.ext4 -q /opt/novapay/disktest.img
sudo mkdir -p /mnt/novapay-logtest
sudo mount -o loop /opt/novapay/disktest.img /mnt/novapay-logtest
sudo chown ubuntu:ubuntu /mnt/novapay-logtest
# point payment-api at it for the test: TRANSACTION_LOG_PATH=/mnt/novapay-logtest/transactions.log
df -h /                         # capture root BEFORE  (~2.8G free)
dd if=/dev/zero of=/mnt/novapay-logtest/filler bs=1M count=60   # fill the LOOP fs, not root
df -h /                         # root UNCHANGED — proven, not assumed
df -h /mnt/novapay-logtest      # 100% / ENOSPC
```
Then fire charges and observe: each charge **still returns 200**, ledger commits,
invariant 0 rows, but `journalctl -u payment-api` shows
`transaction log write failed: ... no space left on device` per charge. The audit
line is lost; the money is correct. **The lesson: a payments box must keep taking
payments when its log disk is full — but it must surface that it is losing audit data.**

### Reversible teardown (runbook)
```bash
sudo umount /mnt/novapay-logtest
rm -f /opt/novapay/disktest.img
sudo rmdir /mnt/novapay-logtest
# restore TRANSACTION_LOG_PATH default, restart payment-api
df -h /                         # root reclaimed/untouched
```

### Acceptance criteria
1. Loop fs capped at 64M; `df -h /` shows root free space **unchanged** before/during/after (captured in the day note as the root-safety proof).
2. During fill: `df -h /mnt/novapay-logtest` = 100%/ENOSPC; charges still 200; `count(*)` increments; invariant 0 rows.
3. `journalctl -u payment-api` shows the ENOSPC write error per charge during the full window.
4. INC-006 GitHub issue opened (GitHub MCP) **before** any fix: trigger, observed behavior, blast-radius bound (loop fs), the gap = *silent audit loss*.
5. Clean teardown verified: unmounted, backing file removed, root reclaimed, services healthy, invariant 0 rows.

### Workflow addition
`/ec2-disk`: `df -h /` + `du -sh /var/log/novapay/*` + `journalctl --disk-usage`.
`scripts/disk-fill-demo.sh`: the bounded loop-fs runbook with a **structural guard —
refuses to run if free space on `/` < 1G**, so it can never be pointed at root.

---

## Day 10 — Disk-fill defence: rotation + retention (close INC-006)
### Goal
Bound audit-log disk use so no charge volume can fill the disk, managed as IaC
(Ansible), **without losing audit lines during rotation**.

### Harden
- **logrotate** config deployed via Ansible to `/etc/logrotate.d/novapay`:
  `size 50M`, `rotate 7`, `compress`, `delaycompress`, `missingok`, `notifempty`.
- **SIGHUP-reopen over `copytruncate`.** The Go process holds the file open with
  `O_APPEND`; `copytruncate` risks losing lines written during the copy. Instead:
  logrotate uses `create` + `postrotate` → `systemctl kill -s HUP payment-api`;
  `payment-api`'s existing signal goroutine gains a `SIGHUP` case that **reopens**
  the audit file. Audit integrity (no lost lines) beats `copytruncate` simplicity.
- **Cap journald** too (the *other* disk-fill vector): `SystemMaxUse=200M` via an
  Ansible-managed `journald.conf` drop-in (currently uncapped → defaults to ~10% disk).
  *(Originally estimated at 100M; 200M was the value actually implemented and deployed in ADR-010 — plan updated to match reality.)*
- **Worst-case ceiling math:** active 50M + 7 compressed rotations ≪ 500M ≪ 2.8G free — recorded in ADR-010.
- Make it **IaC**: logrotate config + journald drop-in added to Ansible (new `logging` tasks), so the defence is reproducible, not a hand-edit.

### Acceptance criteria
1. `/etc/logrotate.d/novapay` deployed via Ansible; `logrotate -d /etc/logrotate.d/novapay` parses clean and shows the size-trigger.
2. Force rotation (`sudo logrotate -f`): active log rotated, fresh active log created, `payment-api` reopens on SIGHUP and the **next charge lands in the new file** — and `lines_before_rotation + lines_after == count(*)` (no audit line lost across rotation).
3. Disk ceiling computed and recorded in ADR-010 (< 500M ≪ 2.8G).
4. journald capped: `journalctl --disk-usage` respects `SystemMaxUse=200M` after `systemctl restart systemd-journald`.
5. Re-run Day 9's bounded loop-fs fill **with rotation enabled** → active log bounded, charges 200, invariant 0 rows, growth no longer unbounded.
6. INC-006 closed (GitHub MCP) referencing the fix commit; ADR-010 committed.
7. `/check` clean; deployed via Ansible (dry-run gate first); `/ec2-invariant` 0 rows.

### ADR
**ADR-010 — Log rotation + retention policy.** Decisions: size-based rotation
(50M), retention 7, compression, **SIGHUP-reopen (not copytruncate)** for audit
integrity, journald `SystemMaxUse` cap. Rejected: `copytruncate` (audit-line race),
time-based rotation (risk correlates with charge volume, not time), app-native
rotation (reinventing logrotate), uncapped journald (second fill vector).

### Workflow addition
`/rotate-check`: `logrotate -d` + list retained/compressed files + ceiling math.
CLAUDE.md: rotation policy + SIGHUP semantics.

---

## Day 11 — OOM incident: observe the break (INC-007)
### Goal
Safely demonstrate memory pressure and the OOM killer on a 911MB / **zero-swap**
box shared with Postgres, using **cgroup-v2 containment** so the blast radius is
**provably bounded to `payment-api`'s own cgroup**. Postgres must be untouched.

### Build — the balloon (env-gated; design already decided)
- Add to `payment-api` a debug allocation path active **only when `NOVAPAY_DEBUG=1`**:
  a `/debug/balloon?mb=N` handler that allocates N MB of **resident** memory (append
  to a package-level `[][]byte` and **touch every page** so RSS actually grows —
  Go won't fault in untouched zeroed pages). Mirrors fake-psp's `PSP_HANG` knob.
  Never registered when `NOVAPAY_DEBUG` is unset. Removable after the week.

### Break — safety design (structural bound: cgroup cap set FIRST)
With Postgres co-resident and no swap, ballooning **without** a cap could invoke the
kernel's system-wide OOM killer and pick Postgres. So the cap goes on **first**:
```bash
sudo systemctl set-property payment-api.service MemoryMax=128M MemoryHigh=96M   # transient, reversible
systemctl show payment-api -p MemoryMax -p MemoryHigh -p MemoryCurrent
free -h                                   # capture box BEFORE
# NOVAPAY_DEBUG=1 on the service for the test:
curl 'localhost:8080/debug/balloon?mb=400'
journalctl -u payment-api -n 50           # cgroup OOM kill of payment-api + systemd restart
systemctl status postgresql               # ACTIVE throughout — blast radius contained
free -h                                   # box never hit system-wide OOM
```
- `MemoryHigh=96M` → throttle/reclaim (visible stall) before `MemoryMax=128M` → **cgroup OOM kill scoped to payment-api only**; systemd restarts it (`Restart=on-failure`).
- The bound is **structural**: 128M ≪ 911MB, so even ballooning to 400M only ever kills payment-api's cgroup. **Rule: never balloon without the cgroup cap in place.**
- **Counterfactual (reasoned, NOT executed):** with no cap, ballooning toward 911MB with zero swap invokes the kernel OOM killer, which could kill Postgres — catastrophic for the ledger. We do not run it; the contained version proves the defence.

### Reversible teardown
```bash
sudo systemctl revert payment-api.service     # drop the transient set-property
# restart with NOVAPAY_DEBUG unset → balloon endpoint gone
systemctl show payment-api -p MemoryMax       # cleared
```

### Acceptance criteria
1. Balloon endpoint exists **only** under `NOVAPAY_DEBUG=1` (without it → `/debug/balloon` 404).
2. With `MemoryMax=128M`: `/debug/balloon?mb=400` → contained cgroup OOM kill of payment-api + automatic restart within `RestartSec`; shown in `journalctl -u payment-api`.
3. **Blast-radius proof** recorded: `systemctl status postgresql` active before/during/after; a charge succeeds after restart; invariant 0 rows; `free -h` shows no system-wide OOM (before/during/after captured).
4. `MemoryHigh` throttle observed as distinct from the `MemoryMax` kill (MemoryCurrent approaches MemoryHigh with reclaim before the kill).
5. INC-007 opened (GitHub MCP) **before** the defence is finalized: trigger, contained-kill behavior, the design choice that made it safe (cap first).
6. Teardown verified: limits reverted, debug off, services healthy, invariant 0 rows.

### Workflow addition
`/ec2-mem`: `systemctl show payment-api -p MemoryCurrent,MemoryMax,MemoryHigh` + `free -h` + top RSS.
`scripts/oom-demo.sh`: runbook with structural guard — **refuses to run unless a MemoryMax is set** on the unit.

---

## Day 12 — OOM defence: systemd memory limits (close INC-007)
### Goal
Make memory bounds **permanent IaC** in the unit files so both services degrade
predictably under pressure — contained, restarted, never taking the box or Postgres
with them.

### Harden
- Bake into `payment-api.service` and `fake-psp.service` (repo `infrastructure/systemd/`, deployed via Ansible):
  - `MemoryHigh` (soft: throttle+reclaim) + `MemoryMax` (hard: OOM-kill backstop).
    Values from observed baseline (D3: payment-api 1.9MB, fake-psp 1.1MB RSS) with
    generous headroom: **payment-api `MemoryHigh=128M` / `MemoryMax=192M`**;
    **fake-psp `MemoryHigh=64M` / `MemoryMax=96M`**.
  - `OOMScoreAdjust=+200` on both app services so that under any system-wide pressure
    the **app dies before Postgres** (the ledger is the source of truth and must survive).
  - Crash-loop guard: `StartLimitBurst=5` / `StartLimitIntervalSec=60` so repeated
    OOM-restarts back off into a visible failed state instead of silent thrash.
- **Budget arithmetic:** sum of all `MemoryMax` + a Postgres reserve must be < 911MB
  with margin — verify the caps themselves can't collectively starve the box.
- Deploy via Ansible (unit files already copied by `deploy.yml`; daemon-reload +
  restart already present). Re-run the Day 11 balloon under the **permanent** caps
  to prove the baked-in `MemoryMax` contains it exactly as the transient one did.

### Acceptance criteria
1. Unit files in repo carry `MemoryMax`/`MemoryHigh`/`OOMScoreAdjust`/`StartLimit*`; deployed via Ansible (dry-run gate first); `systemctl show payment-api -p MemoryMax,MemoryHigh,OOMScoreAdjust` reflects them on EC2.
2. With caps **baked in**, the Day 11 balloon produces a contained cgroup OOM kill + restart — verified from committed config, not a transient `set-property`.
3. Budget arithmetic recorded: `sum(MemoryMax) + Postgres reserve < 911MB` with margin.
4. Crash-loop guard: repeated OOM (balloon each start) → systemd enters failed/backoff after `StartLimitBurst`, visible in `systemctl status` (not infinite restart).
5. `NOVAPAY_DEBUG` is **OFF** in deployed config (`/debug/balloon` → 404 on the deployed service).
6. INC-007 closed (GitHub MCP) referencing the fix commit; ADR-011 committed.
7. `/check` clean; `/ec2-invariant` 0 rows; both services active with caps.

### ADR
**ADR-011 — systemd memory-limit strategy.** Decisions: `MemoryHigh` (soft throttle)
+ `MemoryMax` (hard kill) per service, values = baseline × headroom; `OOMScoreAdjust`
ordering so the app dies before Postgres; `StartLimit*` crash-loop backoff. Rejected:
`MemoryMax`-only (no graceful throttle stage), one global slice limit (less precise),
relying on kernel OOM (scores by badness — could pick Postgres; unacceptable for the
ledger), no limits (the original state → INC-007).

### Workflow addition
CLAUDE.md: memory-limit policy + "`NOVAPAY_DEBUG` is demo-only, never in deployed env".

---

## Day 13 — Integration · full gauntlet · deep-dive draft
### Goal
Prove all Week 2 defences hold **together** and are reproducible from IaC; run the
full correctness+resilience gauntlet; draft the LinkedIn deep-dive. (Mirrors Week 1
Day 7, but publish is split to Day 14 so the article doesn't slip — Week 1's
recorded carryover failure.)

### Activities
- **Clean-slate reproducibility:** redeploy from the committed repo via Ansible and
  confirm every Week 2 defence is present with no hand-tweaks: audit logging,
  logrotate config, journald cap, memory limits + `OOMScoreAdjust` on both units.
- **Full gauntlet** (`scripts/gauntlet-week02.sh`): **five distinct, independently-reported stages**, each printing its own `PASS`/`FAIL` line with the relevant captured state at that point, so a partial failure pinpoints exactly which stage broke and what the system looked like:
  1. **Load test** — fire load under `PSP_ERROR_RATE=0.5`; capture the **invariant query result**; PASS iff 0 rows.
  2. **Audit reconciliation** — capture **audit-log line count** vs `SELECT count(*) FROM payments`; PASS iff equal.
  3. **Forced rotation** — `logrotate -f`, fire a charge; capture **active vs rotated filenames + before/after line counts**; PASS iff next line lands in the new file and no audit line lost.
  4. **Disk-fill** — bounded loop-fs fill; capture **`df -h /` (root) + `df -h /mnt/novapay-logtest` + a sample charge HTTP status**; PASS iff root unchanged, charges 200, invariant 0 rows.
  5. **Balloon / OOM** — balloon under caps; capture **`journalctl -u payment-api` kill line + `systemctl status postgresql` + post-recovery invariant**; PASS iff contained kill + restart, Postgres active, invariant 0 rows.
  Script ends with a per-stage summary table **and** an overall result; `df` safety asserts run inside before any fill stage.
- **Week 2 EC2 baseline** recorded (like the D3 baseline): RSS, `MemoryMax/High`,
  `/var/log/novapay` disk usage, journald usage, audit-log line rate.
- **Draft the article** "Designing a payments box that can't fill its own disk" with
  real captured output (df before/during/after, journald OOM lines, `free -h`); save to `notes/`.
- `/generate-questions 13` (Go file I/O & signals, loop devices & ext4, cgroup v2 & systemd memory accounting, logrotate, OOM killer).

### Acceptance criteria
1. Clean redeploy reproduces all defences (checklist verified on EC2).
2. **`scripts/gauntlet-week02.sh` reports pass/fail per stage with captured state, not only an overall result** — each of the five stages emits its own `PASS`/`FAIL` + the relevant captured output (invariant result, line counts, `df`, `systemctl status`) at the moment of that stage.
3. Gauntlet runs end-to-end; every stage passes; final invariant 0 rows; **root untouched throughout** (asserts inside the script).
4. Week 2 EC2 baseline captured (in the day note + checkpoint draft).
5. Article drafted in `notes/` with real output (no placeholders).
6. `/generate-questions` output saved.

### Workflow addition
`/gauntlet`: wraps the week-02 gauntlet script as a reusable resilience regression.

---

## Day 14 — Publish · checkpoint · Week 3 handoff
### Goal
Ship the article (fixing Week 1's carryover), finalize ADRs/CLAUDE.md, update
checkpoint.md, write the Week 3 handoff. A dedicated publish/admin day so the
deep-dive actually goes out.

### Activities
- Publish the LinkedIn article (or mark published) + short teaser — reuse Week 1's article+teaser file pattern in `notes/`.
- Confirm **ADR-009/010/011** committed; CLAUDE.md architectural-constraints section updated with the three new constraints (audit-log resilience; rotation/SIGHUP; memory limits + `OOMScoreAdjust` ordering).
- Confirm all Week 2 workflow additions committed: `/tail-tx`(+`/ec2-tx`), `/ec2-disk`, `/rotate-check`, `/ec2-mem`, `/gauntlet`, and `scripts/{disk-fill-demo,oom-demo,gauntlet-week02}.sh`; agentic workflow log updated per day.
- Update checkpoint.md: Week 2 complete, Built section, new baseline, INC-006/007 logged, ADRs 009–011, Week 2→3 handoff. **(Proposed to user for review first.)**
- End-of-day ritual + stop EC2.

### Acceptance criteria
1. Article published (or staged + marked) + teaser saved; **no carryover publish item**.
2. ADR-009/010/011 committed; CLAUDE.md constraints updated; `ls docs/decisions/` shows **10 ADR files** (001–007, 009–011; **008 reserved** for the Phase-4 Terraform decision, not yet created).
3. All new commands/scripts committed and listed in CLAUDE.md.
4. checkpoint.md Week 2 section complete (after user review); Week 3 handoff written.
5. Final `/check` clean; `/ec2-invariant` 0 rows; EC2 stopped.

---

## New ADRs this week
- **ADR-009 — Transaction/audit log as a dedicated, resilient file stream** (Day 8).
- **ADR-010 — Log rotation + retention policy** (size-based, SIGHUP-reopen, journald cap) (Day 10).
- **ADR-011 — systemd memory-limit strategy** (MemoryHigh+MemoryMax, OOMScoreAdjust ordering, crash-loop backoff) (Day 12).
- **ADR-008 — RESERVED** for the Terraform boundary decision in **Phase 4**. Not created this week.

## New agentic workflow additions this week
- **Commands:** `/tail-tx` (+`/ec2-tx`) audit-log tail+jq · `/ec2-disk` df+du+journald usage · `/rotate-check` logrotate -d + ceiling · `/ec2-mem` memory accounting · `/gauntlet` week-02 resilience regression.
- **Runbook scripts with structural safety guards:** `scripts/disk-fill-demo.sh` (refuses if `/` free < 1G; bounded loop fs) · `scripts/oom-demo.sh` (refuses unless MemoryMax set) · `scripts/gauntlet-week02.sh` (per-stage reporting + df asserts).
- **MCP:** GitHub MCP for the INC-006/INC-007 issue lifecycle (continue Week 1 pattern); Postgres MCP for invariant/count reconciliation in acceptance checks.
- **CLAUDE.md:** three new architectural constraints (009–011) + audit-log path convention + `NOVAPAY_DEBUG` demo-only rule + new commands listed.
- Per-day "what did the workflow gain today?" continues.

## Week 2 → Week 3 handoff
- **Carried forward:** durable resilient audit log; disk-fill defence (rotation + SIGHUP-reopen + journald cap, IaC); OOM defence (MemoryHigh/Max + OOMScoreAdjust + crash-loop backoff, IaC); Week 2 EC2 baseline; INC-006/007 closed; ADR-009/010/011.
- **Carried affordances:** `NOVAPAY_DEBUG` balloon (demo-only; decide whether to keep or strip); `scripts/{disk-fill-demo,oom-demo,gauntlet-week02}.sh`.
- **Still deferred (unchanged):** Terraform → Phase 4 (ADR-008 reserved); RDS + deep concurrency (isolation/row-locking) → Week 7.
- **Open for next planning session:** Week 3 topic is not yet defined in checkpoint.md — the next Opus session sets it (build-first, discipline-neutral). Reminder: discipline decision still at the Week-20 checkpoint.

---

## Verification (how the executing model proves each day)
- **Correctness gate every day:** `/check` (build + vet + invariant) and `/ec2-invariant` (0 rows) — the invariant is the non-negotiable backstop through every incident.
- **Incident days:** GitHub issue opened *before* the fix and closed *after* the commit (INC-006, INC-007); blast-radius proof (df / `free -h` / `systemctl status postgresql`) captured before-during-after in the day note.
- **Deploy discipline unchanged:** `/check` → `/deploy-dry-run` → human runs Ansible → `/ec2-invariant`; PreToolUse hook still blocks autonomous `ansible-playbook`.
- **End state:** `scripts/gauntlet-week02.sh` green (all five stages), root volume untouched, Postgres healthy, invariant 0 rows, article shipped.
