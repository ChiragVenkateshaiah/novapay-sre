# ADR-010 — Log Rotation and Retention Policy

**Date:** 2026-06-24
**Status:** Accepted
**Decider:** Chirag Venkateshaiah

---

## Context

Day 8 (ADR-009) added a dedicated audit log at `/var/log/novapay/transactions.log`.
Day 9 (INC-006) demonstrated that a full audit-log filesystem produces ENOSPC on
every write — the resilient `auditWriter` keeps charges flowing and the invariant
intact, but audit lines are silently lost for as long as the disk is full. The
ADR-009 design explicitly left closing this gap to ADR-010.

The box is a t3.micro with a single root volume: 6.8G total, 2.8G free, no
separate log partition. `payment-api` writes one JSON audit line per charge;
`journald` captures all operational logs from both services. Without rotation or
caps, sustained charge volume will eventually fill `/`, at which point Postgres
cannot write its WAL and the ledger goes down — a correctness failure, not just
an observability failure.

Two independent disk-fill vectors exist:
1. The audit log file growing without bound.
2. `journald` accumulating without a `SystemMaxUse` cap (defaults to ~10% of
   total disk ≈ 680M on this box).

This ADR closes both.

---

## Decision

### 1. Size-based rotation, not time-based

logrotate is configured with `size 50M`, not `daily` or `weekly`.

**Rationale:** disk fill risk correlates with charge volume, not elapsed time. A
box processing bursts of charges can fill 50M in hours; a box processing light
traffic might take months. A time-based trigger provides false safety during
bursts and unnecessary churn during quiet periods. Size-based rotation fires
exactly when needed.

### 2. Seven compressed generations retained

`rotate 7` with `compress` and `delaycompress`.

**Worst-case ceiling math:** the active log is at most 50M before rotation. Each
compressed generation is typically 5–10% of uncompressed size for structured JSON
(high repetition across fields). At a conservative 15% compression ratio, 7
rotations ≈ 7 × 7.5M ≈ 52M. Total ceiling: 50M active + 52M rotated ≈ 102M.
Well under 500M; well under the 2.8G free observed on the live box. Recorded
here as the authoritative bound; Day 13's gauntlet will verify it holds.

`delaycompress` leaves the newest rotated file (`transactions.log.1`)
uncompressed for one cycle. This is a defensive measure: if the SIGHUP-reopen
fails and `payment-api` is still writing to the renamed file descriptor, those
writes land in `transactions.log.1` in a readable form rather than corrupting
a partially-compressed file.

### 3. SIGHUP-reopen, not copytruncate

logrotate uses `create` mode with a `postrotate` stanza that sends SIGHUP to
`payment-api`, which then closes the old file handle and opens the new one.
`copytruncate` was explicitly rejected.

**Why copytruncate loses audit lines:**
`copytruncate` copies the active log to the rotated name, then truncates the
original in place. Between the copy completing and the truncate, any charge
handler goroutine can write a line to the still-open (not-yet-truncated)
original — that line lands in neither the copy (already done) nor the rotated
file. It is silently lost. For operational logs this is acceptable; for a
financial audit trail it is not.

**The SIGHUP-reopen sequence:**
1. logrotate renames `transactions.log` → `transactions.log.1`, creates a fresh
   empty `transactions.log`.
2. logrotate sends `systemctl kill -s HUP payment-api.service`.
3. `auditWriter.reopen()` opens the fresh `transactions.log` (outside the lock —
   charges continue writing to the renamed fd during this window; those writes
   land in `transactions.log.1`, not lost).
4. `w.mu.Lock()` — drains all in-flight `Write` RLocks.
5. `w.f = newF` — atomic swap; `w.mu.Unlock()`.
6. Old fd closed — nothing can be writing to it; `w.mu.Lock()` drained all
   holders at step 4.

Lines written between steps 1 and 4 go to `transactions.log.1`. Lines written
after step 6 go to the fresh `transactions.log`. Total lines across both files
equals total charges fired — zero lost. **Verified empirically on EC2 on Day 10
with a forced rotation under the real logrotate binary: 2 pre-rotation charges
in `transactions.log.1`, 1 post-rotation charge in fresh `transactions.log`,
3 total == 3 charges fired.**

**Race safety:** `auditWriter` uses `sync.RWMutex`. `Write` holds `RLock` for
the entire duration of each `os.File.Write` call. `reopen` acquires `Lock`
(exclusive) before swapping `w.f`, and calls `old.Close()` only after releasing
`Lock`. This eliminates the write-to-closed-fd race that would exist with a bare
pointer swap.

### 4. journald SystemMaxUse cap

`/etc/systemd/journald.conf.d/novapay.conf` deployed via Ansible:

```
[Journal]
SystemMaxUse=200M
```

`journald` is a second, independent disk-fill vector. Day 9's loopback test
isolated the audit log; it never touched journald. Without a cap, journald
defaults to consuming up to ~10% of total disk (≈ 680M on this box). This cap
bounds it to 200M — leaving substantial headroom below the 2.8G free even if
both the audit log and journald approach their ceilings simultaneously.

Combined worst-case: 102M (audit log + rotations) + 200M (journald) = 302M ≪
2.8G free. Root is structurally protected.

### 5. Deployed as Ansible IaC

Both configs are managed through `deploy.yml`:
- `infrastructure/logrotate/novapay` → `/etc/logrotate.d/novapay`
- `infrastructure/journald/novapay.conf` → `/etc/systemd/journald.conf.d/novapay.conf`

A handler restarts `systemd-journald` after the drop-in changes (journald
requires a restart to pick up new config). The handler fires after all tasks —
including the payment-api and fake-psp restarts — so there is no window where
journald restarts mid-verification of the new binaries.

---

## Alternatives rejected

| Alternative | Reason rejected |
|---|---|
| `copytruncate` | Silent audit-line loss during the copy/truncate window; unacceptable for a financial audit trail |
| Time-based rotation (`daily`/`weekly`) | Risk correlates with charge volume, not clock time; false safety during bursts |
| App-native rotation (Go `lumberjack` or similar) | Reinvents logrotate; adds a dependency; logrotate is already present and standard |
| Uncapped journald | A second, independent disk-fill vector; 680M default ceiling is too high on a 2.8G-free box |
| Separate log partition | Not available on a t3.micro with a single root volume; would require instance resize or EBS changes deferred to Phase 4 |
| Per-write fsync on rotation boundary | Charge-path latency cost; the DB commit is the durable backstop, not the audit line |

---

## Consequences

- The audit log is bounded to ≈ 102M worst-case; journald to 200M. Combined
  ceiling is 302M against 2.8G free — root is structurally protected under
  normal operation.
- Zero audit lines are lost across a rotation, provided logrotate completes its
  rename/recreate before the `postrotate` SIGHUP is sent. This is logrotate's
  documented and observed contract: `create` mode renames then creates, then
  runs `postrotate`. Verified empirically on Day 10.
- If `reopen()` fails (e.g., permissions issue on the new file), `payment-api`
  logs an `ERROR` to journald and continues writing to the old (rotated) fd.
  Charges are not affected. The operator must intervene to fix the path.
- `delaycompress` means the previous rotation (`transactions.log.1`) is always
  human-readable without decompression — useful for incident investigation in
  the 24-hour window after a rotation.
- A leftover `systemctl set-property` environment override (`TRANSACTION_LOG_PATH`
  pointing at a torn-down loop filesystem) was found at the start of Day 10,
  causing silent audit-write failures. Teardown runbooks must now explicitly
  include `systemctl revert <unit>` and verify with `systemctl show --property=Environment`.
  This is a workflow consequence, not a code consequence.
