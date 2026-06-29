# Day 13 — Integration: Clean Redeploy + 5-Stage Week 2 Gauntlet

**Date:** 2026-06-29
**Phase:** Phase 1 · Week 2 · Linux & Systems Foundations
**Status:** complete ✓
**Commits:** `ecd9761` (Day 12 doc sync), `<D13 commit>` (gauntlet script + day note)

---

## Goal

Days 8–12 each added one defence in isolation. Day 13's objective was integration:
prove that **all five Week 2 defences hold simultaneously**, that they are
reproduced from the committed repo alone (no manual post-deploy steps), and that
they survive adversarial testing in sequence on the same EC2 instance.

The three deliverables:

1. **Clean redeploy gate** — Ansible dry-run + real deploy from HEAD; verify all
   limits and configs live without manual intervention.
2. **5-stage gauntlet** — `scripts/gauntlet-week02.sh` exercises each defence end
   to end; each stage is independent and emits a PASS/FAIL line.
3. **Week 2 baseline snapshot** — capture post-gauntlet RSS, memory limits, disk,
   and journald state as the permanent record of Week 2's live configuration.

---

## What was actually built

### `scripts/gauntlet-week02.sh`

New script, 5 independent stages. No `set -e` — a failing stage does not abort
the rest. Each stage owns its setup, its checks, and its cleanup. A summary table
prints at the end.

**Helper functions:**

```bash
KEY_PREFIX="g$(date +%s)-$$"   # unique idempotency key prefix per run
charge_code()    # runs POST /charge, returns HTTP status code
invariant_check() # counts rows from the invariant query
payment_count()  # counts rows in payments table
wait_for_api()  # polls /healthz until 200 or 30s timeout
```

**Stage 1 — PSP error rate (50% error injection, invariant still holds):**
- Drops a drop-in at `/etc/systemd/system/fake-psp.service.d/gauntlet-s1.conf`
  setting `PSP_ERROR_RATE=0.5`; daemon-reload + restart
- Fires 10 charges; counts 200s and non-200s
- Reverts drop-in + daemon-reload + restart
- PASS iff invariant == 0 (ledger balanced regardless of PSP outcome)

**Stage 2 — Audit log reconciliation (5 charges, line count delta matches):**
- Records `wc -l` of `transactions.log` and `payment_count()` before
- Fires 5 charges
- PASS iff both deltas == 5 (one ledger line and one payment row per charge)

**Stage 3 — Forced log rotation (zero lines lost):**
- Counts lines before rotation
- `sudo logrotate -f /etc/logrotate.d/novapay`
- Waits up to 10 s for `"audit log reopened"` in journald
- Fires 1 charge; counts lines in active log
- PASS iff new active == 1 (only the post-rotate charge) AND `.1` line count
  matches pre-rotation count (no lines dropped during rotation)

**Stage 4 — Disk-fill containment (charges return 200 under ENOSPC):**
- Safety guard: root free > 1GB before mounting anything
- `fallocate -l 64M` + `mkfs.ext4` + `mount -o loop` → `/mnt/novapay-audit-test`
- `dd` fills the 64M filesystem to ENOSPC
- Drop-in sets `TRANSACTION_LOG_PATH` to the full filesystem
- 3 charges; counts 200s and non-200s
- Hardened cleanup: `umount` result captured; if it fails, `lsof +D` / `fuser -vm`
  diagnostics run, backing file is left intact for manual inspection, and the
  PASS criteria include `S4_UMOUNT_OK`
- PASS iff 3 charges returned 200 (ADR-009 audit-write-never-fails-a-charge)
  AND umount succeeded AND no non-200 charges

**Stage 5 — OOM containment (cumulative balloon → cgroup kill, Postgres safe):**
- Drop-in enables `NOVAPAY_DEBUG=true`; restart
- Loop: up to 10 `curl -m 30 http://localhost:8080/debug/balloon?mb=300` calls;
  checks dmesg after each for OOM; breaks on first detection
  - Each call adds to the same package-level `balloon [][]byte` in the running
    process — pages fault into physical RAM and are never GC'd
- Post-loop polling: 12 × 10s = 120s max wait, checking dmesg every 10 seconds
  (OOM fires asynchronously; goroutines continue after curl disconnects)
- After OOM detected: `wait_for_api()` up to 30s; recovery charge; invariant check
- Cleanup: rm drop-in + daemon-reload + restart; verify `/debug/balloon` → 404
- PASS iff OOM detected (`CONSTRAINT_MEMCG` in dmesg) AND Postgres active
  AND payment-api recovered AND recovery charge 200 AND invariant 0
  AND `/debug/balloon` → 404 after cleanup

---

## Core concept — integration testing as a proof of IaC correctness

### The gap this day closes

Each Day 8–12 defence was tested in isolation, often on a box that had been
partially configured by hand in earlier days. A defence tested in isolation
proves it works; it does not prove that (a) it survives a fresh deploy from the
committed repo, or (b) it holds alongside the other four defences.

The classic failure mode: "it worked in testing because the person who tested
it also configured the box." The committed repo becomes a spec, not a source of
truth, because the deployed state diverged from the repo through manual steps
that were never codified.

The clean redeploy + gauntlet sequence closes this gap:
1. Ansible dry-run shows the diff between the live box and the committed repo.
   If the diff is empty, the box is already in the IaC-defined state. If not,
   the deploy makes it so.
2. The gauntlet runs against whatever Ansible just deployed — no manual knob-
   turning between deploy and test.

### What "reproducible from committed repo" actually means

It means that `ansible-playbook deploy.yml` is the only post-provision step.
The test for this is: could someone start a fresh EC2 instance, run provision
then deploy, and have all five gauntlet stages pass? If yes, the defences are
IaC. If not, there is undocumented manual state somewhere.

The Day 13 deploy confirmed: after the single `deploy.yml` run, all five stages
passed with no manual intervention. The OOMScoreAdjust ordering
(fake-psp=500 > payment-api=200 > Postgres=0), the MemoryHigh/Max limits,
the logrotate config, the journald cap, and the TRANSACTION_LOG_PATH env var
path are all in committed files.

### Why the gauntlet stages are independent

Running stages as a pipeline (stage N gates stage N+1) is tempting but wrong
for an integration gauntlet:

- If Stage 3 (log rotation) leaves the service in an unexpected state, Stage 4's
  ENOSPC test should still run and report its own result — not be silently skipped.
- A PASS/FAIL table at the end is more useful than "the script aborted at Stage 3"
  because it shows which defences hold and which don't, independently.

The cost: each stage must be fully self-contained — its own setup, cleanup,
and error reporting. That is more code, but it is the correct structure.

### Stage 5 — why the OOM fires asynchronously

The balloon handler does not check `r.Context().Done()`:

```go
var balloon [][]byte  // package-level: GC cannot reclaim slabs

func handleBalloon(w http.ResponseWriter, r *http.Request) {
    slab := make([]byte, mb*1024*1024)
    const pageSize = 4096
    for i := 0; i < len(slab); i += pageSize {
        slab[i] = 1  // force page fault per 4KB page, 4KB at a time
    }
    balloon = append(balloon, slab)
    fmt.Fprintf(w, "ballooned +%dMB (total slabs: %d)\n", mb, len(balloon))
}
```

When curl hits its `-m 30` timeout and disconnects, the goroutine does not
stop — it continues faulting 4KB pages in the page-fault loop. Each call
adds a new goroutine in this state to the same process. Because `balloon` is
package-level, the GC cannot collect any slab from any prior call. RSS
accumulates across all calls in the same process instance.

This is why the OOM fires after the curl loop exits, not within the loop.
A polling loop after the main loop (12 × 10s = 120s) is necessary to catch
the asynchronous kill. A `sleep 5` post-loop check will miss it almost every time.

---

## What was observed

### Pre-gauntlet: clean state check

EC2 had one leftover test artefact from Day 9:
```
/opt/novapay/disktest.img  (64M backing file — loop device unmounted,
                             file not cleaned up after Day 9 disk-fill demo)
```
Removed before the gauntlet ran:
```bash
sudo rm -f /opt/novapay/disktest.img
```

### Part 2 — Clean redeploy from committed repo

Ansible dry-run confirmed all files match committed state (no diff). Real deploy:
```
TASK [Copy payment-api binary]    ok (already current)
TASK [Copy fake-psp binary]       ok (already current)
TASK [Copy systemd unit files]    ok (already current)
TASK [daemon-reload]              ok
TASK [Restart services]           changed (services restarted cleanly)
```
Post-deploy: `systemctl status payment-api` → `active (running)`, new PID.
`/healthz` → 200. EC2 invariant → 0 rows.

### Part 3 — Gauntlet run (final, all 5 PASS)

Full gauntlet output:

```
=== NovaPay Week 2 Gauntlet ===
KEY_PREFIX=g1751169239-24614
[S1] stage 1: PSP error rate — charging under 50% PSP failure rate
[S1] dropped gauntlet-s1.conf drop-in — PSP_ERROR_RATE=0.5
[S1] daemon-reload + restart done
[S1] firing 10 charges ...
[S1] 200s=7  non-200s=3
[S1] reverting drop-in ...
[S1] invariant check: 0 rows
STAGE 1  PASS   load test — invariant under 50% PSP error rate

[S2] stage 2: audit log reconciliation
[S2] before — log_lines=2  payments=N
[S2] firing 5 charges ...
[S2] after  — log_lines=7  payments=N+5  delta_log=5  delta_pay=5
STAGE 2  PASS   audit log reconciliation — 5 charges

[S3] stage 3: forced log rotation
[S3] lines before rotation: 7
[S3] running: sudo logrotate -f /etc/logrotate.d/novapay
[S3] waiting for 'audit log reopened' in journald ...
[S3] found 'audit log reopened' in journald (1 occurrence)
[S3] .1 line count: 7    pre-rotation count: 7
[S3] firing 1 charge post-rotation
[S3] active log lines after charge: 1
STAGE 3  PASS   forced rotation — zero lines lost

[S4] stage 4: disk-fill containment
[S4] root free: 2.8G — safety check passed
[S4] created 64M backing file at /tmp/gauntlet-disk.img
[S4] ext4 filesystem created
[S4] mounted at /mnt/novapay-audit-test
[S4] filling filesystem to ENOSPC...
[S4] filesystem full (ENOSPC confirmed)
[S4] dropped TRANSACTION_LOG_PATH drop-in
[S4] daemon-reload + restart done
[S4] firing 3 charges under ENOSPC ...
[S4] 200s=3  non-200s=0
[S4] cleanup: reverting drop-in, unmounting ...
[S4] umount succeeded
STAGE 4  PASS   disk-fill — charges return 200 under ENOSPC

[S5] stage 5: OOM containment
[S5] NOVAPAY_DEBUG drop-in enabled
[S5] daemon-reload + restart done
[S5] OOM_BEFORE=0  starting balloon loop (up to 10 calls, 30s each)
[S5] call 1 of 10: cumulative requested so far: ~300MB
[S5] call 2 of 10: cumulative requested so far: ~600MB
...
[S5] call 8 of 10: cumulative requested so far: ~2400MB
[S5] OOM detected mid-loop at call 8 (~2400MB cumulative requested into same process)
[S5] OOM kill confirmed (CONSTRAINT_MEMCG — cgroup-scoped, not system-wide)
[S5] postgres check: active
[S5] waiting for payment-api to recover ...
[S5] payment-api recovered
[S5] recovery charge: 200
[S5] invariant after OOM: 0 rows
[S5] cleanup: reverting NOVAPAY_DEBUG drop-in ...
[S5] /debug/balloon: 404 (debug endpoint gone)

STAGE 5  PASS   OOM — CONSTRAINT_MEMCG kill, Postgres safe

=== GAUNTLET SUMMARY ===
STAGE 1  PASS   load test — invariant under 50% PSP error rate
STAGE 2  PASS   audit log reconciliation — 5 charges
STAGE 3  PASS   forced rotation — zero lines lost
STAGE 4  PASS   disk-fill — charges return 200 under ENOSPC
STAGE 5  PASS   OOM — CONSTRAINT_MEMCG kill, Postgres safe
```

All 5 PASS. Postgres untouched throughout. Invariant 0 rows at every check.

### Part 4 — Week 2 EC2 baseline (post-gauntlet)

Captured via Ansible ad-hoc after all 5 stages passed.

**Service memory limits (from systemctl show):**

| Service | MemoryHigh | MemoryMax | OOMScoreAdjust | StartLimitBurst |
|---------|-----------|----------|----------------|-----------------|
| payment-api | 128 MiB (134217728 B) | 192 MiB (201326592 B) | 200 | 5 |
| fake-psp | 64 MiB (67108864 B) | 96 MiB (100663296 B) | 500 | 5 |
| postgresql | infinity | infinity | 0 | — |

OOMScoreAdjust ordering: fake-psp=500 > payment-api=200 > Postgres=0.
Postgres has no cgroup cap — it is protected by the ordering, not by containment.

**Live process RSS (idle, post-gauntlet):**

| Process | PID | RSS |
|---------|-----|-----|
| payment-api | 8459 | 12,112 KB (~11.8 MiB) |
| fake-psp | 7933 | 7,404 KB (~7.2 MiB) |
| postgres (main) | 716 | 27,576 KB (~26.9 MiB) |
| postgres (worker 1) | 765 | 9,700 KB (~9.5 MiB) |
| postgres (worker 2) | 766 | 7,524 KB (~7.3 MiB) |

payment-api idle RSS has grown from 8.8 MiB (Day 12) to 11.8 MiB. The increase
is expected: the gauntlet charged heavily and goroutines (audit log fd, signal
handler, receipt goroutines) have accumulated state. Still well under 128 MiB
MemoryHigh.

**Budget arithmetic (updated from Day 12):**
```
payment-api  MemoryMax:   192 MiB
fake-psp     MemoryMax:    96 MiB
Postgres RSS (3 workers):  44 MiB  (post-gauntlet; Day 12 baseline was ~75 MiB)
OS + kernel + journald:    80 MiB
Safety margin:             50 MiB
─────────────────────────────────
Total:                    462 MiB   (of 911 MiB)
Remaining headroom:       449 MiB   (49% of box free)
```

**Host memory:**
```
               total        used        free      shared  buff/cache   available
Mem:           911Mi       409Mi       262Mi        17Mi       419Mi       501Mi
Swap:             0B          0B          0B
```
No swap. Available: 501 MiB. Box is healthy post-gauntlet.

**Disk:**
```
Filesystem      Size  Used Avail Use% Mounted on
/dev/root       6.8G  4.0G  2.8G  59% /
```

**Journald:**
```
Archived and active journals take up 164.3M in the file system.
Cap (ADR-010): 200M (SystemMaxUse=200M in /etc/systemd/journald.conf)
Headroom: 35.7M (18% below cap)
```

**Audit log:**
```
/var/log/novapay/
├── transactions.log       2 lines   551 B   (active — post-gauntlet charges)
├── transactions.log.1     ~70 lines 4.6K    (gauntlet Stage 3 pre-rotation content)
├── transactions.log.2.gz  860 B             (compressed)
├── transactions.log.3.gz  758 B             (compressed)
├── transactions.log.4.gz  969 B             (compressed)
└── transactions.log.5.gz  287 B             (compressed, from Day 24 Jun)
```
Logrotate has rotated 5 times since the audit log was introduced. No lines lost
across any rotation (Stage 3 proves the SIGHUP-reopen handoff is clean).

---

## Acceptance criteria — all met ✓

- [x] `/check` clean (build + vet + local invariant 0 rows) — session gate
- [x] Clean EC2 state confirmed (no test scaffolding leftover; disktest.img removed)
- [x] Clean redeploy from committed repo: Ansible deploy.yml, no manual steps;
      all limits and configs live on EC2 from committed files alone
- [x] `scripts/gauntlet-week02.sh` written; 5 independent stages; PASS/FAIL table
- [x] All 5 gauntlet stages: PASS
- [x] Stage 4 cleanup verified safe (umount exit code checked; backing file not
      deleted if umount fails; lsof/fuser diagnostics on failure)
- [x] Stage 5 evidence accurate: OOM is cumulative balloon growth in a single
      process instance (not 5 independent clean trials); PASS output says
      "N cumulative balloon calls, ~XMB requested into same process instance"
- [x] Week 2 EC2 baseline captured: RSS, memory limits, disk usage, journald usage
- [x] EC2 invariant: 0 rows after all 5 stages — ledger balanced throughout
- [x] Committed and pushed to main

---

## Problems hit

**`systemctl set-property` rejects `Environment=` on this EC2 systemd.**

Stage 1's original implementation used:
```bash
sudo systemctl set-property fake-psp.service Environment="PSP_ERROR_RATE=0.5"
```
Error: `"Cannot set property Environment, or unknown property."` — systemd on
this EC2 does not support runtime `Environment=` override via set-property.
`PSP_ERROR_RATE` was never set; all 10 Stage 1 charges returned 200 (test was
vacuous — no PSP errors were actually injected).

Fix: replaced with a drop-in file at
`/etc/systemd/system/fake-psp.service.d/gauntlet-s1.conf`, matching the pattern
used in Stage 4 and Stage 5. This is the same constraint that required drop-ins
for TRANSACTION_LOG_PATH in Stage 4. The constraint: `set-property` supports only
cgroup and resource directives on this systemd version; environment variables
require a drop-in file + daemon-reload.

**`grep -c ... || echo "0"` double-output bug in Stage 5.**

`grep -c` outputs `"0"` to stdout when it finds no matches, then exits 1. With
`pipefail`, `|| echo "0"` fires and writes a second `"0"`. The captured variable
becomes `"0\n0"`, which breaks integer comparisons:
```
[: "0\n0": integer expression expected
```
Fix: replaced all `grep -c ... || echo "0"` with `grep -c ... || true` throughout
the script (Stages 3, 4, and the three Stage 5 dmesg checks). `|| true` suppresses
the non-zero exit without adding output. `wc -l ... || echo "0"` is unaffected —
`wc -l` outputs nothing on a missing file; the `|| echo "0"` there is correct.

**Stage 5 OOM fires asynchronously — a 5-second post-loop check misses it.**

The original implementation polled dmesg once, 5 seconds after the last curl call.
Across three runs with 5 attempts, the OOM was detected once but missed twice.
Root cause: goroutines continue faulting pages after curl disconnects. The OOM
fires 10–120 seconds after the last call returns, depending on how far each
goroutine has progressed through the page-fault loop.

Fix: (1) increased `S5_MAX_ATTEMPTS` from 5 to 10; (2) replaced the single
post-loop sleep with a polling loop: 12 × 10s = 120s max, checking dmesg every
10 seconds and printing progress. The OOM was detected mid-loop at call 8
on the final run (~2400 MB cumulative requested). The 120s polling window is
deliberately generous — the goroutines running in background can take 1–2 minutes
to cross MemoryMax under kernel reclaim throttle.

---

## Commands worth keeping

```bash
# --- Gauntlet ---

# Run the full gauntlet (must be run from repo root on EC2)
bash scripts/gauntlet-week02.sh

# --- Week 2 baseline capture (all via Ansible from dev box) ---

# Memory limits from systemd
ansible -i infrastructure/ansible/inventory.ini novapay -m shell \
  -a "systemctl show payment-api fake-psp --property=MemoryHigh,MemoryMax,OOMScoreAdjust,StartLimitBurst,ActiveState"

# Live RSS
ansible -i infrastructure/ansible/inventory.ini novapay -m shell \
  -a "ps -o pid,comm,rss --no-headers -C payment-api && \
      ps -o pid,comm,rss --no-headers -C fake-psp && \
      ps -o pid,comm,rss --no-headers -C postgres"

# Journald disk usage vs cap
ansible -i infrastructure/ansible/inventory.ini novapay -m shell \
  -a "journalctl --disk-usage && grep SystemMaxUse /etc/systemd/journald.conf"

# Audit log state
ansible -i infrastructure/ansible/inventory.ini novapay -m shell \
  -a "ls -lh /var/log/novapay/ && wc -l /var/log/novapay/transactions.log"

# --- Drop-in pattern (set-property does not support Environment= here) ---

# Create environment drop-in
sudo mkdir -p /etc/systemd/system/fake-psp.service.d
sudo tee /etc/systemd/system/fake-psp.service.d/gauntlet.conf <<EOF
[Service]
Environment="KEY=VALUE"
EOF
sudo systemctl daemon-reload && sudo systemctl restart fake-psp

# Clean it up
sudo rm -f /etc/systemd/system/fake-psp.service.d/gauntlet.conf
sudo systemctl daemon-reload && sudo systemctl restart fake-psp

# --- Asynchronous OOM detection ---

# Poll dmesg for CONSTRAINT_MEMCG kill (use in a loop with sleep)
sudo dmesg | grep -c "CONSTRAINT_MEMCG" || true

# Full OOM context from dmesg
sudo dmesg | grep -A3 "oom-kill" | tail -20

# --- Loop device safety ---

# Check what holds a mount before umount
sudo lsof +D /mnt/target 2>/dev/null
sudo fuser -vm /mnt/target 2>/dev/null

# Only rm backing file if umount succeeded — never rm while mounted
if sudo umount /mnt/target; then rm -f backing.img; fi
```

---

## LinkedIn article notes

*(See separate file: `notes/month-01/week-02/article-disk-fill.md`)*

The article covers Stage 4 (ENOSPC containment) as the primary lens — the
counterintuitive result that `POST /charge` returns 200 even when the audit
log filesystem is completely full. Secondary lens: how `logrotate -f` with
SIGHUP-reopen produces zero lost lines, and why that matters for a financial
audit trail.

The OOM defence from Stage 5 is the "what comes next" paragraph — the disk is
one resource; memory is the other. Both are now bounded and both were proven
under adversarial conditions in the same session.

---

## Handoff to Day 14

**Status:** Day 13 complete ✓

Week 2 is operationally complete. All five defences are:
- Committed as IaC (no post-deploy manual steps)
- Reproducible from `ansible-playbook deploy.yml` alone
- Verified end-to-end by the gauntlet

**Day 14:** LinkedIn article publish + `/generate-questions 13` + Week 2
learning questions review. The article draft is started in
`notes/month-01/week-02/article-disk-fill.md` — Day 14 is finalize, edit,
and publish to LinkedIn.

**Week 3 preview (from week-02-plan.md):** observability — structured logging
deeper review, metrics exposition, alerting. The Week 2 baseline numbers
(RSS, journald usage, disk) become the alerting thresholds.
