# Day 08 — Structured Transaction Audit Log

**Date:** 2026-06-19
**Week:** 2 · Phase 1 (Linux & Systems Foundations)
**Status:** Complete ✅

---

## Goal for today

Add a durable, structured per-charge transaction audit log to `payment-api` — a
dedicated JSON-lines file at `/var/log/novapay/transactions.log`, separate from
the journald operational log. The write must be **resilient**: a log-write failure
must never fail a charge or break the ledger invariant.

---

## What was actually built

### `auditWriter` — error-surfacing file wrapper

`*os.File` wrapper implementing `io.Writer`. On write error (ENOSPC, bad fd,
etc.) it calls `slog.Error(...)` to journald and returns `nil` to the caller.
This is the mechanism that makes Day 9's disk-fill observable: the ENOSPC shows
up in journald per charge rather than being silently swallowed by slog.

```go
func (w *auditWriter) Write(p []byte) (int, error) {
    _, err := w.f.Write(p)
    if err != nil {
        slog.Error("audit log write failed", "err", err)
    }
    return len(p), nil  // always return nil — never suppress further writes
}
```

### `initAuditLog()` — startup open, single ERROR on failure

Opens `TRANSACTION_LOG_PATH` (default `/var/log/novapay/transactions.log`) with
`O_APPEND|O_CREATE|O_WRONLY`. On failure: one `ERROR` to journald, `txLog` stays
`nil`. All subsequent `writeAuditLine()` calls are no-ops. The service starts
regardless — a misconfigured audit path is an operator problem, not a reason to
refuse charges.

### `slog.NewJSONHandler` with `ReplaceAttr`

The handler renames `time` → `ts` (RFC3339 UTC) and strips `level` and `msg`
entirely. Result is a clean financial audit schema with no slog boilerplate:

```json
{
  "ts": "2026-06-19T08:47:30Z",
  "event": "charge",
  "payment_id": "9f161d49-7061-44c5-a696-f8a1284bb86a",
  "idempotency_key": "ec2-ac6-001",
  "amount_minor": 1500,
  "currency": "CAD",
  "customer_id": "cust-ec2",
  "psp_status": "approved",
  "psp_ref": "psp_bb26431b",
  "latency_ms": 12
}
```

### Two write points in `handleCharge`

- `event="charge"` — written after `tx.Commit()` succeeds. Money moved, ledger
  balanced, audit recorded.
- `event="charge_idempotent"` — written at the idempotency early-return. No money
  moved, but the replay is recorded so the audit trail is complete.

The idempotency query was extended to also scan `psp_ref`:
```go
`SELECT id, status, psp_ref FROM payments WHERE idempotency_key = $1`
```
Previously only `id` and `status` were fetched. Now the idempotent audit line
carries the original `psp_ref` too.

### `txLogWriter *auditWriter` at package level

Stored at package scope for Day 10's SIGHUP-reopen. When logrotate rotates
the file, the SIGHUP handler will close `txLogWriter.f`, open the new file,
and point `txLog` at the new handler — without any other refactoring.

### ADR-009 committed

Decisions documented: dedicated file stream (not journald-only), resilient write
(never fails a charge), JSON schema, no per-write fsync (DB commit is the durable
backstop), `auditWriter` for error surfacing. Alternatives rejected: journald-only,
Postgres audit table, per-write fsync, async goroutine write, fail-charge-on-error.

---

## Acceptance criteria — results

| AC | Check | Result |
|---|---|---|
| AC1 | 1 charge → 1 line; `jq -e '.payment_id and .amount_minor and .psp_status and .ts'` exits 0 | ✅ |
| AC2 | 10 charges → 10 lines == `count(*) FROM payments` | ✅ |
| AC3 | Idempotent replay → `charge` + `charge_idempotent` in audit; DB 1 row; invariant 0 rows | ✅ |
| AC4 | Idempotent invariant 0 rows | ✅ |
| AC5 | `TRANSACTION_LOG_PATH=/nonexistent/dir` → charge 200, DB commits, invariant 0 rows, ERROR logged | ✅ |
| AC6 | EC2 charge appends to `/var/log/novapay/transactions.log`; `/ec2-invariant` 0 rows | ✅ |

---

## Problems hit

### 1. `initAuditLog()` not called before `go run .` in wrong directory

During local testing, the first `go run .` invocation was launched from the
repo root, not `app/payment-api/`. The command ran but the binary started from
the wrong working directory. Caught quickly by checking `healthz` — service
responded, so it worked, but the invocation was messy. Fixed by always specifying
`cd app/payment-api` before `go run .` or running from that directory.

### 2. LSP hints on existing retry loop

Two `go vet`-adjacent hints from the LSP (`rangeint`, `minmax`) appeared on lines
376/379 — the existing `callPSP` retry loop, unchanged today. They're style
modernisations (`range N` and `min()` builtins from Go 1.22+), not correctness
issues, and fixing them would be scope creep. Left as-is.

---

## /ec2-tx tool bug — caught and fixed mid-session

### What broke

The `/ec2-tx` command used shell command substitution to embed a line count in
the output header:

```bash
ssh -i ~/.ssh/sre-lab-key.pem ubuntu@<IP> \
  "tail -n 20 /var/log/novapay/transactions.log | jq . && \
   echo '=== Total lines: '$(wc -l < /var/log/novapay/transactions.log)"
```

The `$(wc -l < /var/log/novapay/transactions.log)` was wrapped in **double quotes**,
so the local shell expanded it before sending the command over SSH. The local
machine has no `/var/log/novapay/transactions.log`, so `wc -l` returned an error
and the line count came back blank:

```
=== Total lines:      ← blank, error on local shell
```

Meanwhile the audit line content itself was printed correctly (it came from the
`tail | jq .` part, which ran on the remote).

### How it was caught

The blank count disagreed with the manual cross-check:
- `ls -lh` showed `258 bytes` — consistent with exactly one JSON line
- `tail -1 ... | jq .` showed a complete, valid JSON object
- A blank count alongside correct content is a contradiction → the tool had a bug

**Rule reinforced: when a verification tool and a direct observation disagree,
investigate the tool. Don't assume the direct observation is wrong.**

### The fix

Changed outer quotes from double to single so the subshell runs on the remote:

```bash
ssh -i ~/.ssh/sre-lab-key.pem ubuntu@<IP> \
  'tail -n 20 /var/log/novapay/transactions.log | jq . && \
   echo "=== Total lines: $(wc -l < /var/log/novapay/transactions.log)"'
```

Single-quoted outer string → local shell does not expand `$(...)` → the whole
string is sent verbatim to the remote → `wc -l` runs on EC2 against the actual
file.

### The lesson

A verification tool can itself have a bug. The failure mode here was subtle:
most of the output was correct (the JSON content), which made the blank count
easy to overlook. The right response when a check partially misfires is to
treat the *entire output of that check* as suspect until the discrepancy is
explained — not to accept the correct-looking parts and ignore the blank.

---

## What I learned

### The `ReplaceAttr` pattern for clean JSON schemas

`slog.NewJSONHandler` always emits `time`, `level`, and `msg` by default. For
a financial audit file you want neither the slog boilerplate (`"level":"INFO"`,
`"msg":""`) nor the default time key name (`"time"` vs. the conventional `"ts"`).
`ReplaceAttr` is the right escape hatch: return `slog.Attr{}` (zero value) to
omit a field entirely, or return a renamed attr to change the key. The function
runs per field per log call, so it's cheap for this use case.

### The audit write must come *after* commit, not before

A natural mistake would be to write the audit line inside the transaction
(between the ledger inserts and the commit), so that "if it's in the DB it's in
the audit log." But that reasoning is backwards: the audit write is to a file,
not to Postgres, and a file write does not participate in the DB transaction. If
the commit fails after the file write, you'd have an audit line for a payment
that was rolled back. Writing after `tx.Commit()` is the correct ordering: the
money is definitively in the ledger before the audit line is recorded.

### `O_APPEND` is the right flag — not `O_TRUNC`, not `O_SYNC`

`O_APPEND` makes each write atomic at the OS level for small writes (less than
`PIPE_BUF`, typically 4KB on Linux — well within a single JSON line). Multiple
concurrent charge handlers writing to the same file don't need a mutex because
`O_APPEND` guarantees that each write is positioned at the end atomically.
`O_SYNC` would force an fsync per write — correct for a true write-ahead log,
expensive for an audit trail where the DB transaction is already the durable
backstop.

---

## Workflow additions today

- `.claude/commands/tail-tx.md` — tail + `jq`-pretty the local audit log
- `.claude/commands/ec2-tx.md` — tail + `jq`-pretty the audit log on EC2
  (bug fixed: single-quoted SSH string so `wc -l` runs remotely)
- `docs/decisions/ADR-009-audit-log-file-stream.md` — committed
- `CLAUDE.md` — three new architectural constraints (ADR-009 lines); `/tail-tx`
  and `/ec2-tx` added to command list
- **Agentic workflow gain today:** `/tail-tx` + `/ec2-tx` mean the audit stream
  is inspectable in one command locally and on EC2 — no SSHing and no manual
  `tail | jq` construction needed for Day 9 disk-fill observation

---

## EC2 deploy verification

```
08:46:54  INFO  audit log opened  path=/var/log/novapay/transactions.log
08:46:54  INFO  payment-api starting  port=8080
08:47:30  INFO  charge complete  payment_id=9f161d49…  psp_status=approved  latency_ms=12
```

- Zero ERRORs in journald
- Audit file: 1 line, 258 bytes, correct schema
- Invariant: 0 rows after the EC2 test charge
- `/var/log/novapay/` owned by `ubuntu:ubuntu`, `drwxr-xr-x` — no permission issues

---

## Tomorrow — Day 9

Disk-fill incident observation (INC-006):
- Create a 64MB loopback filesystem at `/opt/novapay/disktest.img`
- Mount it, point `TRANSACTION_LOG_PATH` at it
- Fill it with `dd`, then fire charges — observe ENOSPC surfacing in journald
  while charges still return 200 and the invariant holds
- The key question: does today's `auditWriter.Write()` error-logging actually
  appear in journald during ENOSPC? That's what Day 9 proves.
- Root volume must be untouched throughout — `df -h /` captured before/during/after
  as the safety proof

**Before starting Day 9:** run `/check` and `/ec2-invariant` to confirm clean
baseline. Open INC-006 GitHub issue *before* the disk-fill, not after.
