# Day 01 — Environment + Scaffold
**Date:** 2026-06-03
**Phase:** Phase 1 · Week 1 · Linux & Systems Foundations
**Time spent:** ~3 hours

---

## Goal
Stand up the WSL2 build environment, provision EC2 via Ansible, and scaffold `payment-api` + `fake-psp` so both compile and respond to curl.

---

## What was actually built
- WSL2 (Ubuntu 24.04) configured as the primary dev box: Go 1.24.3, gopls, Ansible, Neovim
- EC2 (Ubuntu 24.04, t3.micro) provisioned via a single Ansible playbook — Go, Postgres, app dirs, log dirs, all repeatable
- `payment-api`: `GET /healthz` → `{"status":"ok"}`
- `fake-psp`: `POST /authorize` → `{"psp_ref":"psp_xxxxxxxx","status":"approved"}` + failure knobs (`PSP_LATENCY_MS`, `PSP_ERROR_RATE`, `PSP_HANG`)
- Both services compile and smoke-tested locally on WSL2
- `.gitignore` created to exclude Go binaries
- First commit + push to `novapay-sre` (public)

---

## Key decisions made

**WSL2-dev → EC2-deploy via Ansible** (not develop-on-EC2).
The cleaner platform-engineering workflow: write on WSL2, deploy via code. The Ansible provision playbook lives in `infrastructure/ansible/provision.yml`. One command rebuilds EC2 from scratch.

**VS Code as primary IDE** (after evaluating Neovim and IntelliJ IDEA).
- Neovim: friction too high while simultaneously learning Go + Linux + DevOps stack. Keep for on-EC2 debugging.
- IntelliJ IDEA: enterprise-grade but Java-world. Not designed for Go + Terraform + Ansible + K8s multi-stack.
- VS Code + Remote-WSL: first-class WSL2 support, official Go extension (gopls), covers the full stack (Terraform, Ansible, Kubernetes, Docker). Right call for the foundation.
- Rule: IntelliSense ON (learning aid), Copilot OFF (muscle memory killer).

**Legacy Python app moved to `app/legacy/`** — not deleted, just separated cleanly from the Go work.

---

## Problems hit + resolutions

**Go 1.22.2 shadowing 1.24.3**
- Installed 1.24.3 via tarball but `go version` still showed 1.22.2
- Root cause: `/usr/bin/go` (apt-installed 1.22.2) appeared before `/usr/local/go/bin/go` in PATH
- Fix: `sudo apt remove golang-go golang` + `sudo apt autoremove`
- Lesson: always check `where go` / `which go` after installing a new Go version; the system apt package silently wins

**Accidentally committed compiled Go binaries (7.35 MB push)**
- `app/fake-psp/fake-psp` and `app/payment-api/payment-api` tracked by git before `.gitignore` existed
- Caught immediately: `git ls-files | xargs ls -la | sort -k5 -rn | head -10`
- Fix: `git rm --cached` both binaries + add to `.gitignore`, then re-commit
- Lesson: create `.gitignore` before the first `git add`, not after

**Neovim paste cascading indentation issue**
- Pasting Go code into Neovim without `:set paste` caused auto-indent to cascade, nesting functions inside each other
- Fix: `:set paste` → `i` → paste → `Esc` → `:set nopaste` → `:wq`
- Reason to move to VS Code for future development

---

## What I learned

The **WSL2-dev → EC2-deploy split** is how platform engineers actually work. The local machine is the control plane (code, Ansible, Terraform commands); the cloud VM is the runtime. This muscle was built on Day 1 intentionally — it influences every subsequent day.

The **Go PATH ordering lesson** is a microcosm of how Linux systems fail: the first match in PATH wins, silently. The same principle appears in `LD_LIBRARY_PATH`, `GOPATH`, `PYTHONPATH`. Understanding it at the Go level makes it obvious everywhere else.

---

## Commands worth keeping
```bash
# Check which Go binary wins
where go

# Remove apt-installed Go that shadows a manual install
sudo apt remove golang-go golang && sudo apt autoremove

# Check for accidentally committed large files
git ls-files | xargs ls -la 2>/dev/null | sort -k5 -rn | head -10

# Remove a file from git tracking without deleting it
git rm --cached path/to/file

# Ansible: test connectivity before running a playbook
ansible -i inventory.ini novapay -m ping

# Run the provision playbook
ansible-playbook -i inventory.ini provision.yml
```

---

## LinkedIn article notes
_Raw material — not polished. Pull from here when writing Day 7._

**Strong angles:**
- The binary-in-git catch: "I pushed 7.35 MB on my first commit and here's how I caught it." Short, honest, practical.
- The IDE decision journey: most people default to whatever they used last. Walking through the evaluation (Neovim friction vs VS Code zero-friction vs IntelliJ wrong-domain) shows engineering judgment.
- The WSL2-dev/EC2-deploy workflow as the first deliberate platform-engineering decision: "On Day 1 I set up the workflow, not just the code."

**Specific moments worth using:**
- `go version` still showing 1.22.2 after installing 1.24.3 — the `where go` diagnostic and PATH lesson
- The Ansible ping: "Before I ran a single playbook, I ran a ping. Infrastructure is trust-but-verify from the first command."

**What NOT to make the article about:**
- The scaffold itself (too simple to be interesting)
- Feature list of tools installed

---

## Handoff to Day 02
**Status:** Day 01 complete ✓
**EC2:** provisioned, Go + Postgres running, app dirs created
**WSL2:** Go 1.24.3, gopls, Ansible, VS Code wired to WSL2
**Repo:** clean, binaries excluded, infrastructure committed

**Day 02 starts with:** install Postgres on WSL2, create the NovaPay database, build `POST /charge` with double-entry ledger + idempotency.