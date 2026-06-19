# Day 03 — systemd Unit Files + Ansible Deploy Playbook
**Date:** 2026-06-11
**Phase:** Phase 1 · Week 1 · Linux & Systems Foundations
**Status:** complete ✓

---

## Goal
Run both services as **managed systemd units on EC2**, deployed end-to-end via a single Ansible command. At the end of Day 03:
- `systemctl status payment-api` → `active (running)` on EC2
- Killing the process triggers an automatic systemd restart
- Logs visible in `journalctl -u payment-api`
- Deploy is one command: `ansible-playbook -i inventory.ini deploy.yml`

---

## What was actually built

### 1. `infrastructure/systemd/payment-api.service`
```ini
[Unit]
Description=NovaPay Payment API
After=network.target postgresql.service

[Service]
User=ubuntu
ExecStart=/opt/novapay/bin/payment-api
Restart=on-failure
RestartSec=5s
Environment=PORT=8080
Environment=DATABASE_URL=postgresql://novapay:novapay@localhost:5432/novapay?sslmode=disable
Environment=PSP_URL=http://localhost:8081
StandardOutput=journal
StandardError=journal
SyslogIdentifier=payment-api

[Install]
WantedBy=multi-user.target
```

### 2. `infrastructure/systemd/fake-psp.service`
```ini
[Unit]
Description=NovaPay Fake PSP
After=network.target

[Service]
User=ubuntu
ExecStart=/opt/novapay/bin/fake-psp
Restart=on-failure
RestartSec=5s
Environment=PORT=8081
StandardOutput=journal
StandardError=journal
SyslogIdentifier=fake-psp

[Install]
WantedBy=multi-user.target
```

### 3. `infrastructure/ansible/deploy.yml`
Full Ansible playbook with these tasks in order:
1. **Build payment-api binary** — `go build -o payment-api ./...` via `delegate_to: localhost` (runs on WSL2, not EC2)
2. **Build fake-psp binary** — same pattern
3. **Copy binaries** to `/opt/novapay/bin/` with `mode: '0755'`
4. **Copy `schema.sql`** to `/opt/novapay/schema.sql`
5. **Copy systemd unit files** to `/etc/systemd/system/`
6. **Set up Postgres** (idempotent via shell + `|| true`): create user, create database, grant privileges
7. **Apply `schema.sql`** via `psql` shell command (idempotent — tables use `IF NOT EXISTS`, inserts use `ON CONFLICT DO NOTHING`)
8. **`daemon_reload: yes`**
9. **Enable + restart both services** via `systemd` module

---

## Key decisions made

**Build locally via `delegate_to: localhost`, not on EC2**
The Ansible play targets EC2, but the build step uses `delegate_to: localhost` so it runs on WSL2. EC2 does not need Go installed to run the binaries. The compiled Linux binaries are then copied over. This matches the real workflow: WSL2 = build box, EC2 = runtime target.

**No `community.postgresql` Ansible module — use `shell` with `|| true`**
The `community.postgresql.postgresql_user` and `postgresql_db` modules require the `psycopg2` Python package on the target, which wasn't provisioned. Instead, Postgres setup uses raw `shell` tasks with `sudo -u postgres psql -c "..."` and `2>/dev/null || true` to make them idempotent. If the user/database already exists, the command errors but Ansible keeps going. Simpler, no extra dependencies.

**`SyslogIdentifier` set explicitly in both unit files**
Without `SyslogIdentifier=payment-api`, journald uses the process binary name as the identifier. Explicit identifiers mean `journalctl -u payment-api` always works cleanly, even if the binary is renamed or the process forks.

**`After=network.target postgresql.service` for payment-api only**
payment-api depends on both the network and Postgres being available at start. fake-psp has no DB dependency, so it only waits on `network.target`. Correct ordering prevents "connection refused" on boot.

**`Restart=on-failure` with `RestartSec=5s`**
Only restart if the process exits with a non-zero code (crashes, OOM). A deliberate `systemctl stop` does not trigger a restart. 5-second delay gives Postgres a moment to recover if the crash was DB-related. This is the Day 3 baseline — proper bounded retries are Day 4.

---

## EC2 baseline recorded (post-deploy)

This is the "normal" state everything in Days 4–6 is measured against:

| Service | Memory | Port | Logging | Restart policy | Boot |
|---|---|---|---|---|---|
| payment-api | ~1.9 MB RSS | 8080 | journald (`SyslogIdentifier=payment-api`) | `on-failure`, 5s backoff | enabled |
| fake-psp | ~1.1 MB RSS | 8081 | journald (`SyslogIdentifier=fake-psp`) | `on-failure`, 5s backoff | enabled |

- CPU under no load: ~0–1%
- 0 payments, invariant clean (0 rows returned by invariant query on EC2)
- Reboot-safe: `WantedBy=multi-user.target` + `enabled` means both services start automatically

---

## Acceptance criteria — all met ✓

- [x] Both services running as systemd units on EC2
- [x] `systemctl status payment-api` and `systemctl status fake-psp` → `active (running)`
- [x] `journalctl -u payment-api` shows structured JSON logs
- [x] Killing a process (`pkill payment-api`) triggers automatic systemd restart within 5s
- [x] Full deploy via one command: `ansible-playbook -i infrastructure/ansible/inventory.ini infrastructure/ansible/deploy.yml`
- [x] EC2 Postgres `novapay` database and schema created idempotently by the playbook
- [x] Ledger invariant holds on EC2 database — 0 rows
- [x] Baseline (RAM, port, log cadence) recorded in `checkpoint.md`

---

## What I learned

**systemd is a process supervisor, not just an init system.** The three unit file sections map directly to real operational concerns: `[Unit]` = ordering and dependencies; `[Service]` = how to run and what to do on failure; `[Install]` = when to start it automatically. `Restart=on-failure` + `RestartSec=5s` is the minimum viable restart policy. The service manager handles the restart loop, logging, and PID tracking — you don't write any of that yourself.

**`journalctl` is the right way to read service logs.** `journalctl -u payment-api` filters by unit. `-f` follows live. `--since "10 min ago"` scopes to recent history. Because both unit files set `StandardOutput=journal`, all `slog` output goes to journald, and `SyslogIdentifier` makes filtering exact. No log file rotation to configure for now — journald handles retention.

**Ansible `delegate_to: localhost` is the correct pattern for build-then-deploy.** The alternative (running `go build` on EC2) would require Go to be installed on every deploy target. `delegate_to: localhost` lets the WSL2 box compile and then Ansible copies the artifact. This is the same pattern CI systems use: build artifact on the build host, push to the deploy target. Ansible executes the delegated task with the local environment but still under the play's `become` scope rules — so `become: false` must be set on the build tasks to prevent a sudo escalation attempt on WSL2.

**Idempotency in Ansible requires deliberate design.** The copy module is idempotent by default (hash check). The systemd module is idempotent. The Postgres setup via shell is not — it's made idempotent by redirecting errors and using `|| true`. The schema is idempotent because the SQL uses `IF NOT EXISTS` and `ON CONFLICT DO NOTHING`. Running the playbook twice leaves the system in the same state as running it once — that's the correctness property Ansible is trying to give you, but it only works if you build it in.

**Go binaries on Linux are statically linked by default.** The compiled binary carries its dependencies. No runtime to install on EC2, no version conflicts. Just copy the binary and run it. This is why `delegate_to: localhost` works cleanly: the WSL2 build target is also Linux (via WSL2 kernel), so the binary is ELF-compatible with EC2 Ubuntu.

---

## Problems hit (none critical)

**community.postgresql not available on EC2**
The initial plan used `community.postgresql.postgresql_user` and `community.postgresql.postgresql_db`. When the playbook ran, Ansible returned: module not found. Root cause: `ansible-galaxy collection install community.postgresql` had not been run, and EC2 didn't have `psycopg2`. Resolution: replaced with `shell` tasks using `sudo -u postgres psql -c "..."`. More verbose, but zero dependencies.

---

## Commands worth keeping

```bash
# Run the full deploy from WSL2
ansible-playbook -i infrastructure/ansible/inventory.ini infrastructure/ansible/deploy.yml

# Dry-run (see what Ansible would change without touching anything)
ansible-playbook --check -i infrastructure/ansible/inventory.ini infrastructure/ansible/deploy.yml

# On EC2: check service status
systemctl status payment-api
systemctl status fake-psp

# On EC2: follow live logs
journalctl -u payment-api -f
journalctl -u fake-psp -f

# On EC2: test restart-on-failure
sudo pkill payment-api
sleep 6
systemctl status payment-api   # should be active (running) again

# On EC2: verify invariant on EC2 database
psql postgresql://novapay:novapay@localhost:5432/novapay -c "
SELECT payment_id,
  SUM(CASE WHEN direction='debit'  THEN amount_minor ELSE 0 END) AS debits,
  SUM(CASE WHEN direction='credit' THEN amount_minor ELSE 0 END) AS credits
FROM ledger_entries GROUP BY payment_id
HAVING SUM(CASE WHEN direction='debit' THEN amount_minor ELSE 0 END) !=
       SUM(CASE WHEN direction='credit' THEN amount_minor ELSE 0 END);"
```

---

## Deploy workflow: commands, hooks, and understanding `--check` mode

This section documents the full sequence Claude Code executes when you run the deploy workflow — and precisely what you can and cannot trust from each step.

### The intended sequence (per CLAUDE.local.md rules)

```
/check  →  /deploy-dry-run  →  /deploy  →  /ec2-invariant
```

### Step-by-step: what each command triggers

**Step 1 — `/check`**
Runs `go build ./...` on both apps, then `go vet`, then the invariant query on the **local WSL2 Postgres**. No network, no EC2 contact. This is a local correctness gate — it catches compile errors and broken ledger logic before anything touches the deploy path.

**Step 2 — `/deploy-dry-run`**
Runs:
```bash
ansible-playbook \
  -i infrastructure/ansible/inventory.ini \
  infrastructure/ansible/deploy.yml \
  --check --diff
```

Before the command executes:
- `pre-deploy-check.sh` fires (PreToolUse hook on every Bash call)
- The hook reads the command string, sees `--check`, and **exits 0** (allows it through)

After the command completes:
- `post-tool-log.sh` fires (PostToolUse hook on every Bash call)
- The hook logs the command to `~/.claude/novapay-activity.log`
- Because the command contains `--check`, the hook **does not** print the "Run /ec2-invariant" reminder

**Step 3 — `/deploy`**
Runs:
```bash
ansible-playbook -i infrastructure/ansible/inventory.ini infrastructure/ansible/deploy.yml
```

Before the command executes:
- `pre-deploy-check.sh` fires (PreToolUse hook)
- The hook sees `ansible-playbook` with **no `--check` flag**
- Hook prints the PRODUCTION DEPLOY GATE banner and **exits 2** — Claude Code blocks the tool call
- You must run this manually in the terminal — Claude Code cannot deploy to EC2 autonomously

After the command completes:
- `post-tool-log.sh` fires and prints: `✓ Deploy completed. Run /ec2-invariant to verify money is still balanced.`

**Step 4 — `/ec2-invariant`**
Runs two `ansible -m command` ad-hoc commands against EC2. Queries the **EC2 Postgres** (not WSL2). Returns the invariant result and total payment count. This is the post-deploy correctness gate.

---

### What you can and cannot trust from `--check` mode

Not all Ansible task types behave the same in `--check`. This is the single most important thing to understand about dry-runs.

| Task type | What `--check` actually does | Trust level | In this playbook |
|---|---|---|---|
| `copy` | Computes a hash diff between local and remote file | **High** — tells you exactly what file content would change | Binaries, schema.sql, unit files |
| `template` | Actually renders the template and diffs it | **High** — shows config changes | Not used yet |
| `systemd` | Simulates based on what `copy` reported | **Medium** — accurate only if preceding copy was accurate | daemon-reload, enable, restart |
| `command` | **Skipped entirely** — no simulation at all | **Zero** — gives you no information | `go build` tasks |
| `shell` | **Skipped entirely** — no simulation at all | **Zero** — gives you no information | Postgres setup, schema apply |

**The practical rule — one sentence:**

> Run `/deploy-dry-run` to verify **which files are changing and where they land**. Never use it to validate **shell or command tasks** — those are always silent in check mode and give you zero information about whether they will succeed.

**What `/deploy-dry-run` is reliable for:**
- Confirming the right binary lands in `/opt/novapay/bin/`
- Confirming the correct unit file content goes to `/etc/systemd/system/`
- Seeing exactly what file content would change (`--diff` shows the diff)

**What `/deploy-dry-run` tells you nothing about:**
- Whether `go build` succeeds (silently skipped)
- Whether the Postgres user/database creation works (silently skipped)
- Whether `psql schema.sql` applies cleanly (silently skipped)

---

### The false positive explained

The dry-run reported one failure:
```
fatal: [ec2]: FAILED! => "Could not find the requested service payment-api: host"
```

This is a **check-mode false positive** — a reported failure that does not occur in a real deploy. Here is why:

```
Step 1 → copy payment-api.service to /etc/systemd/system/   [SIMULATED — not written]
Step 2 → systemctl daemon-reload                             [SIMULATED — not run]
Step 3 → systemctl enable --now payment-api                  [RUNS against real EC2]
               ↓
        EC2's real systemd: "I have never seen a payment-api unit file"
        FAIL ✗  (honest answer — the file was only simulated, never written)
```

In a real deploy, Step 1 actually writes the file, Step 2 actually reloads systemd, and Step 3 succeeds because the service exists. The failure only existed because simulation breaks the dependency chain.

**How to distinguish false positives from real failures:**

Ask one question: *Does this task depend on a previous task that was only simulated?*

| Failure in `--check` | Meaning | Action |
|---|---|---|
| Service not found (unit file being deployed in same playbook) | False positive — simulation gap | Safe to deploy |
| Connection refused / host unreachable | Real problem — EC2 is down | Fix before deploying |
| Permission denied | Real problem — wrong credentials | Fix before deploying |
| File not found (file that already exists on EC2) | Real problem — path is wrong | Fix before deploying |

---

### The complete pre-deploy confidence chain

`/check` and `/deploy-dry-run` complement each other — together they cover the full picture:

```
/check           → validates: code compiles, go vet passes, ledger invariant holds locally
/deploy-dry-run  → validates: correct files going to correct places on EC2 (copy tasks only)
Real deploy      → validates: shell tasks (Postgres, schema) — only on first run
/ec2-invariant   → validates: invariant holds on EC2 after deploy
```

**The corollary:** `/check` covers exactly what `--check` misses. `/check` runs `go build` and `go vet` locally. If those pass, the build step in the real deploy will also pass — the same binary that compiled on WSL2 is what gets copied to EC2. The two commands are designed to be run together precisely because each covers the other's blind spot.

Running all four in order — as done today — is the correct and complete workflow.

---

### Hook wiring (settings.json)

Both hooks are registered in `.claude/settings.json` under `PreToolUse` and `PostToolUse`, each with `matcher: "Bash"` — they fire on **every single Bash tool call**. The hooks inspect the command string internally and only act on matching patterns.

`ansible-playbook --check` is in the `permissions.allow` list — dry-runs run without prompting. A real deploy (`ansible-playbook` without `--check`) is **not** in the allow list, so the user sees a permission prompt in addition to the hook gate — two independent safety layers.

---

## Handoff to Day 04
**Status:** Day 03 complete ✓

**What Day 03 leaves behind:**
- Both services managed by systemd on EC2, deployed via Ansible
- EC2 baseline: 1.9MB / 1.1MB RAM, ports 8080/8081, restart-on-failure, reboot-safe
- Invariant holds on EC2 (0 rows)

**Day 04 goal:** bounded retries — backoff + jitter + cap on the PSP call in `payment-api`.
- fake-psp gains the `PSP_ERROR_RATE` knob (random % failure, configurable via env)
- payment-api retries with exponential backoff + full jitter, capped at 3 attempts
- Verify: with `PSP_ERROR_RATE=0.5`, most charges succeed; ledger invariant still holds; no payment retried into a second write

**What Day 04 starts with:**
1. Add `PSP_ERROR_RATE` env knob to `fake-psp/main.go`
2. Add retry loop with backoff + jitter to `payment-api/main.go` PSP call
3. Test against high error rate, confirm invariant holds
4. Commit: `D4: bounded retries with backoff + jitter`
