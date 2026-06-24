# Day 10 — Log Rotation + SIGHUP-Reopen + journald Cap: Closing INC-006

**Date:** 2026-06-24
**Phase:** Phase 1 · Week 2 · Linux & Systems Foundations
**Status:** complete ✓
**Commit:** D10 commit — pushed at end of session (see git log)

---

## Goal

Day 9 (INC-006) proved that a full audit-log filesystem produces ENOSPC on every
write: charges keep flowing, the ledger invariant holds, but audit lines are
silently lost for as long as the disk is full. The ADR-009 resilient write is a
backstop for transient failures, not a policy for preventing the disk from filling
in the first place. Day 10 closes the gap with two complementary defences, both
deployed as Ansible IaC so they are reproducible on a clean box, not hand-edits.

The two defences address two independent disk-fill vectors:
1. The audit log growing without bound → logrotate with size-based rotation and
   SIGHUP-triggered file-handle reopen in `payment-api`.
2. `journald` accumulating without a cap → `SystemMaxUse=200M` via a drop-in
   config, deployed via Ansible handler.

The correctness claim for today: **zero audit lines are lost across a rotation**.
This is the empirical analogue of Day 8's correctness claim ("audit write never
fails a charge"). Both were verified on the live box, not assumed from the spec.

---

## What was actually built

### `app/payment-api/main.go` — three changes

#### 1. `auditWriter` struct: gained `mu sync.RWMutex` and `path string`

```go
// Before (Day 8):
type auditWriter struct {
    f *os.File
}

// After (Day 10):
type auditWriter struct {
    mu   sync.RWMutex
    f    *os.File
    path string
}
```

`mu` serialises SIGHUP reopens against concurrent charge writes (see Core Concept).
`path` stores the resolved audit log path at init time so `reopen()` does not need
to re-read the environment variable on every SIGHUP.

#### 2. `Write` method: RLock for full write duration; real byte count on success

```go
// Before (Day 8) — no lock, always returned len(p) even on success:
func (w *auditWriter) Write(p []byte) (int, error) {
    _, err := w.f.Write(p)
    if err != nil {
        slog.Error("audit log write failed", "err", err)
    }
    return len(p), nil
}

// After (Day 10) — holds RLock for entire write; real n on success, len(p) on error-swallow:
func (w *auditWriter) Write(p []byte) (int, error) {
    w.mu.RLock()
    defer w.mu.RUnlock()
    n, err := w.f.Write(p)
    if err != nil {
        slog.Error("audit log write failed", "err", err)
        return len(p), nil
    }
    return n, nil
}
```

Two distinct fixes here:
- **Lock:** `RLock` held for the full `w.f.Write(p)` call — this is what prevents
  the reopen's `Lock()` from closing the old fd while a write goroutine is mid-write
  on it. Releasing the lock before the write would leave a window where `reopen()`
  could close the fd between the lock release and the write call.
- **Byte count:** the original always returned `len(p), nil` — even on success, where
  the actual bytes written (`n`) might differ from `len(p)`. The error-swallowing
  contract (ADR-009) only requires returning `len(p), nil` when swallowing an error
  so slog doesn't suppress future writes. On a successful write, returning the real
  `n` is correct. This was caught during review before proceeding to Part 3.

#### 3. `reopen()` method: atomic file-handle swap under mutex

```go
func (w *auditWriter) reopen() {
    newF, err := os.OpenFile(w.path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
    if err != nil {
        slog.Error("audit log reopen failed", "path", w.path, "err", err)
        return
    }
    w.mu.Lock()
    old := w.f
    w.f = newF
    w.mu.Unlock()
    old.Close()
    slog.Info("audit log reopened", "path", w.path)
}
```

Opens the new file *outside* the lock so charges continue writing to the old
(renamed) fd during the open call. Acquires `Lock` to drain all in-flight writes,
swaps the pointer, releases before closing old — see Core Concept for the full
race analysis.

#### 4. `initAuditLog`: stores path on `auditWriter`

```go
// Before:
aw := &auditWriter{f: f}

// After:
aw := &auditWriter{f: f, path: path}
```

One-line change so `reopen()` knows what path to open.

#### 5. Signal goroutine: `for sig := range` loop with SIGHUP case

```go
// Before (Day 5/6) — one-shot receive, only SIGTERM:
go func() {
    sigCh := make(chan os.Signal, 1)
    signal.Notify(sigCh, syscall.SIGTERM, os.Interrupt)
    <-sigCh
    slog.Info("SIGTERM received — draining receipt worker")
    close(receiptWorker)
    wg.Wait()
    slog.Info("receipt worker drained")
    os.Exit(0)
}()

// After (Day 10) — loop dispatches SIGHUP and SIGTERM separately:
go func() {
    sigCh := make(chan os.Signal, 1)
    signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGHUP, os.Interrupt)
    for sig := range sigCh {
        switch sig {
        case syscall.SIGHUP:
            if txLogWriter != nil {
                txLogWriter.reopen()
            }
        default:
            slog.Info("SIGTERM received — draining receipt worker")
            close(receiptWorker)
            wg.Wait()
            slog.Info("receipt worker drained")
            os.Exit(0)
        }
    }
}()
```

The `for sig := range sigCh` pattern is required because SIGHUP can arrive many
times (daily rotation for 7 rotations before the oldest is dropped). The previous
`<-sigCh` would have consumed the first signal (whatever it was) and called
`os.Exit(0)` — a SIGHUP on a service that used to handle only SIGTERM would have
killed the process.

### `infrastructure/logrotate/novapay` (new file)

```
/var/log/novapay/transactions.log {
    size 50M
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 0644 ubuntu ubuntu
    postrotate
        systemctl kill -s HUP payment-api.service
    endscript
}
```

Size-based (not time-based), 7 compressed generations, SIGHUP-triggered reopen
via `postrotate`. `delaycompress` leaves `transactions.log.1` uncompressed for one
cycle — useful for incident investigation and as a safety net if reopen fails.

### `infrastructure/journald/novapay.conf` (new file)

```ini
[Journal]
SystemMaxUse=200M
```

Drop-in cap on journald disk use. Deployed to `/etc/systemd/journald.conf.d/novapay.conf`.

### `infrastructure/ansible/deploy.yml` — two new sections + handler

```yaml
    # ── Logging: logrotate config ─────────────────────────────────────────────

    - name: Copy logrotate config for novapay audit log
      copy:
        src: "{{ playbook_dir }}/../logrotate/novapay"
        dest: /etc/logrotate.d/novapay
        owner: root
        group: root
        mode: '0644'

    # ── Logging: journald disk cap ────────────────────────────────────────────

    - name: Ensure journald drop-in directory exists
      file:
        path: /etc/systemd/journald.conf.d
        state: directory
        owner: root
        group: root
        mode: '0755'

    - name: Copy journald cap drop-in
      copy:
        src: "{{ playbook_dir }}/../journald/novapay.conf"
        dest: /etc/systemd/journald.conf.d/novapay.conf
        owner: root
        group: root
        mode: '0644'
      notify: restart journald

  handlers:
    - name: restart journald
      systemd:
        name: systemd-journald
        state: restarted
```

The journald restart is a handler so it fires after all tasks — including
payment-api and fake-psp restarts — with no window where journald is restarting
while the new binaries are being verified. `/etc/systemd/journald.conf.d/` did
not exist on this box prior to Day 10; the `file: state: directory` task creates
it idempotently.

### `docs/decisions/ADR-010-log-rotation-retention-policy.md` (new file)

Records: size-based over time-based (risk correlates with charge volume);
SIGHUP-reopen over copytruncate (audit-line-loss race); journald as an
independent second vector; worst-case disk math (≈ 102M audit + 200M journald =
302M ≪ 2.8G free); empirical verification of zero-lines-lost on EC2.

---

## Core concept — Log Rotation, SIGHUP-Reopen, and File Descriptor Semantics

### The concept explained from first principles

A Unix process that opens a file gets a **file descriptor** (fd) — an integer
index into the kernel's per-process open-file table. The kernel's open-file
table entry holds the current seek offset and a pointer to the inode (the actual
on-disk file identity). The key invariant: **a file descriptor refers to an inode,
not a path**. Paths are just names for inodes in directory entries.

`logrotate` in `create` mode does the following sequence:

```
1. rename("transactions.log", "transactions.log.1")
   → The path "transactions.log" no longer exists.
   → The inode is now reachable only via "transactions.log.1".
   → Any open fd pointing at that inode still works — the fd holds the inode
     reference, not the path. payment-api's open fd is still valid.

2. open("transactions.log", O_CREAT|O_WRONLY, 0644)
   → Creates a fresh inode at the path "transactions.log".
   → This is a NEW inode, distinct from the one payment-api has open.

3. Run postrotate: systemctl kill -s HUP payment-api.service
   → SIGHUP delivered to payment-api.
   → payment-api's signal goroutine calls auditWriter.reopen().
   → reopen() opens "transactions.log" — gets the NEW inode's fd.
   → Under Lock, swaps w.f to the new fd.
   → Closes old fd (the renamed inode; postrotate has already run so logrotate
     is finished with it and won't be confused by a late close).
```

Between steps 1 and the end of step 3, any charge that completes writes its
audit line to the OLD fd (the renamed inode, now `transactions.log.1`). That
line is not lost — it lands in the rotated file. After step 3, charges write to
the NEW fd (`transactions.log`). The total count across both files equals the
total charge count. **Zero lines lost, and the proof is empirical, not just
logical.**

#### Why `copytruncate` loses lines

`copytruncate` copies the active file to the rotated name, then truncates the
original to zero. Between the copy completing and the truncate:

```
T=0  logrotate: copy complete → transactions.log.1 has N lines
T=1  charge goroutine: writes line N+1 to the still-open transactions.log
T=2  logrotate: truncate transactions.log to 0
```

Line N+1 existed in `transactions.log` between T=1 and T=2, then was erased by
the truncate. It is not in `transactions.log.1` (copied before T=1). It is not
in the truncated `transactions.log`. It is gone. For operational logs this is
acceptable. For a financial audit trail it is not — a missing audit line means
an unknown charge that cannot be reconciled against the ledger.

#### The RWMutex file-handle swap

The race `reopen()` is defending against:

```
T=0  charge goroutine: w.f.Write(p) — writing to old fd
T=1  signal goroutine: old.Close()   — closes the same fd
T=2  charge goroutine: write returns EBADF on closed fd
```

The fix: `Write` holds `RLock` for the *full duration* of `w.f.Write(p)`. Multiple
charge goroutines can hold `RLock` simultaneously (they write concurrently, which
is safe because `O_APPEND` writes to a file from multiple goroutines are atomic up
to `PIPE_BUF` on Linux for local filesystems). `reopen()` calls `Lock()` which
blocks until ALL `RLock` holders release. Only then does it swap `w.f` and release
`Lock`. `old.Close()` comes after `Unlock` — by then, no goroutine holds the old fd.

```go
// Write — many goroutines can be here simultaneously:
func (w *auditWriter) Write(p []byte) (int, error) {
    w.mu.RLock()
    defer w.mu.RUnlock()   // holds lock until w.f.Write returns
    n, err := w.f.Write(p)
    ...
}

// reopen — exclusive; waits for all Writers to drain:
func (w *auditWriter) reopen() {
    newF, _ := os.OpenFile(w.path, ...)  // outside lock — charges flow to old fd
    w.mu.Lock()                           // drains all in-flight Write calls
    old := w.f
    w.f = newF                            // atomic swap
    w.mu.Unlock()                         // new Write calls go to newF
    old.Close()                           // safe: no goroutine holds old
    slog.Info("audit log reopened", ...)
}
```

### Why it matters for a payments service specifically

The double-entry invariant requires that every charge produces exactly two ledger
entries summing to zero. The audit log is the second layer of record — the
per-charge human-readable trace that lets an operator reconcile "what did the
system process" against "what the ledger says". If audit lines are lost silently
during rotation, the audit count falls below the payment count and the mismatch
is invisible until someone runs `wc -l transactions.log* == SELECT count(*) FROM
payments`. On a real payments box, that comparison is part of the end-of-day
reconciliation; a gap means an investigation, a potential regulatory finding,
and customer support calls. "We lost some log lines during rotation" is not an
acceptable answer in a regulated context.

The invariant (DB ledger) is still correct. But the audit trail is not. They
must match.

### The broken pattern — copytruncate and the silent audit gap

If logrotate were configured with `copytruncate` instead of `create` + SIGHUP:
- A charge handler writing line N+1 between the copy and the truncate produces
  a line that never appears in any file.
- The process never restarts, never reopens; the fd continues pointing at the
  now-zeroed file.
- Subsequent charges append to the truncated file starting from offset 0 again.
- `wc -l transactions.log.1` + `wc -l transactions.log` < `SELECT count(*) FROM
  payments` — the gap is detectable but only after the fact.

### The correct pattern — create mode + SIGHUP-reopen

Already described above. The key design properties:
1. Lines written before SIGHUP delivery land in `transactions.log.1` — not lost.
2. The fd swap under `Lock` is atomic from the caller's perspective.
3. `old.Close()` after `Unlock` — no use-after-close possible.
4. Failed reopen logs `ERROR` and leaves `w.f` pointing at the old fd — the
   process continues writing to `transactions.log.1` indefinitely, which is
   wrong but not charge-path-breaking. The operator sees the ERROR and must
   intervene. (This is the same "fail soft, signal loudly" pattern as ADR-009.)

### The failure cascade — what happens at scale without rotation

Without logrotate, on a t3.micro processing 1000 charges/day at an average
audit line of 200 bytes:

```
200 bytes × 1000 charges/day × 365 days = 73MB/year
```

At moderate scale (10,000 charges/day): 730MB/year from the audit log alone.
At high scale (100,000/day): 7.3GB/year — exceeds the total disk on this box
within the first year. Once root fills:

1. Audit write → ENOSPC (ADR-009 handles: charge returns 200).
2. Next Postgres WAL write → ENOSPC → Postgres enters recovery or panics.
3. `payment-api` cannot commit transactions → charges return 500.
4. systemd restarts payment-api → `initAuditLog` fails → `txLog=nil`.
5. journald can no longer write either → no logs, no audit, charges failing.
6. The box is effectively bricked: money not moving, no observability.

logrotate prevents step 1 from ever being reached under normal operation.

---

## What was observed

### Local SIGHUP smoke-test (WSL2)

```bash
# started fake-psp on :8081, payment-api with TRANSACTION_LOG_PATH=/tmp/novapay-audit-test.log
$ curl -s localhost:8080/healthz
{"goroutines":7,"status":"ok"}

# charge 1
$ curl -s -X POST localhost:8080/charge -d '{"idempotency_key":"sighup-test-1","amount_minor":500,...}'
{"payment_id":"32fd4857-5c6a-4eae-8bc1-c8b941d189de","status":"approved"}

$ wc -l /tmp/novapay-audit-test.log
1 /tmp/novapay-audit-test.log

# send SIGHUP
$ kill -HUP 2873
$ grep "reopened" /tmp/novapay-api.log
2026/06/24 04:14:19 INFO audit log reopened path=/tmp/novapay-audit-test.log

# charge 2 (post-SIGHUP)
$ curl -s -X POST localhost:8080/charge -d '{"idempotency_key":"sighup-test-2","amount_minor":750,...}'
{"payment_id":"d66e87ac-1a74-4e94-afb0-9c2b211d2f5d","status":"approved"}

$ wc -l /tmp/novapay-audit-test.log
2 /tmp/novapay-audit-test.log

$ cat /tmp/novapay-audit-test.log | jq -r '.idempotency_key + " → " + .event'
sighup-test-1 → charge
sighup-test-2 → charge
```

Note: the local test uses the same path (no rename happens; process reopens the
same file on itself). This confirms the reopen code path executes without error.
The actual rename/recreate scenario is verified on EC2 below.

### Ansible dry-run (--check --diff)

```
PLAY RECAP
ec2: ok=13 changed=8 unreachable=0 failed=0 skipped=5 rescued=0 ignored=0
```

Changed tasks:
- Copy payment-api binary (new SIGHUP binary)
- Copy fake-psp binary
- Copy logrotate config → `/etc/logrotate.d/novapay` (full diff shown)
- Ensure journald drop-in directory → `/etc/systemd/journald.conf.d/` (absent → directory)
- Copy journald cap drop-in → `[Journal] SystemMaxUse=200M` (full diff shown)
- Enable and restart payment-api
- Enable and restart fake-psp
- HANDLER: restart journald (fires after all tasks)

### EC2 post-deploy verification

**Logrotate config parses clean:**
```
$ sudo logrotate -d /etc/logrotate.d/novapay
reading config file /etc/logrotate.d/novapay
...
log needs rotating   ← size trigger confirmed (if log > 50M)
```

**Forced rotation — zero lines lost:**
```
# 2 charges fired → transactions.log has 2 lines
$ wc -l /var/log/novapay/transactions.log
2

# force rotation
$ sudo logrotate -f /etc/logrotate.d/novapay

# journald confirms SIGHUP delivery and reopen:
$ journalctl -u payment-api -n 5
... INFO audit log reopened path=/var/log/novapay/transactions.log

# 1 charge fired after rotation
→ transactions.log: 1 line (new charge)
→ transactions.log.1: 2 lines (pre-rotation charges)
→ total: 3 lines == 3 charges fired — ZERO LINES LOST
```

**journald cap:**
```
$ journalctl --disk-usage
Archived and active journals take up 8.0M in the filesystem.
(effective ceiling now 200M per SystemMaxUse)
```

---

## Acceptance criteria — all met ✓

- [x] `/etc/logrotate.d/novapay` deployed via Ansible; `logrotate -d` parses clean.
- [x] Forced rotation: active log rotated, fresh active log created, payment-api reopens
      on SIGHUP, next charge lands in new file — zero lines lost across rotation
      (`lines_before + lines_after == count(*)`).
- [x] Disk ceiling computed and recorded in ADR-010: ≈ 102M audit + 200M journald = 302M ≪ 2.8G.
- [x] journald capped: `journalctl --disk-usage` respects `SystemMaxUse=200M` after journald restart.
- [x] INC-006 closed via GitHub MCP (#5) with full resolution comment.
- [x] ADR-010 committed.
- [x] `/check` clean (build + vet + invariant + EC2:8080 PASS).
- [x] Deployed via Ansible (dry-run gate first); `/ec2-invariant` 0 rows.

---

## Problems hit

### 1. `Write()` returned `len(p), nil` even on success — caught in review

**What was wrong:** the Day 8 implementation of `auditWriter.Write` always returned
`len(p), nil` regardless of whether the write succeeded. The error-swallowing
contract (returning `len(p), nil` to prevent slog from suppressing future writes)
only applies on the error path. On a successful write, the correct contract is
`io.Writer`: return the actual number of bytes written.

**Catch:** caught during code review of Part 2 before any EC2 deployment. The
fix was a one-line change: `n, err := w.f.Write(p)` and return `n, nil` on the
success path.

**Lesson:** the error-swallowing pattern (`return len(p), nil` to satisfy `io.Writer`
without propagating errors) is a deliberate override of the standard contract.
Apply it only on the error branch, not universally — otherwise the caller
receives misleading byte counts on successful writes.

### 2. Leftover `systemctl set-property` environment override from Day 9

**What happened:** at the start of Day 10, audit writes were silently failing on
EC2. The service appeared healthy (`systemctl status payment-api` active, charges
returning 200), but no new lines appeared in `/var/log/novapay/transactions.log`.

**Root cause:** Day 9's INC-006 observation used `sudo systemctl set-property
payment-api.service Environment=TRANSACTION_LOG_PATH=/mnt/novapay-logtest/transactions.log`
to redirect audit writes to the loop filesystem. Day 9's teardown unmounted the
loop filesystem and removed the backing file — but did not run `systemctl revert
payment-api`. The transient drop-in (`/etc/systemd/system/payment-api.service.d/`)
persisted across the service restart. On Day 10, `payment-api` was attempting to
open `/mnt/novapay-logtest/transactions.log`, which no longer existed (the mount
point was gone). `initAuditLog` logged one startup ERROR and set `txLog = nil`.
All subsequent audit writes were silent no-ops.

**Diagnosis:**
```bash
$ systemctl show payment-api --property=Environment
Environment=TRANSACTION_LOG_PATH=/mnt/novapay-logtest/transactions.log
```

**Fix:**
```bash
$ sudo systemctl revert payment-api
$ sudo systemctl daemon-reload
$ sudo systemctl restart payment-api
$ systemctl show payment-api --property=Environment
Environment=
```

**Lesson for teardown runbooks:** removing the underlying resource (umount + rm)
is not sufficient when a `systemctl set-property` override is in play. The
override creates a drop-in file on disk (`/etc/systemd/system/<unit>.d/*.conf`)
that survives the resource removal, survives service restarts, and survives
reboots. The correct teardown sequence:

```bash
sudo systemctl revert <unit>              # removes the drop-in
sudo systemctl daemon-reload              # picks up the reverted unit
sudo systemctl restart <unit>
systemctl show <unit> --property=Environment  # must be empty / default
```

This finding was recorded in INC-006's closing comment and in ADR-010's
Consequences section, and should be added to `disk-fill-demo.sh`'s teardown
runbook steps.

---

## Commands worth keeping

### logrotate — config, test, force

```bash
# Test config parses clean (dry-run, shows what would rotate):
sudo logrotate -d /etc/logrotate.d/novapay

# Force rotation regardless of size trigger (for testing):
sudo logrotate -f /etc/logrotate.d/novapay

# Confirm the rotated files are what you expect:
ls -lh /var/log/novapay/
# transactions.log        ← active (new lines go here after SIGHUP)
# transactions.log.1      ← most recent rotation (uncompressed, delaycompress)
# transactions.log.2.gz   ← older rotations (compressed)
```

### systemctl — detect and revert transient environment overrides

```bash
# Check if a unit has any active environment overrides:
systemctl show payment-api --property=Environment

# Check for transient drop-in files:
ls /etc/systemd/system/payment-api.service.d/

# Revert all transient set-property overrides (idempotent if nothing to revert):
sudo systemctl revert payment-api

# Always verify after revert:
sudo systemctl daemon-reload
sudo systemctl restart payment-api
systemctl show payment-api --property=Environment   # must be empty
```

### journald — disk usage and cap verification

```bash
# Check current disk usage vs cap:
journalctl --disk-usage

# Verify the cap is in effect (restart required after config change):
sudo systemctl restart systemd-journald
journalctl --disk-usage   # should now show cap applied

# Check the journald config including drop-ins:
systemd-analyze cat-config systemd/journald.conf
```

### SIGHUP delivery and verification

```bash
# Send SIGHUP to a specific service (preferred over kill -HUP <pid>
# because it survives service restarts and PID changes):
sudo systemctl kill -s HUP payment-api.service

# Verify reopen via journald (should appear within ~1s):
journalctl -u payment-api -n 5 | grep -E "reopened|reopen"

# Verify new lines land in fresh file (not the rotated one):
tail -f /var/log/novapay/transactions.log
```

### Zero-lines-lost verification (post-rotation reconciliation)

```bash
# Count lines in active + all rotated files:
cat /var/log/novapay/transactions.log <(zcat /var/log/novapay/transactions.log.*.gz 2>/dev/null) \
  /var/log/novapay/transactions.log.1 2>/dev/null | wc -l

# Compare against DB payment count:
psql postgresql://novapay:novapay@localhost:5432/novapay \
  -c "SELECT count(*) FROM payments;"

# They must be equal (or within idempotent-replay count if replays aren't in
# the audit log reconciliation).
```

---

## Agentic workflow addition

### ADR-010 committed — tooling ADR corpus grows

ADR-010 is the third tooling/methodology ADR this week (alongside 008 and 012
from Day 9). The ADR corpus now covers not just code decisions (001–007, 009)
but also deployment policy decisions (010), tooling decisions (008, 012), and
validation methodology decisions (013). The precedent from Day 9 for recording
infrastructure and workflow decisions in the same canonical MADR format continues.

### INC-006 closed via GitHub MCP

INC-006 (#5) received a full resolution comment documenting: the logrotate
config (size trigger, retention, compression strategy), the SIGHUP-reopen
mechanism and its race-safety proof, the journald cap, the forced-rotation
zero-lines-lost verification with exact counts (2 + 1 = 3), and the leftover
override incidental finding with the correct teardown procedure. Closed with
`state_reason: completed`.

Pattern followed: observe (Day 9) → comment observation → leave open → close on
defence commit. Same as INC-003 through INC-005.

### Ansible handler pattern established

The `notify: restart journald` + `handlers:` section is the first Ansible handler
in `deploy.yml`. This is the correct Ansible pattern for restart-on-change: the
handler fires exactly once (even if the task is notified multiple times) and only
after all tasks complete. Confirmed: journald restart fires after payment-api and
fake-psp restarts, not before or during.

### `infrastructure/logrotate/` and `infrastructure/journald/` directories

New convention: non-binary infrastructure config files that are not Ansible
playbooks or systemd units now have their own subdirectories under
`infrastructure/`. The Ansible playbook references them via relative paths
(`{{ playbook_dir }}/../logrotate/novapay`). Pattern is consistent with the
existing `infrastructure/systemd/` convention.

---

## LinkedIn article notes

**Strongest technical angle:**
"The file descriptor is not the file name. logrotate renames the file under your
process while your process is happily writing to the same bytes — and if you
don't handle SIGHUP, you write to a ghost."

**Specific numbers worth using:**
- Zero lines lost across a forced rotation — verified empirically (2 + 1 = 3)
- 302M worst-case disk ceiling vs 2.8G free — the defence is not theoretical
- `delaycompress` detail: one rotation cycle of human-readable headroom for
  incident investigation without gunzipping
- The leftover `set-property` override that survived teardown: "the mount was
  gone; the override wasn't"

**What NOT to make the article about:**
- The RWMutex internals (interesting to Go engineers, not to the broad SRE
  audience this series targets)
- Ansible handler execution order (too specific)
- ADR-010 writing process (too meta)

**The moment that resonates with a senior engineer:**
The `copytruncate` rejection. Any engineer who has worked at a regulated company
knows the audit trail is the one thing that cannot have gaps — it is the evidence
in the dispute resolution. The fact that `copytruncate` has a documented,
unpreventable race that loses lines during the copy/truncate window, and that
most logrotate examples on the internet use `copytruncate` for running processes,
is the hook. "The popular option silently loses audit lines. Here is why, and
what you should use instead."

---

## Handoff to Day 11

**Status:** Day 10 complete ✓ · INC-006 closed · ADR-010 committed · pushed

Day 11 is the **OOM incident observation** (INC-007). The same observe-then-defend
pattern as INC-006: demonstrate the failure mode safely, then close it on Day 12.

The OOM observation is structurally bounded: a cgroup-v2 `MemoryMax` cap is set
*before* ballooning begins. The balloon allocates memory only under
`NOVAPAY_DEBUG=1`. Postgres must remain active throughout.

**Day 11 starts with:**
1. `/check` — confirm clean baseline (build + vet + invariant + EC2:8080 PASS)
2. `/ec2-invariant` — confirm ledger balanced on EC2
3. Confirm Day 10 teardown is clean: `systemctl show payment-api --property=Environment`
   should be empty (no leftover TRANSACTION_LOG_PATH override)
4. Confirm logrotate is live: `ls /etc/logrotate.d/novapay` exists; `sudo logrotate -d`
   parses clean
5. Open INC-007 via GitHub MCP **before** adding the balloon endpoint
6. Add `NOVAPAY_DEBUG=1` balloon handler to `payment-api` — registered only when
   env var is set, never in deployed config
7. Set transient cgroup cap: `sudo systemctl set-property payment-api.service
   MemoryMax=128M MemoryHigh=96M` — cap goes on **before** any balloon
8. Balloon to 400M, observe cgroup OOM kill + systemd restart, verify Postgres active
9. Record before/during/after: `free -h`, `systemctl status postgresql`, invariant query
