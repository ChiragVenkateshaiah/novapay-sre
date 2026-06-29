# Article Draft: "Designing a payments box that can't fill its own disk"

**Target:** LinkedIn long-form post
**Status:** draft — Day 13
**Publish:** Day 14

---

## Draft

---

I ran an experiment last week: I filled the audit log filesystem to 100% capacity on purpose, then fired three payment charges at the service.

All three returned HTTP 200. The ledger balanced. The money moved.

Here's why that's the right behaviour, and what it took to make it happen reliably.

---

**The problem with "write the audit log or fail the charge"**

The obvious design is: if you can't write the audit log, fail the charge and return an error. Safe. Conservative.

But it breaks an invariant: the ledger transaction completes inside a database transaction. Postgres has already committed the debit and credit entries when you try to write the audit log. Rolling back the Postgres transaction because a log file write failed means you're using a log file as a distributed coordinator — and log file writes are far less reliable than Postgres commits.

The correct principle: **the audit log records what happened; it does not determine whether it happened.** If writing the log fails, the charge still completed. Surface the write failure as an error in your operational logs. Do not roll it back.

In Go:

```go
if err := writeAuditEntry(entry); err != nil {
    slog.Error("audit write failed", "err", err, "payment_id", paymentID)
    // charge is committed — we do not return an error to the caller
}
```

The Postgres transaction is committed before this line runs. The audit log write is best-effort.

---

**But then what fills your disk?**

If you're running on a single EC2 instance — payment API, database, and logs all on the same root filesystem — you have a disk-fill problem waiting to happen. The audit log, combined with application logs (journald by default in systemd), can quietly fill `/` over weeks or months.

When `/` is full:
- Postgres cannot write WAL entries → transactions fail
- systemd cannot write journal entries → logs go dark
- SSH sessions may not open new PTYs

The service that caused the disk to fill is the last thing you'll hear from.

---

**Two-layer defence: logrotate + journald cap**

Layer one: rotate the audit log before it grows unbounded.

```ini
# /etc/logrotate.d/novapay
/var/log/novapay/transactions.log {
    size 50M
    rotate 7
    compress
    missingok
    notifempty
    postrotate
        systemctl kill -s HUP payment-api.service
    endscript
}
```

The key is the `postrotate` block: it sends `SIGHUP` to the payment-api process, which the Go application catches and uses to reopen its file descriptor on the new, empty log file. Without SIGHUP reopen, logrotate renames the file but the process still holds an open fd to the old inode — writes go to the renamed file, not the new one. You think you're rotating; you're not.

I ran `logrotate -f` (force immediate rotation) during the gauntlet and checked that:
1. The `.1` file had exactly the same number of lines as the pre-rotation active log (zero lines dropped during the handoff)
2. The next charge wrote to the new active log (one line, new file, correct)

Layer two: cap journald.

```ini
# /etc/systemd/journald.conf
[Journal]
SystemMaxUse=200M
```

Without this, journald grows until it decides to rotate based on filesystem usage thresholds — which are generous by default. A service that logs verbosely (or a failing service in a crash loop) can push journald past anything reasonable. 200M is a hard ceiling.

Both of these are in Ansible IaC. A fresh deploy applies them. No manual step.

---

**The experiment: 64M loopback filesystem, completely full**

To prove the ENOSPC defence actually works:

```bash
# create a 64M backing file
fallocate -l 64M /tmp/gauntlet-disk.img
mkfs.ext4 /tmp/gauntlet-disk.img
mount -o loop /tmp/gauntlet-disk.img /mnt/novapay-audit-test

# fill it completely
dd if=/dev/zero of=/mnt/novapay-audit-test/fill bs=1M || true
# dd exits with "No space left on device"

# point the payment API at it via a systemd drop-in
mkdir -p /etc/systemd/system/payment-api.service.d
tee /etc/systemd/system/payment-api.service.d/enospc-test.conf <<EOF
[Service]
Environment="TRANSACTION_LOG_PATH=/mnt/novapay-audit-test/transactions.log"
EOF
systemctl daemon-reload && systemctl restart payment-api
```

Then fired 3 charges:

```
HTTP 200  {"payment_id":"...","status":"approved"}
HTTP 200  {"payment_id":"...","status":"approved"}
HTTP 200  {"payment_id":"...","status":"approved"}
```

journald showed the write errors:

```
Jun 29 payment-api[8459]: ERROR audit write failed err="write /mnt/novapay-audit-test/transactions.log: no space left on device"
```

The ledger invariant after all three:

```sql
SELECT payment_id, SUM(debits), SUM(credits)
FROM ledger_entries GROUP BY payment_id
HAVING SUM(debits) != SUM(credits);
-- 0 rows
```

Zero rows. Every charge produced exactly one debit and one credit. The audit log was silent; the ledger was correct.

---

**What the audit log is for — and what it isn't**

The audit log is a record for reconciliation: an external readable file that operations, compliance, or a separate service can consume without querying Postgres. It contains idempotency key, payment ID, amount, status, and timestamp in JSON — one line per charge.

It is not the source of truth for whether a charge completed. Postgres is. If the audit log and Postgres disagree, Postgres wins, and the missing audit log line is a bug in the logging path, not in the ledger.

This separation is what allows the ENOSPC defence to work cleanly. The charge result is determined entirely inside a Postgres transaction. The audit write is observation, not determination.

---

**The second resource: memory**

The audit log consumes disk. But the payment API also consumes memory — and on a single-node deployment, if the API leaks memory and the kernel's OOM killer fires, it might kill Postgres instead of the API.

The defence for this is symmetric: two systemd resource limits in the unit file:

```ini
[Service]
MemoryHigh=128M    # soft throttle: kernel starts reclaiming pages
MemoryMax=192M     # hard ceiling: cgroup OOM kill if exceeded

OOMScoreAdjust=200 # score bias: die before Postgres under system-wide OOM pressure
```

`OOMScoreAdjust=200` raises the API's OOM score relative to Postgres (which runs at 0). Under system-wide memory pressure, the kernel uses this score to decide who dies first. With the ordering `fake-psp=500 > payment-api=200 > Postgres=0`, the stub bank dies before the API, and the API dies before the database.

The dmesg line from our gauntlet run:

```
[...] payment-api invoked oom-killer: gfp_mask=0x100cca, order=0, oom_score_adj=200
[...] oom-kill:constraint=CONSTRAINT_MEMCG,
      oom_memcg=/system.slice/payment-api.service,
      task=payment-api,pid=8459,uid=1000
```

`constraint=CONSTRAINT_MEMCG` — the kill is cgroup-scoped. The API's cgroup hit `MemoryMax=192M` and the kernel killed only that cgroup's processes. Postgres was untouched. The API restarted in 5 seconds. The next charge succeeded.

---

**What this looks like in a real incident**

Without these defences, the failure mode is: the disk fills silently (the payment API never returns errors), journald stops logging, Postgres can't write WAL, and the next charge fails with a database error. By the time you notice something is wrong, you may have lost minutes of logs and have no clear starting point.

With the defences: the disk fills, the audit log writes stop, journald surfaces ERROR entries pointing at the exact cause, and charges continue returning 200 with correct ledger entries. You have a clear signal with no data loss.

For the memory case: without a MemoryMax cap, a leaking payment-api on a 911 MB / no-swap box can push system memory to the limit and get Postgres OOM-killed. With the cap, the API kills itself within its own cgroup, restarts clean, and Postgres never sees the event.

Both defences follow the same principle: **fail the noisy component, protect the source of truth.**

---

**The setup**

This is all running on a t3.micro EC2 instance — 1 vCPU, 1 GB RAM, 8 GB root volume. Payment API and fake bank in Go; PostgreSQL for the double-entry ledger; systemd for service management; Ansible for IaC. No Kubernetes, no managed database, no managed logging. The constraints are deliberate — single-node keeps failure modes tractable when you're learning them from first principles.

All of this is committed as Ansible IaC. Running `ansible-playbook deploy.yml` on a fresh provisioned instance produces a box with the logrotate config, journald cap, memory limits, and OOM score ordering all active — no manual steps. That reproducibility was itself a goal: defences that require manual post-deploy steps are defences that won't be there when you actually need them.

---

*Building NovaPay — a production-like payments system — as a structured learning environment for SRE and platform engineering. Day 13 of the build log.*

---

## Editorial notes for finalization (Day 14)

- Lead with the 200 result before explaining why — don't bury the counterintuitive finding
- The code blocks are good; keep them — senior engineers scan for specifics
- The `constraint=CONSTRAINT_MEMCG` dmesg line is the strongest specific in the piece — make sure it reads as a payoff for the OOM section
- Consider cutting the "What the audit log is for" section or tightening it to 2 sentences — it's explanatory, not surprising
- The closing paragraph about t3.micro + Ansible is the right hook for the "why this matters beyond Kubernetes" crowd — keep it
- Target length: 900–1100 words (currently ~1050 words estimated) — good range, resist padding
- Tags: #SRE #SystemsEngineering #Linux #Payments #Infrastructure
