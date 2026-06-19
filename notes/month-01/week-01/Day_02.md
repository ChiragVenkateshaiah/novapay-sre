# Day 02 — Charge Path + Double-Entry Ledger + Idempotency
**Date:** 2026-06-05
**Phase:** Phase 1 · Week 1 · Linux & Systems Foundations
**Time spent:** ~3 hours

---

## Goal
Implement `POST /charge`: write a balanced double-entry ledger transaction, call `fake-psp`, enforce idempotency via a unique-key constraint, add structured JSON logging. Prove the invariant (debits == credits) holds by hand.

---

## What was actually built
- Postgres installed locally on WSL2 (dev target); EC2 Postgres already in place via Ansible
- `schema.sql`: `accounts`, `payments`, `ledger_entries` tables + seed data (`customer_funds`, `psp_clearing`)
- `POST /charge` implemented:
  - Idempotency: check `payments` for existing `idempotency_key`; return cached result immediately if found
  - New charge: resolve account IDs → call `fake-psp /authorize` → write `payments` + 2 `ledger_entries` in a single transaction → return result
  - Structured logging via `log/slog` (stdlib, Go 1.21+): `charge complete`, `charge idempotent`, all errors
- Dependencies added: `pgx/v5`, `pgx/v5/pgxpool`, `google/uuid`
- Invariant query confirmed: 0 rows returned (all payments balanced)
- Idempotency confirmed: same `idempotency_key` twice → same `payment_id` returned, `latency_ms=0` (no DB write)

---

## Key decisions made

**pgx/v5 over database/sql + lib/pq**
Using native pgx directly (not the `database/sql` shim) for the pool, connection management, and error types (`pgx.ErrNoRows`). More idiomatic for Postgres-first Go, and `pgxpool` handles connection pooling cleanly.

**Account IDs pre-fetched per charge (not subquery in INSERT)**
Originally tried `INSERT INTO ledger_entries ... SELECT $1, $2, id, $3, 'debit' FROM accounts WHERE name = 'customer_funds'`. This caused a pgx parameter binding issue (simple vs extended query protocol — see Problems section). Final approach: two `db.QueryRow` calls to resolve `custID` and `pspID` before the transaction, then plain `VALUES ($1, $2, $3, $4, 'debit')`. Cleaner and unambiguously correct.

**slog over log or zap/zerolog**
`log/slog` is in the standard library (Go 1.21+). Structured, no dependency, outputs JSON natively. Right call for the foundation — no third-party logging library for Week 1.

**Replace whole file over incremental edits for fixing broken code**
After several incremental Find & Replace edits in VS Code left the file in an inconsistent state, the right move was `Ctrl+A` → paste the complete corrected file. Lesson: when a file has multiple inconsistencies, a full replacement is faster and safer than surgical patches.

---

## Problems hit + resolutions

### 1. pgx dependencies not in go.mod
`go build` failed: `no required module provides package github.com/jackc/pgx/v5`.
- Fix: `go get github.com/jackc/pgx/v5 && go get github.com/jackc/pgx/v5/pgxpool && go mod tidy`
- Also caught a ghost import (`golang.org/x/text/currency`) from clipboard garbage — removed with `grep` then deleted in VS Code

### 2. INSERT...SELECT with positional parameters — pgx protocol mismatch
The original SQL pattern:
```sql
INSERT INTO ledger_entries (id, payment_id, account_id, amount_minor, direction)
SELECT $1, $2, id, $3, 'debit' FROM accounts WHERE name = 'customer_funds'
```
PostgreSQL returned: `ERROR: there is no parameter $1 (SQLSTATE 42P02)`

**Root cause:** SQLSTATE 42P02 means PostgreSQL received the query via **simple query protocol** (not extended/prepared statement). In simple protocol, `$N` are not recognised as parameter placeholders — they're just literal text. When pgx detects no args or has trouble with the INSERT...SELECT form, it can fall back to simple protocol.

**Fix:** pre-fetch account IDs into Go variables (`custID`, `pspID`) and use plain `VALUES ($1, $2, $3, $4)` — 4 positional parameters with direct values. No subquery inside the INSERT. pgx sends this as extended protocol reliably and PostgreSQL binds `$1–$4` correctly.

**Deeper lesson:** in pgx, always verify the SQL form you're using triggers extended (prepared statement) protocol. The clearest signal: if PostgreSQL says "there is no parameter $N," it received a simple query and never bound your args. The fix is always: simpler SQL, direct params, no subqueries inside VALUES.

### 3. VS Code Find & Replace mangling backtick SQL strings
When replacing multi-line SQL inside Go raw string literals (backticks), VS Code's Find & Replace dropped the closing backtick in two places:

Before (correct):
```go
`INSERT INTO ... VALUES (...)`,
    uuid.New().String(), paymentID, req.AmountMinor,
```

After bad replacement:
```go
`INSERT INTO ... VALUES (...),
    uuid.New().String(), paymentID, req.AmountMinor,
```

The closing backtick was lost. The raw string literal continued until the next backtick in the file, swallowing function arguments as string content. Go compiled fine (the string was syntactically valid, just wrong) but the credit INSERT received zero arguments → simple protocol → SQLSTATE 42P02.

**Fix:** targeted Find & Replace to add the missing backtick back between `)` and `,`. Then full file replacement to restore consistency.

**Lesson:** when making multiple edits to Go raw string literals in VS Code, verify closing backticks after every replacement. Or replace the whole function block in one shot.

### 4. Credit INSERT had no arguments at all
At one point the credit `tx.Exec` was called with no args:
```go
tx.Exec(ctx, `INSERT INTO ... VALUES ($1, $2, $3, 'credit')`)
// no args passed — pgx uses simple protocol — $1 rejected
```
The debit worked (had args); credit failed silently until the structured log caught it.

**Fix:** added `uuid.New().String(), paymentID, pspID, req.AmountMinor` as the 4 arguments.

**Lesson:** "mismatched param and argument count" is a pgx-side error (counts `$N` in SQL vs args provided). "there is no parameter $1" is a PostgreSQL-side error (received via simple protocol). The two errors tell you different things about where the mismatch happened.

---

## What I learned

**The invariant is the heart.** A payment that writes 1 debit and 1 credit in a single transaction is provably correct — the database can't commit a partial write. Running `SELECT ... HAVING debits != credits` and seeing 0 rows is a stronger guarantee than any unit test. This is what "build for correctness" means in a payments context.

**Idempotency at the DB layer beats idempotency in application code.** The `UNIQUE(idempotency_key)` constraint means even if two concurrent requests slip through the application-level check simultaneously, the DB will reject one of them. Defence in depth: check in app code AND enforce in the schema.

**pgx protocol behaviour matters.** Understanding *when* pgx uses simple vs extended query protocol is not an implementation detail — it directly affects correctness. Extended protocol = parameterised = safe. Simple protocol = no param binding = `$N` silently becomes literal text. Know which one you're getting.

---

## Commands worth keeping
```bash
# Create the NovaPay database and user
sudo -u postgres psql << 'EOF'
CREATE USER novapay WITH PASSWORD 'novapay';
CREATE DATABASE novapay OWNER novapay;
GRANT ALL PRIVILEGES ON DATABASE novapay TO novapay;
EOF

# Apply schema
psql postgresql://novapay:novapay@localhost:5432/novapay -f schema.sql

# Verify accounts seeded
psql postgresql://novapay:novapay@localhost:5432/novapay -c "SELECT * FROM accounts;"

# Run the invariant check (should return 0 rows)
psql postgresql://novapay:novapay@localhost:5432/novapay -c "
SELECT payment_id,
  SUM(CASE WHEN direction='debit'  THEN amount_minor ELSE 0 END) AS debits,
  SUM(CASE WHEN direction='credit' THEN amount_minor ELSE 0 END) AS credits
FROM ledger_entries GROUP BY payment_id
HAVING SUM(CASE WHEN direction='debit' THEN amount_minor ELSE 0 END) !=
       SUM(CASE WHEN direction='credit' THEN amount_minor ELSE 0 END);"

# Clear test data between runs
psql postgresql://novapay:novapay@localhost:5432/novapay \
  -c "DELETE FROM ledger_entries; DELETE FROM payments;"

# Check pgx error type in Go
# pgx.ErrNoRows  → no matching row (expected, not a real error)
# "mismatched param and argument count" → pgx-side: wrong number of $N vs args
# SQLSTATE 42P02 → PostgreSQL-side: received via simple protocol, $N not bound
```

---

## LinkedIn article notes
_Raw material — not polished. Pull from here when writing Day 7._

**The strongest technical angle from Day 2:**
The pgx protocol debugging story. Concrete, specific, rare. Most Go+Postgres tutorials don't explain WHY SQLSTATE 42P02 happens — they just say "use a prepared statement." The actual explanation (simple vs extended protocol, when pgx chooses which, what `$N` means in each) is valuable content.

**Hook ideas:**
- "My payment API returned `approved` but the ledger had 0 rows. Here's why." (the credit-missing-args scenario)
- "PostgreSQL said 'there is no parameter $1'. I had definitely passed $1. Here's what actually happened." (the simple vs extended protocol story)
- "The query that catches a broken payment system: one SQL check, 0 rows = all money accounted for."

**The invariant angle is strong:**
The line `(0 rows)` from the invariant query is genuinely satisfying. It proves correctness in a way that's immediately understandable to anyone who has worked on money systems. Lead with the proof, then explain how the double-entry structure makes it possible.

**What to avoid:**
- Tutorial-style "here's how to use pgx" — that's not the angle
- Over-explaining the accounting concepts — keep it engineering-focused

**Specific log lines worth including in the article:**
```
INFO charge complete payment_id=06860dd5... idempotency_key=test-001 amount_minor=1000 psp_status=approved latency_ms=399
INFO charge idempotent idempotency_key=test-001 payment_id=06860dd5... latency_ms=0
```
The `latency_ms=0` on the idempotent call is a great concrete detail — it shows the idempotency check short-circuits before any DB write.

---

## Handoff to Day 03
**Status:** Day 02 complete ✓
**Acceptance criteria met:**
- `POST /charge` returns `{"payment_id":"...","status":"approved"}`
- Same `idempotency_key` twice → same result, no new rows, `latency_ms=0`
- Invariant query returns 0 rows
- Payments count = 1, ledger = 1 debit + 1 credit at 1000

**Day 03 goal:** systemd unit files for both services + Ansible deploy playbook (`deploy.yml`). At the end of Day 03, `payment-api` and `fake-psp` must be running as managed services on EC2, deployed via a single Ansible command.

**What Day 03 starts with:**
1. Write systemd unit files in VS Code (on WSL2)
2. Write `infrastructure/ansible/deploy.yml`: build binaries → copy to EC2 → install unit files → daemon-reload → enable + start
3. Run playbook, verify on EC2 via `systemctl status` and `journalctl`
4. Test: kill a process, confirm systemd restarts it