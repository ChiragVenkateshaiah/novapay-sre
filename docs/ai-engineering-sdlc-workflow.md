# AI Engineering Workflow — Development, Staging & Production
**Reference document · Created during NovaPay Phase 1, Week 1**
_Read this whenever you have doubts about which AI tooling is appropriate at which stage._

---

## The core principle (read this first)

> **Claude Code is the investigator and proposer. The safety layer — read-only credentials, Ansible, human approval — is what changes by environment. The skill is portable. The autonomy is not.**

You build one investigation mindset. You apply it with different permission boundaries at each stage. Nothing you learn in development has to be unlearned — it just gets an additional approval layer as data becomes real.

---

## The data lifecycle — what actually lives where

A common misconception: "I might need to query real data during development." In practice:

```
DEVELOPMENT          STAGING                   PRODUCTION
────────────         ──────────────────────    ──────────────────────────
Synthetic data        Anonymised prod copy      Real customer data
You generate it       PII stripped / hashed     PII, real money, real users
No real users         Realistic volume          Real transactions
Zero risk             Controlled risk           Maximum protection
```

**Development:** You write code against data you create yourself (test payments, fake UUIDs, synthetic amounts). No real customer ever touches this database. This is the NovaPay ledger on your WSL2 machine right now.

**Staging:** A copy of production with PII removed. Real schemas, real data volume, realistic failure patterns — but customer names are hashed, card numbers are masked, amounts are fuzzed. Engineers can investigate production-like behaviour without exposing real customer data.

**Production:** Real customer data. First time real data appears in the system. Every interaction here has financial and legal consequences.

**The implication:** you will never have real customer data on your development machine. The question "how do I use Claude with production data" is about production operations — not development workflow. Those are different problems solved differently.

---

## AI Engineering at each stage

### Stage 1 — Development

**What exists here:** synthetic data, your local database, no real users.

**AI capabilities:** full access. Claude Code can connect to the database directly, write arbitrary queries, explore the schema dynamically, and propose or execute changes autonomously. Nothing is at risk.

**MCP setup:** Postgres MCP with full application credentials. GitHub MCP for PR workflow. All custom commands.

**When to use Postgres MCP over custom commands:**
- Dynamic multi-step investigation: "why did this query plan change?" — Claude writes one query, reads the result, writes another based on it
- Schema exploration: Claude needs to understand table structure before generating a migration
- Unexpected data state: something looks wrong, you need to explore freely without knowing the right query upfront

**When to use custom commands instead:**
- Routine, predictable checks (invariant query, payment counts)
- Any operation that is fixed and repeatable
- Anything you will run more than once

**The rule:** if you know exactly what query you need, write a custom command. If you don't know yet and need to explore, MCP earns its place.

**Claude Code autonomy level:** high. It can read, write, and explore freely. You review code before committing; you don't need to approve every database query.

---

### Stage 2 — Staging

**What exists here:** anonymised production data. Real schemas, real volume, PII removed.

**AI capabilities:** read-only database access. Claude Code can investigate production-like data states dynamically — this is its most powerful legitimate use case. It cannot write to the database.

**How to set this up — the read-only Postgres user:**

```sql
-- Run this once on your staging database
CREATE USER claude_readonly WITH PASSWORD 'a-strong-password-here';
GRANT CONNECT ON DATABASE novapay TO claude_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO claude_readonly;
-- Explicitly deny write operations (belt and braces)
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON ALL TABLES IN SCHEMA public FROM claude_readonly;
```

**MCP connection string for staging:**
```
postgresql://claude_readonly:password@staging-host:5432/novapay
```

The application uses its own credentials for writes. Claude Code uses `claude_readonly` — reads only, always.

**Claude Code autonomy level:** investigation only. Claude reads and proposes; you approve and execute changes. It can tell you "this payment failed because the account ID lookup returned null" — you decide what to fix.

**NovaPay timeline:** this pattern arrives in Week 7 when the ledger moves to RDS. At that point, create a `claude_readonly` user on RDS and point any exploratory tooling there.

---

### Stage 3 — Production

**What exists here:** real customer data, real transactions, real money.

**The wrong mental model:** "AI cannot touch production."
**The right mental model:** "AI must not have uncontrolled write access to production. Controlled read access with the right architecture is a standard industry pattern."

Four patterns, in order of increasing access level:

---

#### Pattern 1 — Ansible ad-hoc (what NovaPay already has)

Claude Code never connects to the production database directly. It runs Ansible commands which SSH into EC2 and run pre-approved operations.

```
Claude Code → runs bash
  └── ansible -i inventory.ini novapay -m command \
        -a "journalctl -u payment-api --since '10 minutes ago'"
```

This is what `/ec2-status`, `/ec2-logs`, and `/ec2-invariant` do. The operations are:
- Scoped (pre-defined commands, not arbitrary)
- Audited (Ansible logs everything)
- Non-destructive (systemctl status, journalctl reads, psql SELECT)
- Safe for production

**Use for:** log investigation, service health checks, metrics, invariant checks. This is your primary production AI tooling and you have it already.

---

#### Pattern 2 — Read-only replica (investigation during incidents)

Many production databases support read replicas — a second database instance that receives all writes from the primary but only accepts reads. You connect Claude Code to the replica, never the primary.

```
Production primary    ──replicates──→    Read replica
(application writes)                     (Claude reads here)
     ↓                                        ↓
Real customer data                    Same data, read-only
```

**AWS RDS (your Week 7 setup)** supports read replicas natively. One checkbox in the console creates one. The replica gets its own endpoint.

Claude Code's Postgres MCP points to the replica endpoint with a read-only user. It can run arbitrary SELECT queries during an incident — "show me all payments in the last 10 minutes", "find charges where PSP status is null" — without any risk to the primary database or to write operations.

**Controls required before production use:**
- Read-only Postgres user (no INSERT, UPDATE, DELETE)
- Every query logged to an audit table (timestamp, query text, who ran it)
- Query complexity limits (no `SELECT *` with no WHERE on large tables)
- Automatic session expiry (30-minute windows for on-call sessions)

**Use for:** live incident investigation when you need dynamic SQL exploration on real data. On-call SRE work. Debugging production anomalies that staging couldn't reproduce.

---

#### Pattern 3 — Human-in-loop for production changes

For any change that modifies production — data corrections, configuration updates, deployments — the pattern is:

```
Claude Code:    investigates → generates proposal → explains rationale
You:            review the proposal
Claude Code:    executes AFTER your explicit approval
Production:     changes only after human confirmation
```

This is already implemented in your deploy workflow:
- `/deploy-dry-run` → Claude shows you what will change
- You review
- `/deploy` → Claude executes after you run it

Apply the same pattern to any production data change. Claude generates the corrective SQL; you review it; you run it (or approve Claude to run it). Claude never autonomously modifies production data.

**Use for:** data corrections, schema migrations, configuration changes, anything that modifies production state.

---

#### Pattern 4 — Abstraction API (enterprise pattern)

Instead of direct database access, an internal API exposes approved operations:

```
Claude Code  →  POST /internal/api/query-payments  →  returns safe aggregate
              →  GET  /internal/api/invariant-check →  returns pass/fail
              →  GET  /internal/api/payment-status  →  returns safe summary
```

Claude never runs arbitrary SQL. It only calls approved endpoints that return safe, pre-defined results. No raw customer records ever leave the API layer. PII fields are never returned.

This is the pattern used at large fintechs (Stripe, Wise, etc.) where compliance requires that no tool — human or AI — can run arbitrary SQL against production customer data.

**NovaPay timeline:** Phase 5 (platform engineering) — when you build the golden path, baking safety into the default API layer is part of the platform design.

---

## How your muscle memory transfers across stages

You build one investigation workflow. The interface adapts; the skill doesn't change.

| Development habit | Production equivalent |
|---|---|
| Postgres MCP → run any query | Read replica MCP → same queries, same skill, read-only |
| Claude writes SQL freely | Claude writes SQL → you review → you (or Claude) run it |
| `/ec2-logs` to investigate | `/ec2-logs` via Ansible → identical command, same pattern |
| `/deploy-dry-run` → review → `/deploy` | Same exact pattern, now with a production database at stake |
| Claude explores data state dynamically | Claude proposes investigation steps → you approve each one |

Nothing you learn in development is wasted. The thinking pattern — "check logs, check metrics, query the data, correlate" — is identical across all three stages. What changes is the permission boundary, not the investigation mindset.

---

## NovaPay progression through the phases

| Phase | Database | Claude Code DB access | Pattern |
|---|---|---|---|
| Phase 1 (now) | Local Postgres on WSL2 | Full (synthetic data) | Dev MCP or custom commands |
| Phase 2, Wk 7 | AWS RDS | Read-only replica user | Staging pattern on production-like DB |
| Phase 2, Wk 9+ | RDS with CloudWatch | Ansible ad-hoc + read replica | Production Pattern 1 + Pattern 2 |
| Phase 5 | Full platform | Internal API abstraction | Production Pattern 4 |

The `/ec2-status`, `/ec2-logs`, `/ec2-invariant` custom commands you have right now are Pattern 1. They are already production-grade. You will use them unchanged from Week 1 through the final phase.

---

## Decision framework — which tool at which stage

```
Is the data synthetic (dev environment)?
  YES → MCP with full access is fine. Use it for exploration.
  NO  → Continue below.

Is the data anonymised (staging)?
  YES → MCP with read-only user. Explore freely. No writes.
  NO  → Continue below.

Is this a read operation or a write operation?
  READ  → Pattern 2 (read replica) with audit logging.
  WRITE → Pattern 3 (human-in-loop). Claude proposes. You approve. You execute.

Does compliance require no arbitrary SQL ever?
  YES → Pattern 4 (abstraction API). Build the safe endpoint first.
  NO  → Pattern 2 or 3 depending on read/write.
```

---

## The operations AI toolkit (safe at all stages)

These tools are safe in production because they operate through Ansible — a controlled, logged, non-destructive layer — not through direct database or service access:

| Command | What it does | Safe because |
|---|---|---|
| `/ec2-status` | systemctl status via Ansible | Read-only, Ansible logged |
| `/ec2-logs` | journalctl via Ansible | Read-only, no data exposure |
| `/ec2-invariant` | SELECT-only invariant query | Read-only psql, Ansible logged |
| `/deploy-dry-run` | Ansible --check (preview only) | No changes made |
| `/deploy` | Ansible deploy (hook-gated) | Human approval required first |

These commands are your production AI workflow. They work identically from Week 1 through the full production lifecycle. The investigation skill you build using them on your local EC2 is exactly the skill you will use when operating a real production system.

---

## Summary in one paragraph

In development you work with synthetic data and can use AI tools freely — full database access, dynamic queries, autonomous execution. In staging you work with anonymised production data via a read-only database user — Claude investigates freely but cannot write. In production, reads go through a read-only replica with audit logging; writes always require human review and approval before execution; and in compliance-sensitive environments, an abstraction API is the right layer. The investigation skill — using Claude Code to correlate logs, metrics, and data to find root cause — is identical at every stage. The permission boundary adapts; the engineering practice does not.

---

_Last updated: Phase 1, Week 1 · Revisit and extend when RDS is introduced (Week 7)_
