# NovaPay — Week 1 Plan (Phase 1: Linux & Systems Foundations)

> **Planned by:** Opus 4.8 · **Executed by:** Sonnet
> **Theme of the week:** Shell, processes & the first running service. Build a minimal, *correct*, concurrent payments core on one box, run it under systemd, and **harden it at the process boundary** against the failure modes a payments service must defend against — without staging outages.
> **Orientation (v2, build-first):** the deliverable each day is a robust, correct service — not an incident or a postmortem. You reproduce a failure mode only briefly, to *see what you're defending against*, then build the defense. (Break-on-purpose / chaos is a post-checkpoint, SRE-lane lens — not part of the foundation.)
> **Workflow:** **build & test on WSL2 → deploy to EC2 via Ansible.** WSL2 is the IDE/build box (Neovim, Go, local Postgres). EC2 is the runtime/deploy target. Deployment goes through Ansible, not hand-copying — this builds the platform-engineering muscle from day one.
> **How to use this file:** execute day by day, tick the boxes, and update `checkpoint.md` after each day (the continuity file Opus reads to plan Week 2). Days are numbered, not weekday-locked.

---

## Locked constraints (do not drift)
- Repo: `novapay-sre` (public). Build path: **minimal payments core, self-built, built for correctness.** No cloning, no real PSP, no PCI scope.
- **Postgres is local this week.** For dev it runs **locally on WSL2**; the deploy target EC2 runs **its own local Postgres** (already installed by the provision playbook). RDS — and the deep isolation/locking/connection-pool work — is **Week 7**, not now.
- **One box only** for runtime (the EC2 instance). **Billing alarm must exist before launching anything.** Tear down / stop the EC2 instance at the end of each session.
- **Scope ceiling:** build only what **deepens a core competency** — correctness, concurrency, systems, observability, reproducibility. No payment features for their own sake.
- **Cadence:** build daily; publish one **build/learning deep-dive** at end of week. Comment on 5–10 posts daily.
- **Foundation principle (standing):** *build for correctness, depth-first.* Study failure modes to **harden** against them — every timeout, retry cap, and invariant check is a defense — not to manufacture incidents. Reproducibility and demonstrable correctness are the measure.

---

## Build specs (the contract Sonnet builds toward — keeps dev unambiguous)

### `app/payment-api/` (Go)
- `GET /healthz` → `200 {"status":"ok"}` *(done)*
- `POST /charge` — body: `{ "idempotency_key": str, "amount_minor": int, "currency": str, "customer_id": str }`
  - On new key: write the payments row + **two balanced ledger entries**, call `fake-psp` `/authorize`, return `{ "payment_id": str, "status": "approved|declined" }`.
  - On repeated key: return the original result, do **not** move money again.
- Structured JSON logs to stdout (request id, idempotency_key, latency_ms, psp_status).
- **Resilience properties (built this week, see Days 4–6):** bounded retries with backoff + jitter + cap; a `context` deadline + HTTP client timeout on every PSP call; graceful shutdown on SIGTERM that drains in-flight charges; correct goroutine lifecycle (no leaks).

### Ledger schema (Postgres, local this week)
```
accounts(id PK, name, type)                          -- seed: 'customer_funds', 'psp_clearing'
payments(id PK, idempotency_key UNIQUE NOT NULL,
         amount_minor, currency, status, created_at)
ledger_entries(id PK, payment_id FK, account_id FK,
               amount_minor, direction CHECK(direction IN ('debit','credit')), created_at)
```
- **Invariant:** for any `payment_id`, sum(debits) == sum(credits). This is the heart of the system — write a tiny check query you can run by hand. (It becomes a real-time SLO in Phase 2, and gets the deep concurrency treatment — isolation levels, row locking — in Week 7.)
- Idempotency is enforced by the `UNIQUE(idempotency_key)` constraint, not application logic alone.

### `app/fake-psp/` (Go) — the controllable "bank"
- `POST /authorize` — body: `{ "amount_minor": int, "currency": str }` → `{ "psp_ref": str, "status": "approved" }` *(done)*
- **Knobs** (env vars or query params) — these exist so you can **reproduce the failure modes you're hardening against and test your defenses** (and, post-checkpoint, drive chaos experiments):
  - `PSP_LATENCY_MS` — inject delay before responding. *(done)*
  - `PSP_ERROR_RATE` — fraction of calls that 500 (used to test backoff, Day 4).
  - `PSP_HANG=true` — accept and never respond (used to test timeouts, Day 6). *(done)*

---

## Day-by-day

### Day 1 — Environment + scaffold (DONE ✓)
- [x] WSL2 set up as the build box: Go 1.24.3, gopls, Ansible, Neovim.
- [x] Billing alarm confirmed. EC2 (Ubuntu 24.04, t3.micro) launched and **provisioned via Ansible** (Go + Postgres + app dirs + log dir).
- [x] Repo folders confirmed (`app/`, `infrastructure/`, `monitoring/`, `postmortems/`, `runbooks/`, `scripts/`). Legacy Python app moved to `app/legacy/`.
- [x] Scaffolded `payment-api` (`/healthz`) and `fake-psp` (`/authorize` + latency/hang knobs); both compile and run on WSL2; smoke-tested with curl; binaries git-ignored; committed + pushed.
- **Acceptance:** met — both binaries run; `curl localhost:<port>/healthz` returns ok; first commit pushed.

### Day 2 — Core charge path + ledger (BUILD · on WSL2)
- [ ] Install Postgres **locally on WSL2** for the dev loop; create the NovaPay database.
- [ ] Create the ledger schema; seed the two accounts.
- [ ] Implement `POST /charge`: write the payments row + two balanced ledger entries **in a single transaction**, call `fake-psp /authorize`, return the result.
- [ ] Enforce idempotency via the unique constraint; a repeated key returns the original result and moves no money.
- [ ] Add structured JSON logging (request id, idempotency_key, latency_ms, psp_status).
- **Acceptance:** a successful charge creates exactly 2 ledger rows summing to zero; the same idempotency_key twice creates only one payment; the hand-run invariant query passes. Commit.
- **Baseline note:** record what "normal" looks like — latency, log cadence, a healthy charge. You'll verify your Day 4–6 hardening against this.

### Day 3 — systemd + deploy via Ansible (BUILD → DEPLOY)
- [ ] Write systemd unit files for `payment-api` and `fake-psp` (log to journald, restart-on-failure, start-on-boot).
- [ ] Write an **Ansible deploy playbook** (`infrastructure/ansible/deploy.yml`): build the Go binaries, copy them to `/opt/novapay/bin` on EC2, template the unit files, `daemon-reload`, `enable --now`, restart. One command deploys.
- [ ] Deploy to EC2 with the playbook. Confirm both run as managed services; `systemctl status`, `journalctl -u payment-api -f`.
- **Acceptance:** both run as managed services on EC2, deployed via a single Ansible command; killing a process triggers a systemd restart; logs visible in the journal. Commit.

### Day 4 — Harden: resilient dependency calls (HARDEN)
- **Competency:** a payment service is only as reliable as its calls across process boundaries. A naive retry against a flaky dependency busy-spins and amplifies load.
- [ ] Set `PSP_ERROR_RATE=0.5`. Drive a small load loop at `/charge` with a *naive* retry (no backoff) and **watch it once** in `top`/`btop` — see the CPU pin and latency explode. Inspect the pegged process: `ps -p <pid> -o ...`, peek at `/proc/<pid>`. This is what you're defending against.
- [ ] **Build the defense:** retries with **backoff + jitter + a cap**. Re-run the load loop; confirm CPU stays sane and the service degrades gracefully instead of melting.
- [ ] Note the *money framing*: charges timing out = lost/queued payments — that's why this matters in a payments context.
- **Acceptance:** bounded-retry logic committed; under `PSP_ERROR_RATE=0.5` the service stays at baseline CPU. Commit.

### Day 5 — Harden: correct process & goroutine lifecycle (HARDEN · Linux process lesson)
- **Competency:** understand Linux process semantics (zombies, orphans, reaping, `<defunct>`, PID/fd pressure) — core Week-1 Linux material — and apply it to a correct concurrency design.
- [ ] **Learn firsthand:** wire "receipt generation" as a *shelled-out child process per charge that isn't reaped*, drive load, and watch `<defunct>` accumulate: `ps -el | grep defunct`, identify the parent, explain *why* they aren't reaped (no `wait`/SIGCHLD handling). This is the Linux lesson.
- [ ] **Build it correctly:** replace the shell-out with an **in-process goroutine** for receipt generation — bounded concurrency, no leaked goroutines, cleaned up on shutdown. Confirm no defunct processes and no goroutine leak under load.
- **Acceptance:** correct in-process design committed; zero `<defunct>` processes under load; you can explain reaping and why the in-process design is the right call. Commit.

### Day 6 — Harden: timeouts & graceful shutdown (HARDEN)
- **Competency:** an unbounded wait on a dependency is the *silent* failure — the process stays alive and answers health checks while doing no work, and goroutines/connections/fds pile up until the box tips. Liveness ≠ healthy.
- [ ] Set `PSP_HANG=true`. Issue a charge and **observe once**: the request blocks forever; trace where it's stuck; watch goroutines/connections accumulate. This is what you're defending against.
- [ ] **Build the defense:** a `context` deadline + HTTP client timeout on the PSP call — fail fast and mark the payment appropriately; plus **graceful shutdown** on SIGTERM that drains in-flight charges so a deploy/restart doesn't strand money.
- [ ] Confirm: with `PSP_HANG=true`, a charge now fails fast and the service stays responsive; on SIGTERM, in-flight work drains cleanly.
- **Acceptance:** deadlines + graceful shutdown committed; a hung PSP no longer wedges the service. Commit. *(Previews the circuit-breaker work in the later reliability phase — note that in the write-up.)*

### Day 7 — Consolidate + publish (CONTENT)
- [ ] Pick the week's strongest **build story** — recommended: **resilient dependency handling** (Days 4 & 6 unified), the most instructive and senior-signaling.
- [ ] Polish it to portfolio quality. Update `README.md` and `checkpoint.md`.
- [ ] Draft the LinkedIn **build/learning deep-dive** (brief below).
- [ ] **Tear down / stop** all billable resources.

---

## LinkedIn deep-dive brief (Day 7)
**Subject:** *How I built a payment service to be resilient at the process boundary — bounded retries, timeouts, and clean shutdown.*

**What kind of post this is — read before drafting.** This is a **build-and-teach** post, not an incident postmortem. The value is showing *how to call a flaky dependency safely in Go and why each defense matters*. It reads senior because it demonstrates engineering judgment built in from the start — not a war story about something breaking. (The break-on-purpose / chaos framing belongs to the SRE lane, after the checkpoint.)

**Honesty stance:** it's a learning build, openly so. You can show the *naive* version next to the *hardened* version to make the lesson concrete — transparently framed as "I built it both ways to understand the failure mode." That's honest and instructive; no manufactured outage required.

**Hook (first ~210 chars — lead with the engineering insight or the stakes):**
> e.g. *"A payment call to a bank with no timeout isn't 'mostly fine' — it's a goroutine, a connection, and a file descriptor quietly piling up until the box tips over. The process stays 'up' the whole time. Here's how I built every dependency call to fail fast and shut down clean."*

**Body (~1,200–1,500 chars) — in this order:**
1. **The frame:** a payments service is only as reliable as its calls across a process boundary. Three things can go wrong there — the dependency errors, it hangs, or you restart mid-charge.
2. **Defense 1 — bounded retries (backoff + jitter + cap):** why a naive retry busy-spins the CPU and amplifies load on an already-struggling dependency; what the bounded version looks like.
3. **Defense 2 — a deadline on every outbound call:** the silent failure — liveness ≠ doing work. A `context` deadline + client timeout means a slow/hung bank fails fast and the payment gets a clear terminal state instead of hanging forever.
4. **Defense 3 — graceful shutdown:** drain in-flight charges on SIGTERM so a deploy or restart never strands money mid-flight.
5. **Takeaway:** at a process boundary, "no timeout" and "no backoff" aren't omissions — they're latent outages. Build the defense in from the start; correctness under failure is a design property, not an afterthought.

**Close:** one line on what's next — moving the ledger to RDS and adding real observability so these properties are *measured*, not just coded.

**Tone:** honest, specific, no hype. Show the actual code and the `top`/`ps` output that motivated each defense.

---

## End-of-week deliverables checklist
- [ ] `payment-api` + `fake-psp` running under systemd on one EC2 box, **deployed via Ansible** (one command).
- [ ] Double-entry ledger (local Postgres) with the **balance invariant holding** and **idempotency real** (repeated key moves no money).
- [ ] Service **hardened at the process boundary**: bounded retries (backoff + jitter + cap), `context` deadlines + client timeouts, graceful shutdown, correct in-process goroutine lifecycle.
- [ ] `checkpoint.md` updated.
- [ ] One **build/learning deep-dive** drafted.
- [ ] Billable resources torn down.
