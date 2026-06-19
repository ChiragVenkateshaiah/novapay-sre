# The Invariant That Never Broke: Week 1 of Building a Payments Platform to Learn It the Hard Way

There is one query I run after every single deploy. It is the first thing I check and the last thing I trust:

```sql
SELECT payment_id,
  SUM(CASE WHEN direction='debit'  THEN amount_minor ELSE 0 END) AS debits,
  SUM(CASE WHEN direction='credit' THEN amount_minor ELSE 0 END) AS credits
FROM ledger_entries
GROUP BY payment_id
HAVING SUM(CASE WHEN direction='debit'  THEN amount_minor ELSE 0 END) !=
       SUM(CASE WHEN direction='credit' THEN amount_minor ELSE 0 END);
```

It asks one question: is there any payment in this system where the money doesn't balance? Every charge writes exactly two ledger entries — a debit and a credit — and they must sum to zero. If this query ever returns a row, money has appeared or vanished, and the system is lying to me.

Across an entire week of deliberately breaking my own platform — retry storms, zombie processes, hung dependencies, three production-style incidents — **this query never returned a row.** Not once.

That is not because nothing broke. Plenty broke. It is because correctness lived in one transaction and one database constraint, and the failures I built happened *around* that core, never *through* it. That distinction — what can rot at the edges versus what must never move at the center — turned out to be the actual lesson of Week 1.

This is the honest write-up. The repo is public: **[github.com/ChiragVenkateshaiah/novapay-sre](https://github.com/ChiragVenkateshaiah/novapay-sre)**. Every incident below is a real GitHub issue you can read.

---

## The Pivot: Changing Direction Before Writing Line One

The original plan was an "SRE war room." Clone an existing repo, wire up instrumentation, break it, practice incident response. Resume-shaped. Clean.

I scrapped it before writing a single line.

The reasoning: choosing *SRE vs DevOps vs Platform Engineering* before you have ever operated a stack is like choosing a database engine before you understand your access patterns. You're optimizing against a workload you haven't met yet. And when you look closely, the three disciplines share the **same foundation** — Linux, networking, a real service, a real datastore, real failure modes. What separates them is *orientation*, not tooling. SRE orients toward reliability and toil reduction. DevOps toward delivery flow. Platform toward paved roads for other engineers. But they all stand on the same ground.

So I inverted it. Build a correct system first. Operate it. Break it. Harden it. Then, at a **Week-20 decision checkpoint**, choose the lane from *evidence* — from which kind of problem I actually reach for first — instead of guessing now and rationalizing later.

That decision is itself documented as an Architecture Decision Record (ADR-007), so future-me can't quietly forget why the discipline is undecided.

---

## The Foundation: Days 1–3

The system is deliberately small. Two Go services:

- **payment-api** (port 8080): `POST /charge` — idempotency check → call the bank → write to the ledger in one transaction. Plus `GET /healthz`.
- **fake-psp** (port 8081): a stub bank I fully control, with knobs: `PSP_LATENCY_MS`, `PSP_ERROR_RATE`, `PSP_HANG=true`. This is my failure injector.

Behind them, PostgreSQL with three tables: `accounts`, `payments`, `ledger_entries`. The core invariant — debits equal credits, per payment — is enforced by the schema and proven by that query above.

Simple to describe. Not simple to get right. Here is what actually happened.

### Go 1.22.2 was quietly winning

Builds behaved strangely. `where go` showed **two** binaries on the PATH. I had installed Go 1.24.3 by hand, but `apt` had its own `golang-go` (1.22.2) sitting earlier in the PATH and silently winning every invocation. I spent real time chasing version-specific behavior before realizing I wasn't even running the compiler I thought I was.

```bash
sudo apt remove golang-go
```

One line. But you can't fix what you haven't correctly identified, and "the wrong binary is shadowing the right one" is invisible until you stop trusting `go version` and start asking *which* `go`.

### The `$1` that PostgreSQL swore didn't exist

This one cost hours. My ledger insert used `INSERT ... SELECT` with positional parameters, and Postgres responded:

```
ERROR: there is no parameter $1 (SQLSTATE 42P02)
```

I *had* passed `$1`. I could see it. The database insisted it didn't exist.

Root cause, eventually: `INSERT ... SELECT` routed my query through the **simple query protocol**, where `$N` placeholders aren't bound parameters at all — they're treated as literal text the planner doesn't understand. The fix was to stop being clever: pre-fetch the account IDs into plain Go variables, then do a flat `INSERT ... VALUES ($1, $2, $3, $4)`.

```sql
-- not this (simple query protocol swallows $N)
INSERT INTO ledger_entries (...)
SELECT id, ... FROM accounts WHERE ...;

-- this (extended protocol, real bound params)
INSERT INTO ledger_entries (payment_id, account_id, direction, amount_minor)
VALUES ($1, $2, $3, $4);
```

That's now a hard coding rule in the project: **plain positional params in `VALUES(...)`, no subqueries inside `VALUES`.** Codified so I never re-learn it.

### A missing backtick that compiled fine

The worst kind of bug: the one with no error. VS Code's Find & Replace dropped the **closing backtick** off a Go raw string literal. The code compiled. `go build` was happy. But the unterminated-then-reterminated string had silently swallowed the next function's arguments into itself. No syntax error. No runtime panic. Just wrong behavior, with the toolchain cheerfully signing off.

The lesson stuck harder than any green test: *compiles* and *correct* are different claims, and only one of them is checkable by the compiler.

### Deploy reality on Day 3

Day 3 was systemd unit files plus an Ansible deploy pipeline to a real EC2 box. Three things bit me immediately:

1. **`community.postgresql` Ansible module failed** because `psycopg2` wasn't installed on EC2. I rewrote the Postgres setup as raw shell tasks guarded with `|| true` for idempotency. Less elegant, but it runs on the box as it actually exists, not as the module wishes it existed.

2. **The EC2 public IP changed on every start/stop.** My `inventory.ini` kept pointing at a dead address. I extended my `vm.sh` helper to auto-sync the current IP on every connect, so the inventory is never stale.

3. **A `--check` false positive that looked exactly like a real failure** — which deserves its own section below, because it taught me something about dry-runs.

---

## Three Incidents

This is the part that matters. Each one followed the same workflow: **open a GitHub issue first, reproduce, find root cause, fix, verify, close the issue with the commit.** Not optional. That *is* the incident process, even for a solo project — especially for a solo project, because the discipline is the point.

### INC-003 — The naive retry meltdown

**Issue: [#1](https://github.com/ChiragVenkateshaiah/novapay-sre/issues/1)**

I added retries to the PSP call. Seemed responsible — networks are flaky, retry the failures. I fired 10 charges with the PSP error rate cranked up.

All 10 charges returned `approved`. The ledger balanced. The invariant held. It *looked* completely correct.

It was not. I checked the PSP's call count: **10 charges had produced 23 authorize calls.** Under a 90% error rate, the math gets violent — my naive retry was issuing up to **10× the calls per charge**. Every retry hammered the bank harder precisely when the bank was already struggling. This is a retry storm: the textbook way a client turns a partial outage into a total one. The reason it looked fine is the most dangerous part — the *outcome* was correct, so nothing in the response or the ledger hinted at the amplification underneath.

The fix:
- **Bounded** retries — a hard cap, not "until it works."
- **Full jitter** backoff — randomized sleep so retries don't synchronize into thundering herds. (Full jitter, specifically — not equal jitter. That's ADR-004.)
- **Retry only 5xx** — server faults, never 4xx client errors, which won't improve on retry.

The jitter was observable in the logs — successive backoffs landing at **26ms, 82ms, 117ms, 290ms**. Spread, not lockstep. That's the whole point: a hundred clients retrying should *not* all wake up at the same millisecond.

**At scale:** unbounded retries against a degraded dependency are how a blip becomes an outage. The client amplifies the very failure it's reacting to.

### INC-004 — Zombie process accumulation

**Issue: [#2](https://github.com/ChiragVenkateshaiah/novapay-sre/issues/2)**

I had receipt generation shelling out to a child process via `exec.Command().Start()`. The receipts wrote correctly. The charges succeeded. The invariant held. Everything looked fine.

Then I ran:

```bash
ps -el | awk '$2 == "Z"'
```

**Fifteen rows.** Fifteen `<defunct>` processes — exactly one per charge. A perfect 1:1 with the work I'd done.

The cause: `.Start()` launches a child but I never called `.Wait()`. Without `.Wait()`, the child exits but the kernel keeps its process-table entry around so a parent that never asks can never reap it. Zombie. Each one holds a PID. The only signal anything was wrong was that `ps` output — no error, no log line, no failed charge.

The fix wasn't to add `.Wait()`. It was to **delete the child process entirely.** Receipts now generate in an in-process goroutine fed by a buffered channel. No `exec`, no fork, no child to reap. **Zero zombies, structurally impossible** — not "handled correctly" but *unreachable by construction*. That's now ADR-005: side effects run as in-process goroutines, never `exec.Command` shell-outs.

After the fix:

```bash
ps -el | awk '$2 == "Z"'   # zero rows
```

**At scale:** PIDs are finite. A service leaking one zombie per request is a slow countdown to PID exhaustion, at which point the box can't fork *anything* — and the metric that catches it is one almost nobody graphs.

### INC-005 — Liveness is not health

**Issue: [#3](https://github.com/ChiragVenkateshaiah/novapay-sre/issues/3)**

I set `PSP_HANG=true`. The fake bank now accepts connections and simply... never responds.

I hit the health endpoint:

```bash
curl -s localhost:8080/healthz
```

It answered in **11 milliseconds**: `{"goroutines":7,"status":"ok"}`. Healthy. Green. A load balancer would happily keep routing traffic here.

Meanwhile, real charges were hanging. Every request was blocking on the dead PSP, and each one parked a goroutine waiting forever. I watched the count climb: **7 → 27.** Zero errors logged. Zero work completed. The service was a corpse that could still pass its own pulse check, because `/healthz` only proved the process was *alive*, not that it could *do its job*.

This is the gap between **liveness** and **health**, and it's exactly how real systems get stuck in "everything's green but nothing works" outages.

Two fixes:

1. **Two timeout layers** on the PSP call — a `context.WithTimeout(5s)` *and* an `http.Client{Timeout: 6s}`. The context bounds the logical operation; the client bounds the transport. Layered, so a hang at either level gets cut. (ADR-006.)

   ```go
   ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
   defer cancel()
   client := &http.Client{Timeout: 6 * time.Second}
   ```

2. **Put the goroutine count in `/healthz` itself.** The pile-up was visible *without SSH-ing into the box* — the symptom now surfaces in the one endpoint everything already scrapes.

   ```json
   {"goroutines":7,"status":"ok"}    // healthy baseline
   {"goroutines":27,"status":"ok"}   // before fix: silent goroutine leak
   ```

**At scale:** a health check that only proves liveness will keep a brain-dead instance in the load-balancer pool, quietly black-holing traffic while the dashboard stays green.

---

## The `--check` False Positive

One more, because it's a different *kind* of lesson. Running the Ansible deploy in dry-run:

```bash
ansible-playbook --check --diff -i inventory.ini deploy.yml
```

It reported that the `payment-api` systemd service couldn't be found. That reads as a hard failure. My stomach dropped.

It wasn't real. In `--check` mode, the `copy` tasks *simulate* writing the unit file but don't actually write it — so the later `command`/`service` task that looks for that unit finds nothing, because in dry-run the file was never laid down. The "failure" was an artifact of the dry-run's own simulation: copy tasks report what they *would* do, while command tasks can't act on files that only *would* exist.

Knowing the difference between **"this will break"** and **"this is the dry-run lying to you about ordering"** is its own skill. Dry-runs are invaluable and also have sharp edges; you have to know which of your tasks the simulation can model honestly and which it can't.

---

## The Agentic Workflow: Claude Code as a Real Tool

I ran this entire week with **Claude Code** (Anthropic's CLI) as a genuine part of the toolchain — not autocomplete, not a novelty. What made it serious was the *guardrails I wired around it*, because an agent you can't constrain is an agent you can't trust near a deploy.

**Project intelligence loaded every session.** A `CLAUDE.md` file at the repo root holds the architecture, the coding conventions, the critical rules ("the invariant is sacred"), and the ADR constraints. Every session starts with that context, so the assistant operates *inside* my decisions instead of re-litigating them.

**A `PreToolUse` hook that physically blocks unsafe deploys.** This is the piece I'm proudest of. Before Claude Code runs *any* bash command, a hook inspects it. If it matches `ansible-playbook` **without** `--check`, the hook exits with code 2 — and the command is *blocked*. The agent literally cannot deploy to EC2 on its own. A human runs the real deploy, manually, every time. The safety isn't a promise from the model; it's enforced by the harness.

**A `PostToolUse` hook for the audit trail.** Every command Claude runs gets logged to `~/.claude/novapay-activity.log` with a timestamp. If I want to know what happened, I read the log, not my memory.

**10+ custom slash commands** that encode the routines: `/check` (build + vet + invariant), `/deploy-dry-run`, `/ec2-invariant`, `/load-test`, `/write-note`, `/generate-questions`, `/new-adr`. The repetitive, error-prone sequences become one word.

**7 Architecture Decision Records** in `docs/decisions/`. Every significant choice — double-entry ledger, `pgx/v5` over `database/sql`, DB-level idempotency, full jitter, in-process side effects, two-layer PSP timeouts, undecided discipline — is written down with context, the alternatives I rejected, and the consequences. The constraints are mirrored into `CLAUDE.md` so a future session *can't* casually violate a decision past-me made for a reason.

And the **deploy chain is non-negotiable**, enforced by hook and habit together:

```
/check  →  /deploy-dry-run  →  human runs Ansible  →  /ec2-invariant
```

Build clean. Preview the change. A human pulls the trigger. Verify money still balances. The agent accelerates every step except the one that touches production — and that's exactly the design.

---

## Why This Is a 12-Month Commitment

Week 1 produced two Go services, a deploy pipeline, three resolved incidents, seven ADRs, and an invariant that held through all of it. That's not the point. The point is what the failures taught:

- A retry that *looks* correct can be **amplifying** an outage.
- A service that *looks* healthy can be a **goroutine graveyard**.
- A process that *succeeds* can be leaking **zombies** toward PID exhaustion.
- "Compiles" and "the dry-run passed" are **claims about the tooling**, not the system.

Every one of those gaps is invisible until you go looking with the right command — `ps -el | awk '$2=="Z"'`, the goroutine count in `/healthz`, the PSP's call counter. Reliability isn't built by writing more features. It's built by knowing where the lies hide and instrumenting them into the open.

**Next:** push further into systemd hardening, structured deploy verification, and the first real metrics layer — moving from "I ran a command and looked" toward "the system tells me before I have to ask." Then more failure injection, because the failures are where the learning actually is.

And in roughly five months, at the **Week-20 checkpoint**, I'll choose the lane — SRE, DevOps, or Platform — from evidence about which problems I instinctively reach for, not from a guess I made before I'd ever operated the thing.

Twelve months. Depth-first. Correctness before speed.

The repo is open and the incidents are real: **[github.com/ChiragVenkateshaiah/novapay-sre](https://github.com/ChiragVenkateshaiah/novapay-sre)**

If you're an engineer who's debugged a green dashboard sitting on top of a dead service, you already know why the invariant matters. I'd genuinely like to hear which of these three you've hit in production.
