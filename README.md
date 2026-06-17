# NovaPay SRE Lab

A self-built payments platform used as a structured learning environment for SRE, DevOps, and Platform Engineering. Not a clone, not a tutorial project — every line was written from scratch so that every postmortem, design decision, and failure mode can be explained from the code that was actually written. The goal is a platform that can be broken deliberately and hardened deliberately, with a public record of what failed, what was built to stop it, and why each decision was made.

The project follows a build-first philosophy: correctness first, hardening second, specialisation after a Week-20 decision checkpoint where SRE / DevOps / Platform Engineering is chosen from experience rather than assumed up front. The double-entry accounting ledger is the correctness foundation — every payment writes exactly two balanced rows (one debit, one credit) in a single database transaction. The invariant (`sum(debits) == sum(credits)` per payment) is verifiable at any point with a single SQL query. If that query returns rows, money is out of balance. Through all of Week 1, it has returned zero rows.

---

## Architecture

```
WSL2 (build box)
  │  go build → binary
  │  ansible-playbook deploy.yml
  │
  └──► EC2 t3.micro (runtime)
         │
         ├── payment-api  :8080  (systemd: payment-api.service)
         │     ├── GET  /healthz  → {"status":"ok","goroutines":N}
         │     └── POST /charge   → idempotency check → PSP → DB transaction
         │
         ├── fake-psp     :8081  (systemd: fake-psp.service)
         │     └── POST /authorize
         │           knobs: PSP_LATENCY_MS · PSP_ERROR_RATE · PSP_HANG
         │
         └── PostgreSQL (local on EC2)
               └── double-entry ledger
                     accounts · payments · ledger_entries
```

Both services are managed by systemd (`Restart=on-failure`), deployed via a single Ansible command, and log structured JSON to journald.

---

## What was built (Week 1)

| Component | What it does | Key property |
|---|---|---|
| `payment-api` | `GET /healthz`, `POST /charge` | Idempotency via `UNIQUE(idempotency_key)`; atomic ledger writes in one transaction |
| `fake-psp` | `POST /authorize` + failure knobs | `PSP_LATENCY_MS`, `PSP_ERROR_RATE`, `PSP_HANG` — controllable failure injection |
| PostgreSQL schema | `accounts`, `payments`, `ledger_entries` | Invariant query; `ON CONFLICT DO NOTHING` for seed idempotency |
| systemd units | Both services managed | `Restart=on-failure`, `SyslogIdentifier`, reboot-safe via `WantedBy=multi-user.target` |
| Ansible deploy | WSL2 build → EC2 deploy | One command, idempotent, `delegate_to: localhost` for local binary build |

---

## Week 1 hardening

Three failure modes observed forensically, then eliminated by design:

| Day | Failure mode defended against | Defence built | Commit |
|---|---|---|---|
| D4 | Retry storm / thundering herd | Bounded retry (max 3), full-jitter exponential backoff, HTTP 5xx only — failed charges never touch the DB | `2eef3e9` |
| D5 | Zombie process accumulation / PID exhaustion | In-process goroutine receipt worker (buffered channel, SIGTERM drain) — no child processes structurally possible | `a68b831` |
| D6 | Silent goroutine pile-up / liveness ≠ healthy | `context.WithTimeout(5s)` on PSP call + `http.Client{Timeout:6s}` backstop; goroutine count in `/healthz` | `c8be95e` |

Each failure was observed first — goroutine pile-up made visible via `/healthz`, zombie accumulation confirmed 1:1 via `ps -el | awk '$2=="Z"'`, retry storm documented with PSP call counts — before the fix was built. The day notes and GitHub Issues (INC-003, INC-004, INC-005) record the forensic detail.

---

## The agentic workflow

The build environment uses Claude Code CLI with a `CLAUDE.md` project intelligence file that provides session context, coding conventions, and architectural constraints. The workflow is operator-supervised, not autonomous — Claude Code coordinates, humans approve deploys.

**Custom commands (10+):**
`/check`, `/deploy-dry-run`, `/deploy`, `/ec2-status`, `/ec2-logs`, `/ec2-invariant`, `/load-test`, `/write-note`, `/generate-questions`, `/new-adr`, `/day-start`, `/commit`

**Hooks:**
- `PreToolUse`: blocks `ansible-playbook` without `--check` (exit 2) — no autonomous deploys
- `PostToolUse`: logs every Bash command to `~/.claude/novapay-activity.log`

**The 4-step deploy gate:**
```
/check  →  /deploy-dry-run  →  manual deploy  →  /ec2-invariant
```
`/check` validates: code compiles, go vet passes, local invariant holds.
`/deploy-dry-run` validates: correct files going to correct paths on EC2 (copy tasks only — shell tasks are silent in check mode by design).
Manual deploy: humans run `ansible-playbook`; the PreToolUse hook blocks Claude Code from doing it autonomously.
`/ec2-invariant`: queries EC2 Postgres directly — confirms the ledger is balanced post-deploy.

**MCP integrations:**
- Postgres MCP: direct dev database queries in-session
- GitHub MCP: issue + PR workflow (INC-003, INC-004, INC-005 opened and closed without leaving Claude Code)

**7 Architecture Decision Records** in `docs/decisions/` — from the double-entry ledger choice to the full-jitter retry strategy. Each ADR documents the decision, the context, the alternatives considered, and the rationale.

---

## Architecture decisions

Seven significant design decisions are documented as ADRs — from the double-entry ledger choice to the full-jitter retry strategy. See [`docs/decisions/`](docs/decisions/) for the full set.

Key constraints: the double-entry ledger is permanent (ADR-001); `pgx/v5` with `pgxpool` only, no `database/sql` shim (ADR-002); idempotency enforced at the DB layer via `UNIQUE` constraint, not application code alone (ADR-003); full jitter retry, not equal jitter (ADR-004); side effects in-process goroutines, never `exec.Command` (ADR-005); two timeout layers on PSP calls (ADR-006); discipline undecided until Week 20 (ADR-007).

---

## What's next

**Week 2:** filesystems, disk, and memory — structured transaction logging that writes a log entry per charge to `/var/log/novapay/transactions.log`, log rotation and retention so a busy day cannot fill `/`, and memory limits on systemd units so the ledger writer degrades predictably under memory pressure rather than being killed at random. Publish angle: "Designing a payments box that can't fill its own disk."

**Week 20 Decision Checkpoint:** SRE / DevOps / Platform Engineering is chosen after operating the full stack — not assumed up front. The chosen lane sets the spine of Weeks 21–34 and determines whether break-on-purpose chaos becomes the model or whether the scope expands toward developer platforms.

---

## Running locally

```bash
# Prerequisites: Go 1.24.3, PostgreSQL, fake-psp running on :8081

# Apply schema (first time)
psql postgresql://novapay:novapay@localhost:5432/novapay -f app/payment-api/schema.sql

# Start payment-api
cd app/payment-api && go run .

# Test a charge
curl -s -X POST localhost:8080/charge \
  -H "Content-Type: application/json" \
  -d '{"idempotency_key":"test-001","amount_minor":1000,"currency":"CAD","customer_id":"cust-1"}'

# Verify idempotency (same key — should return same payment_id, no new DB rows)
curl -s -X POST localhost:8080/charge \
  -H "Content-Type: application/json" \
  -d '{"idempotency_key":"test-001","amount_minor":1000,"currency":"CAD","customer_id":"cust-1"}'

# Verify the invariant (must return 0 rows — any row means money is out of balance)
psql postgresql://novapay:novapay@localhost:5432/novapay -c "
SELECT payment_id,
  SUM(CASE WHEN direction='debit'  THEN amount_minor ELSE 0 END) AS debits,
  SUM(CASE WHEN direction='credit' THEN amount_minor ELSE 0 END) AS credits
FROM ledger_entries GROUP BY payment_id
HAVING SUM(CASE WHEN direction='debit'  THEN amount_minor ELSE 0 END) !=
       SUM(CASE WHEN direction='credit' THEN amount_minor ELSE 0 END);"

# Check goroutine count (elevated count signals a hung dependency)
curl -s localhost:8080/healthz
```

---

## Deploy to EC2

```bash
# Dry-run first — see what would change (never skip this)
ansible-playbook -i infrastructure/ansible/inventory.ini \
  infrastructure/ansible/deploy.yml --check --diff

# Deploy (builds binaries locally, copies to EC2, restarts services)
ansible-playbook -i infrastructure/ansible/inventory.ini \
  infrastructure/ansible/deploy.yml
```
