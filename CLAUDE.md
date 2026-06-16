# NovaPay — Project Intelligence

> This file is read by Claude Code at the start of every session.
> Keep it current. Stale context produces wrong output.

---

## What this project is

NovaPay is a self-built minimal payments platform used as a structured learning environment for SRE, DevOps, and Platform Engineering. It is not a toy — it is a production-like system with a real double-entry accounting ledger, real idempotency enforcement, and real failure modes.

**The project goal is not to ship features. It is to build and operate a correct system, then harden it.**

---

## Architecture

```
payment-api  (Go, port 8080)
    └── POST /charge    — idempotency check → PSP call → DB transaction
    └── GET  /healthz   — liveness check

fake-psp     (Go, port 8081)
    └── POST /authorize — controllable stub bank
    └── Knobs: PSP_LATENCY_MS, PSP_ERROR_RATE, PSP_HANG=true

PostgreSQL   (local on WSL2 for dev; local on EC2 for deploy)
    └── accounts, payments, ledger_entries
    └── Core invariant: per payment, sum(debits) == sum(credits)
```

---

## Current state

**Phase:** Phase 1 · Week 1 · Linux & Systems Foundations
**Discipline:** Deliberately undecided until Week-20 Decision Checkpoint (SRE / DevOps / Platform)

**Completed:**
- Day 1: WSL2 build env, EC2 provisioned via Ansible, services scaffolded
- Day 2: POST /charge, double-entry ledger, idempotency, structured slog logging

**Day 3 goal (next):** systemd unit files + Ansible deploy playbook
- Write `infrastructure/systemd/payment-api.service` and `fake-psp.service`
- Write `infrastructure/ansible/deploy.yml`: build binaries → copy to EC2 → install units → restart
- Verify on EC2: `systemctl status`, `journalctl -u payment-api`
- Record healthy baseline (normal CPU, latency, log cadence) in checkpoint.md

---

## Repository structure

```
novapay-sre/
├── CLAUDE.md                          ← you are here
├── CLAUDE.local.md                    ← personal overrides (gitignored)
├── .claude/
│   └── commands/                      ← custom slash commands
├── app/
│   ├── payment-api/
│   │   ├── main.go                    ← handlers, DB, PSP call
│   │   ├── schema.sql                 ← tables + seed + invariant query
│   │   ├── go.mod / go.sum
│   └── fake-psp/
│       ├── main.go                    ← /authorize + failure knobs
│       ├── go.mod / go.sum
├── infrastructure/
│   ├── ansible/
│   │   ├── inventory.ini              ← EC2 host + SSH key
│   │   ├── provision.yml              ← EC2 initial setup (already run)
│   │   └── deploy.yml                 ← Day 3: build + copy + restart
│   └── systemd/
│       ├── payment-api.service        ← Day 3: unit file
│       └── fake-psp.service           ← Day 3: unit file
├── monitoring/
├── postmortems/
├── runbooks/
├── scripts/
└── notes/                             ← gitignored, local working journal
    └── month-01/week-01/
        ├── learning-notes.md
        ├── day-01.md
        ├── day-02.md
        └── day-03-continuity.md
```

---

## Development workflow

```
Write / edit code    →  VS Code (Remote-WSL) or Claude Code
Build + test         →  WSL2 terminal (go build ./...)
Deploy to EC2        →  Ansible (ansible-playbook -i inventory.ini deploy.yml)
Debug on EC2         →  SSH + Neovim (on-box only)
```

**Dev database:** `postgresql://novapay:novapay@localhost:5432/novapay` (WSL2 local)
**Deploy database:** same DSN but on EC2 (provisioned by provision.yml)
**EC2 SSH:** `~/.ssh/sre-lab-key.pem`, user `ubuntu`, IP in `inventory.ini`

---

## Coding conventions

- **Go:** idiomatic, standard library preferred, no unnecessary abstractions
- **Errors:** always wrapped with `fmt.Errorf("context: %w", err)`
- **Logging:** `log/slog` only — no third-party logging libs
- **SQL:** plain positional params (`$1, $2`) in `VALUES(...)` — no subqueries inside VALUES
- **Transactions:** always `defer tx.Rollback(ctx)` immediately after `db.Begin(ctx)`
- **Context:** always pass `ctx` to every DB and HTTP call
- **PSP calls:** `context.WithTimeout(5s)` + `http.Client{Timeout:6s}` — see ADR-006

---

## Critical rules — read before every change

1. **The invariant is sacred.** Every charge must produce exactly 2 ledger entries summing to zero. Run `/check` after any change to the charge path.
2. **Scope ceiling.** Add code only if it deepens a core competency or serves the current day's goal. No payment features for their own sake.
3. **No framework magic.** The system is simple by design. Keep it simple.
4. **Financial correctness over speed.** When in doubt, do less, verify more.
5. **All DB writes for a charge go in one transaction.** Never split the payment row and ledger entries across separate transactions.
6. **Idempotency is enforced at the DB level** (`UNIQUE` constraint on `idempotency_key`), not just in application code.

---

## Architectural constraints (docs/decisions/)
These decisions are permanent unless an ADR explicitly supersedes them.
Propose changes that violate these only after reading the relevant ADR
and flagging the conflict explicitly.

- Never replace double-entry ledger with single balance table → ADR-001
- Always pgx/v5 with pgxpool, never database/sql + lib/pq → ADR-002
- Idempotency enforced at DB level (UNIQUE constraint), not app-only → ADR-003
- Retry backoff must use full jitter, never equal jitter → ADR-004
- Side effects (receipts, notifications) always in-process goroutines,
  never shell-out via exec.Command → ADR-005
- PSP calls must have two timeout layers: context deadline + HTTP client → ADR-006
- Discipline (SRE/DevOps/Platform) undecided until Week-20 checkpoint → ADR-007

---

## Key commands

```bash
# Build
cd app/payment-api && go build ./...
cd app/fake-psp    && go build ./...

# Run locally
go run .   # from each app directory

# Invariant check (must return 0 rows)
psql postgresql://novapay:novapay@localhost:5432/novapay -c "
SELECT payment_id,
  SUM(CASE WHEN direction='debit'  THEN amount_minor ELSE 0 END) AS debits,
  SUM(CASE WHEN direction='credit' THEN amount_minor ELSE 0 END) AS credits
FROM ledger_entries GROUP BY payment_id
HAVING SUM(CASE WHEN direction='debit' THEN amount_minor ELSE 0 END) !=
       SUM(CASE WHEN direction='credit' THEN amount_minor ELSE 0 END);"

# Test charge
curl -s -X POST localhost:8080/charge \
  -H "Content-Type: application/json" \
  -d '{"idempotency_key":"test-001","amount_minor":1000,"currency":"CAD","customer_id":"cust-1"}'

# Deploy to EC2
ansible-playbook -i infrastructure/ansible/inventory.ini infrastructure/ansible/deploy.yml

# EC2: check service status
systemctl status payment-api
journalctl -u payment-api -f

# Clear test data
psql postgresql://novapay:novapay@localhost:5432/novapay \
  -c "DELETE FROM ledger_entries; DELETE FROM payments;"
```

---

## Certs and learning context

- **Next cert:** AWS SAA (~Week 12)
- **Week-20 Decision Checkpoint:** choose SRE / DevOps / Platform Engineering
- **Foundation principle:** build for correctness, depth-first. Study failure modes to harden against them.
- **Content cadence:** one build/learning deep-dive published weekly (Fridays)

---

## Custom slash commands available

- `/check` — go build + go vet + invariant query
- `/deploy` — Ansible deploy to EC2
- `/test-charge` — run a test charge and idempotency check
- `/day-start` — print current day context from checkpoint.md
- `/commit` — stage, commit, and push with a message
