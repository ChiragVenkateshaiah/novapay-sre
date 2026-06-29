# NovaPay

A self-built payments platform engineered to be **broken on purpose and hardened on purpose** — every failure mode is observed forensically, defended in code, and recorded as a public incident. Not a CRUD portfolio app, not a clone, not a tutorial: a correctness-first system whose value is the postmortem trail, not the feature list.

---

## What this is

NovaPay is a minimal, production-shaped payments core — `payment-api`, a controllable fake bank, and a real double-entry PostgreSQL ledger — used as a structured learning environment for systems, reliability, and platform engineering. Every line was written from scratch so that every design decision, failure mode, and postmortem can be explained from code that was actually authored here, not inherited from a framework. The correctness foundation is the double-entry ledger: each charge writes exactly two balanced rows (one debit, one credit) inside a single database transaction, and the invariant `sum(debits) == sum(credits)` per payment is verifiable at any moment with one SQL query. If that query returns a row, money is out of balance. It has returned zero rows through every day so far.

The foundation is **discipline-neutral by design**. SRE, DevOps, and Platform Engineering are not assumed up front — they are chosen at a **Week-20 Decision Checkpoint**, from the experience of operating the full stack rather than from a label picked on day one (ADR-007). Weeks 1–20 are the common core: build for correctness, depth-first, and study failure modes only to harden against them.

The repository name carries `-sre` for continuity only — it is a **label, not a discipline commitment**. This project was originally scoped as an SRE "war room" of staged outages; it was deliberately replanned. The former planned incidents (runaway CPU, zombie processes, stuck payments) became **Week-1 hardening tasks** — defences built in, not chaos manufactured for its own sake. Break-on-purpose chaos returns post-checkpoint, primarily if the SRE lane is chosen. Until then, every timeout, retry cap, rotation policy, and memory bound exists to make the system provably safe under a specific failure.

---

## Architecture

```
WSL2 (build box)
  │  go build → binary
  │  ansible-playbook deploy.yml   (--check dry-run gate enforced)
  │
  └──► EC2 t3.micro  (~911MB RAM, single root volume, zero swap)
         │
         ├── payment-api  :8080   systemd: payment-api.service
         │     ├── GET  /healthz   → {"status":"ok","goroutines":N}
         │     ├── POST /charge    → idempotency check → PSP call → DB txn → audit line
         │     └── (NOVAPAY_DEBUG=1 only) /debug/balloon  — RSS-growth probe, non-prod
         │     [MemoryHigh=128M · MemoryMax=192M · OOMScoreAdjust=+200 · StartLimitBurst=5]  ← payment-api
         │
         ├── fake-psp     :8081   systemd: fake-psp.service
         │     └── POST /authorize
         │           knobs: PSP_LATENCY_MS · PSP_ERROR_RATE · PSP_HANG
         │     [MemoryHigh=64M · MemoryMax=96M · OOMScoreAdjust=+500 · StartLimitBurst=5]   ← fake-psp (stub, dies first)
         │
         ├── PostgreSQL (local on EC2)
         │     └── double-entry ledger: accounts · payments · ledger_entries
         │
         └── Disk discipline
               ├── /var/log/novapay/transactions.log   (dedicated audit stream)
               ├── logrotate  (size 50M, rotate 7, compress, SIGHUP-reopen)
               └── journald    SystemMaxUse=200M cap
```

Both services run under systemd (`Restart=on-failure`, `RestartSec=5s`, reboot-safe via `WantedBy=multi-user.target`), are deployed by a single Ansible command, and log structured JSON to journald. The audit log is a separate, resilient file stream from operational journald logs (ADR-009).

---

## What's built

| Component | What it does | Key property |
|---|---|---|
| `payment-api` | `GET /healthz`, `POST /charge` | Idempotency via `UNIQUE(idempotency_key)`; payment row + both ledger entries committed in **one** transaction; goroutine count exposed in `/healthz` |
| `fake-psp` | `POST /authorize` + failure knobs | `PSP_LATENCY_MS`, `PSP_ERROR_RATE`, `PSP_HANG` — deterministic failure injection |
| PostgreSQL schema | `accounts`, `payments`, `ledger_entries` | Invariant query; `direction` CHECK constraint (`debit`/`credit`); `ON CONFLICT DO NOTHING` seed idempotency |
| Bounded PSP retry | Max 3 attempts, HTTP 5xx only, full-jitter backoff | Exhausted retries return 503 with the DB transaction never opened — invariant guaranteed on the failure path (ADR-004) |
| PSP timeout layers | `context.WithTimeout(5s)` + `http.Client{Timeout:6s}` | Two independent deadlines; hung dependency returns `DeadlineExceeded`, goroutines drain, zero DB rows on timeout (ADR-006) |
| Receipt worker | Buffered channel + single in-process goroutine, SIGTERM drain | Zero child processes structurally possible — no `exec.Command`, no zombies (ADR-005) |
| Audit log | One JSON line per charge to `/var/log/novapay/transactions.log` | `auditWriter` surfaces `ENOSPC`/write errors to journald as ERROR and **never fails the charge** — charge returns 200, ledger commits (ADR-009) |
| Log rotation | logrotate: `size 50M`, `rotate 7`, `compress`, `delaycompress` | SIGHUP-reopen (not `copytruncate`) — `RWMutex`-guarded fd swap, **zero audit lines lost across a rotation**, verified on EC2 (ADR-010) |
| journald cap | `SystemMaxUse=200M` drop-in | Bounds the second independent disk-fill vector; combined worst case ≈302M ≪ 2.8G free — root structurally protected (ADR-010) |
| systemd memory limits | `MemoryHigh/MemoryMax` per service, `OOMScoreAdjust` (fake-psp=500, payment-api=200), `StartLimitBurst=5` | Two-stage cgroup-v2 containment: soft throttle then hard cgroup-scoped OOM kill; three-tier kill ordering (fake-psp → payment-api → Postgres) ensures stub dies before charge processor, ledger survives longest; crash-loop guard stops infinite restart thrash (ADR-011) |
| systemd units | Both services managed | `Restart=on-failure`, `SyslogIdentifier`, start-on-boot |
| Ansible deploy | WSL2 build → EC2 deploy | One idempotent command; `delegate_to: localhost` for the local binary build; ships binaries, schema, unit files, logrotate + journald config |

---

## Incidents — engineered, observed, resolved

Each incident is a failure mode reproduced under controlled, bounded conditions, observed forensically, then closed by a defence built in code or infrastructure. Every entry links to a real GitHub issue with the full observation, root cause, and acceptance criteria.

| Incident | Failure mode | Defence built | Issue | Status |
|---|---|---|---|---|
| INC-003 | Naive PSP retry busy-spins → CPU meltdown under partial failure | Bounded retry: 3 attempts, exponential backoff + **full jitter** (ADR-004) | [#1](https://github.com/ChiragVenkateshaiah/novapay-sre/issues/1) | ✅ Closed |
| INC-004 | Shell-out receipt generation accumulates zombie processes → PID exhaustion | In-process goroutine worker, SIGTERM drain, zero forks (ADR-005) | [#2](https://github.com/ChiragVenkateshaiah/novapay-sre/issues/2) | ✅ Closed |
| INC-005 | No PSP timeout → goroutines pile up silently; liveness ≠ healthy | `context.WithTimeout(5s)` + `http.Client{Timeout:6s}`; goroutine count in `/healthz` (ADR-006) | [#4](https://github.com/ChiragVenkateshaiah/novapay-sre/issues/4) | ✅ Closed |
| INC-006 | Audit-log filesystem fills → `ENOSPC` on every write | Resilient `auditWriter` (charge still 200); logrotate + SIGHUP-reopen + journald cap (ADR-009, ADR-010) | [#5](https://github.com/ChiragVenkateshaiah/novapay-sre/issues/5) | ✅ Closed |
| INC-007 | Memory balloon → OOM kill; system-wide killer could pick Postgres | cgroup-v2 `MemoryMax/MemoryHigh` per-service caps scope the kill to the app's own cgroup; three-tier `OOMScoreAdjust` ordering (fake-psp=500 > payment-api=200 > Postgres=0) ensures stub dies first, ledger last; `StartLimitBurst=5` stops crash-loop thrash. Baked into committed unit files as IaC (ADR-011) | [#6](https://github.com/ChiragVenkateshaiah/novapay-sre/issues/6) | ✅ Closed |

---

## Architecture Decision Records

**13 ADRs** in [`docs/decisions/`](docs/decisions/), each documenting the decision, context, alternatives considered, and rationale:

- **ADR-001** — double-entry ledger, never a single balances table
- **ADR-002** — `pgx/v5` + `pgxpool`, never `database/sql` + `lib/pq`
- **ADR-003** — idempotency enforced at the DB layer (`UNIQUE`), not app-only
- **ADR-004** — retry backoff uses full jitter, never equal jitter
- **ADR-005** — side effects as in-process goroutines, never `exec.Command`
- **ADR-006** — PSP calls carry two timeout layers (context deadline + HTTP client)
- **ADR-007** — discipline (SRE/DevOps/Platform) undecided until the Week-20 checkpoint
- **ADR-008** — Terraform deferred to Phase 4; EC2/SG/key-pair stay manual + Ansible
- **ADR-009** — audit log is a dedicated, resilient file stream separate from journald
- **ADR-010** — log rotation + retention: size-based, 7 compressed generations, SIGHUP-reopen, journald cap
- **ADR-011** — systemd memory-limit strategy: `MemoryHigh/MemoryMax` two-stage containment, `OOMScoreAdjust` ordering to protect Postgres, crash-loop backoff
- **ADR-012** — no meta-harness; a single Claude Code CLI agent is the workflow ceiling
- **ADR-013** — pre-flight checks are deterministic shell guards, not LLM subagents (port 22 ≠ port 8080 reachability)

---

## The agentic workflow

The build runs on **Claude Code CLI**, with [`CLAUDE.md`](CLAUDE.md) as a committed project-intelligence file read at the start of every session — it carries architecture, coding conventions, and the locked architectural constraints (the ADR list above) so context never resets to zero. The workflow is **operator-supervised, not autonomous**: Claude Code coordinates, the human approves every deploy.

**16 custom commands** in [`.claude/commands/`](.claude/commands/):
`/check` · `/deploy-dry-run` · `/deploy` · `/ec2-status` · `/ec2-logs` · `/ec2-invariant` · `/ec2-tx` · `/tail-tx` · `/test-charge` · `/load-test` · `/write-note` · `/generate-questions` · `/new-adr` · `/day-start` · `/commit` · `/update-readme`

**Hooks** (`.claude/hooks/`):
- `PreToolUse` — blocks any `ansible-playbook` without `--check` (exit 2). No autonomous production deploys are structurally possible.
- `PostToolUse` — logs every Bash command to `~/.claude/novapay-activity.log` and, after a real deploy, prints a reminder to verify the invariant.

**The human-approval deploy gate (4 steps, in order):**
```
/check  →  /deploy-dry-run  →  manual ansible-playbook (human runs it)  →  /ec2-invariant
```
`/check` validates code compiles, `go vet` passes, and the local invariant holds. `/deploy-dry-run` shows exactly which files land at which paths on EC2. The real deploy is run by a human — the PreToolUse hook blocks Claude Code from running it. `/ec2-invariant` queries EC2's Postgres directly to confirm money is still balanced after the deploy.

**The GitHub-issue-driven incident lifecycle:** observe the failure → open a GitHub issue with the forensic detail and acceptance criteria (via GitHub MCP) → build the defence → close the issue from the commit that ships it. INC-003 through INC-007 were all opened and managed this way without leaving the session.

**MCP integrations:** Postgres MCP (direct dev-database queries in-session) and GitHub MCP (issue + PR workflow).

---

## Tech stack

- **Language:** Go 1.25 (`payment-api`), Go 1.24 (`fake-psp`) — standard library preferred, `log/slog` for logging
- **DB driver:** `pgx/v5` with `pgxpool` (ADR-002)
- **Database:** PostgreSQL (local on WSL2 for dev; local on EC2 for deploy)
- **Process management:** systemd (units with cgroup-v2 memory limits)
- **Disk discipline:** logrotate + journald `SystemMaxUse`
- **Provisioning / deploy:** Ansible (Terraform deferred to Phase 4, ADR-008)
- **Runtime:** single EC2 t3.micro
- **Tooling:** Claude Code CLI + MCP (Postgres, GitHub)

---

## Running locally

```bash
# Prerequisites: Go 1.25, PostgreSQL, fake-psp running on :8081

# Apply schema (first time)
psql postgresql://novapay:novapay@localhost:5432/novapay -f app/payment-api/schema.sql

# Start fake-psp (in its own terminal)
cd app/fake-psp && go run .

# Start payment-api
cd app/payment-api && go run .

# Test a charge
curl -s -X POST localhost:8080/charge \
  -H "Content-Type: application/json" \
  -d '{"idempotency_key":"test-001","amount_minor":1000,"currency":"CAD","customer_id":"cust-1"}'

# Verify idempotency (same key → same payment_id, no new DB rows)
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

# Health + goroutine count (elevated count signals a hung dependency)
curl -s localhost:8080/healthz

# Tail the local audit log (set TRANSACTION_LOG_PATH=/tmp/novapay-tx.log when running locally)
tail -f "${TRANSACTION_LOG_PATH:-/tmp/novapay-tx.log}" | jq .
```

---

## Deploying

```bash
# 1. Dry-run first — see exactly what would change (never skip; the hook enforces it)
ansible-playbook -i infrastructure/ansible/inventory.ini \
  infrastructure/ansible/deploy.yml --check --diff

# 2. Deploy — builds binaries locally on WSL2, copies to EC2, ships unit files +
#    logrotate + journald config, applies schema, restarts services
ansible-playbook -i infrastructure/ansible/inventory.ini \
  infrastructure/ansible/deploy.yml

# 3. Verify the EC2 ledger is balanced after the deploy
#    (/ec2-invariant inside Claude Code, or query EC2 Postgres directly)
```

---

## What's next

- **Day 13 — Integration:** clean redeploy from committed repo + 5-stage failure gauntlet (`scripts/gauntlet-week02.sh`, per-stage PASS/FAIL) + Week-2 article draft.
- **Day 14 — Publish + checkpoint + Week-3 handoff.**
- **Week-20 Decision Checkpoint:** choose SRE / DevOps / Platform Engineering from operating experience — the chosen lane sets the spine of Weeks 21–34 and decides whether break-on-purpose chaos becomes the model.

---

## Status

**Phase 1 · Week 2 (Filesystems, disk, memory) · Days 1–12 complete, Day 13 next · discipline-neutral foundation.** Last updated 2026-06-28.

---

Repo: [github.com/ChiragVenkateshaiah/novapay-sre](https://github.com/ChiragVenkateshaiah/novapay-sre) · No license (all rights reserved) · Built with Claude Code.
