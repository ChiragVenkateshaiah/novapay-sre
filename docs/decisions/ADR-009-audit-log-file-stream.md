# ADR-009 — Transaction Audit Log as a Dedicated, Resilient File Stream

**Date:** 2026-06-19
**Status:** Accepted
**Decider:** Chirag Venkateshaiah

---

## Context

`payment-api` already emits operational logs to journald via `log/slog`. Week 2
adds a per-charge **transaction audit log** — a durable, structured record of
every charge and idempotent replay. This ADR decides where that log goes, how it
is formatted, and what happens when it cannot be written.

The box is a t3.micro with a single root volume and 2.8G free. Postgres and the
Go services all share that volume. Any logging design must account for:

1. The audit log path failing to open at startup (bad config, missing directory).
2. The audit log filesystem filling at runtime (ENOSPC) — which Week 2's disk-fill
   incident (INC-006) will deliberately trigger.

In both cases, the invariant `sum(debits) == sum(credits)` must hold and the
charge must return 200. **Money correctness is never a casualty of a logging
failure.**

---

## Decision

### 1. Dedicated file, not journald-only

The audit log is written to a dedicated file
(`/var/log/novapay/transactions.log` by default, overridable via
`TRANSACTION_LOG_PATH`) using `slog.NewJSONHandler` with one JSON object per
line. This is separate from and in addition to the existing journald operational
log.

**Rationale:** journald is an operational stream — it rotates, vacuums, and
compresses on its own schedule. A financial audit trail needs to be queryable
(`grep`, `jq`, `awk`) and independently rotated with controlled retention.
Routing audit lines to journald collapses two distinct concerns and makes
independent retention impossible.

### 2. Resilient write: audit failure never fails a charge

The audit write is **synchronous on the charge path but error-swallowing**:

- If the file cannot be opened at startup, an `ERROR` is logged to journald once
  and `txLog` is set to `nil`. All subsequent audit writes are silent no-ops.
- If a write fails at runtime (e.g., ENOSPC), the error is caught by an
  `auditWriter` wrapper and logged to journald as an `ERROR` per failed write.
  The slog caller always receives a success return so it does not suppress
  further writes.
- In both cases the charge path continues: `tx.Commit()` has already succeeded,
  the response is 200, and the ledger is balanced. The audit line may be lost;
  the money is never wrong.

### 3. JSON schema (fixed per line)

```json
{
  "ts":              "<RFC3339 UTC>",
  "event":           "charge" | "charge_idempotent",
  "payment_id":      "<uuid>",
  "idempotency_key": "<string>",
  "amount_minor":    <int64>,
  "currency":        "<string>",
  "customer_id":     "<string>",
  "psp_status":      "<string>",
  "psp_ref":         "<string>",
  "latency_ms":      <int64>
}
```

`event="charge"` is written after `tx.Commit()` on a new payment.
`event="charge_idempotent"` is written at the idempotency-check early-return,
recording the replay without double-counting the money.

### 4. No per-write fsync this week

Each write is `O_APPEND` to the open file. No `fsync` is called per line. The
durable backstop is the Postgres transaction — the ledger entry is already
committed before the audit line is attempted. Per-write fsync would add latency
to every charge path; that trade-off is deferred.

### 5. Handler is stored at package level for Day 10 SIGHUP reopen

`txLogWriter *auditWriter` is package-level so the signal handler added in
ADR-010 (log rotation) can close the old file and open the new one without
re-initialising the entire logger.

---

## Alternatives rejected

| Alternative | Reason rejected |
|---|---|
| journald-only | Not queryable as a structured audit file; journald vacuums independently of audit-retention requirements |
| Postgres audit table | Couples audit growth to the ledger DB; adds write amplification on every charge; defeats the purpose of exercising the filesystem this week |
| Per-write fsync | Latency cost on the hot charge path; DB commit is already the durable backstop |
| Async goroutine write | Adds ordering complexity; a buffered channel drop under ENOSPC would silently lose lines with no journald signal |
| Fail the charge on audit error | Violates financial correctness: a logging failure is not a payment failure |

---

## Consequences

- A charge with a misconfigured `TRANSACTION_LOG_PATH` still succeeds; the
  operator learns from the startup ERROR in journald, not from a customer 500.
- Under ENOSPC the audit trail has gaps; the Postgres ledger is the authoritative
  record. INC-006 (Day 9) will demonstrate this gap and ADR-010 will close it
  with rotation + retention.
- `TRANSACTION_LOG_PATH` is an escape hatch for dev/test environments (e.g.,
  WSL2 writing to `/tmp/novapay-audit/`). It must not be set in deployed config
  — the deployed default `/var/log/novapay/transactions.log` is the correct path.
