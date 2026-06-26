# Day 11 — OOM Incident: Observed and Contained (INC-007)

**Date:** 2026-06-26
**Phase:** Phase 1 · Week 2 · Linux & Systems Foundations
**Status:** complete ✓
**Commit:** pending — to be pushed at end of session (D11 commit)

---

## Goal

With Postgres co-resident on a 911MB / zero-swap EC2 t3.micro, demonstrate what
happens when `payment-api` tries to consume all available RAM — and prove that the
blast radius is structurally bounded to `payment-api`'s own cgroup before the test
ever runs. The safety mechanism is the ordering: cgroup cap confirmed active first,
`NOVAPAY_DEBUG=1` set second, balloon called third. Any deviation from that order
removes the structural bound and risks the kernel's system-wide OOM killer choosing
Postgres as its victim, which would corrupt or lose the ledger.

Day 11 is purely observational. The cap is transient (`systemctl set-property`),
the debug env is via a drop-in (removable), and the balloon endpoint is only wired
into the HTTP mux when `NOVAPAY_DEBUG=1` is present at startup — a structural 404
when it isn't. Day 12 will bake the memory limits permanently into the unit files
as IaC and strip `NOVAPAY_DEBUG` from the deployed config.

---

## What was actually built

### `app/payment-api/debug.go` — new file

```go
package main

import (
    "fmt"
    "net/http"
    "strconv"
)

// balloon holds allocated slabs across requests so the GC cannot collect them.
// Grows monotonically for the duration of the process — intentional: the point
// is to drive RSS up to trigger the cgroup OOM kill.
var balloon [][]byte

func handleBalloon(w http.ResponseWriter, r *http.Request) {
    mbStr := r.URL.Query().Get("mb")
    mb, err := strconv.Atoi(mbStr)
    if err != nil || mb <= 0 || mb > 512 {
        http.Error(w, "mb must be a positive integer <= 512", http.StatusBadRequest)
        return
    }

    slab := make([]byte, mb*1024*1024)

    // Touch every page so the kernel faults in physical frames now.
    // make() returns virtual memory backed by MAP_ANONYMOUS pages that are
    // copy-on-write zeroed — they don't contribute to RSS until first written.
    // Writing one byte per 4KB page forces a page fault on each page, causing
    // the kernel to assign a physical frame. After this loop RSS grows by ~N MB.
    const pageSize = 4096
    for i := 0; i < len(slab); i += pageSize {
        slab[i] = 1
    }

    balloon = append(balloon, slab)
    fmt.Fprintf(w, "ballooned +%dMB (total slabs: %d)\n", mb, len(balloon))
}
```

The 512MB ceiling is a second structural guard independent of the cgroup cap:
even if the cap were somehow absent, this code cannot request more than half the
box's total RAM in a single call. Defense in depth — same pattern as
DB-level idempotency enforcing what the application already enforces.

### `app/payment-api/main.go` — conditional route registration

Added immediately after the two existing `http.HandleFunc` calls:

```go
if os.Getenv("NOVAPAY_DEBUG") == "1" {
    http.HandleFunc("/debug/balloon", handleBalloon)
    slog.Info("debug balloon endpoint enabled — NOT FOR PRODUCTION")
}
```

The `if` block only executes at process startup. If the env var is absent, the
default `ServeMux` has no entry for `/debug/balloon` — any request gets a plain
`404 page not found`. Not a 401, not a disabled handler — the route does not exist
in the mux table at all.

### `checkpoint.md` — discipline signal logged

Added a `### Day 11 — discipline signal (2026-06-26)` entry to the agentic
workflow enhancement log recording a strong personal pull toward the SRE
break/observe/contain/verify/teardown loop as a data point for the Week-20
discipline decision (ADR-007). Not acted on.

---

## Core concept — cgroup v2 memory containment and the kernel OOM killer

### The concept explained from first principles

Linux cgroup v2 (`cgroup2fs`, unified hierarchy) organises processes into a tree
of control groups. Each node in the tree can have resource limits applied to it.
systemd 255 maps every service to its own cgroup slice:
`/system.slice/payment-api.service`. When you run
`systemctl set-property payment-api.service MemoryMax=128M`, systemd writes
`134217728` to `/sys/fs/cgroup/system.slice/payment-api.service/memory.max`.

Two distinct limits are relevant here:

**`MemoryHigh` (soft, reclaim throttle):**
When a cgroup's memory usage crosses `MemoryHigh`, the kernel begins applying
memory pressure to processes in that cgroup. Specifically, it invokes memory
reclaim and throttles the processes by making page faults slower — the page-fault
handler sleeps while the kernel tries to reclaim pages from that cgroup. This is
visible as a process stall. No kill happens; the kernel is trying to bring usage
back below `MemoryHigh` by reclaiming clean pages (page cache, unreferenced
anonymous pages, etc.).

**`MemoryMax` (hard, OOM kill):**
When the cgroup cannot reclaim enough memory to satisfy a new allocation and
usage would exceed `MemoryMax`, the kernel's **cgroup OOM killer** fires. This is
distinct from the system-wide OOM killer. The cgroup OOM killer picks a victim
*within that cgroup only* — it cannot touch processes in other cgroups. The
selected process receives SIGKILL. The kernel records this in dmesg with
`constraint=CONSTRAINT_MEMCG`, which proves the kill was cgroup-scoped (as
opposed to `CONSTRAINT_NONE`, which is system-wide).

When systemd detects that its main process for a service was killed this way, it
records `Failed with result 'oom-kill'` in the journal and, if the unit has
`Restart=on-failure`, schedules a restart. The `restart counter` increments;
`StartLimitBurst` (set in Day 12) bounds how many times it can restart in a
window before entering a failed/backoff state.

**Why this matters for payment-api specifically:**
Postgres (PID 925 throughout this session) runs in
`/system.slice/postgresql.service`. That is a sibling cgroup, not a descendant
of payment-api's cgroup. The cgroup OOM killer's scope is strictly
`/system.slice/payment-api.service` and its children. It cannot reach Postgres.
The system-wide OOM killer can reach anything, which is why the cap goes on
*before* the balloon is ever enabled — without the cap, a runaway payment-api
could push total system memory toward exhaustion, at which point the kernel OOM
killer would make a system-wide choice and Postgres (holding the ledger) could
be selected.

### Why it matters for a payments service specifically

The ledger invariant (sum of debits == sum of credits per payment) is enforced
by Postgres. If Postgres is OOM-killed mid-transaction, the uncommitted
transaction is rolled back — the invariant is safe, but any in-flight charges
fail with a connection error. If Postgres is killed and its shared memory
segments are torn down, recovery takes time and in-flight connections are lost.
On this box there is no replica, no RDS, no failover — if Postgres goes down,
the ledger is unavailable until it restarts. The entire safety design of today's
incident is built around one invariant: *Postgres must never be touched by the
OOM killer, under any memory pressure from payment-api*.

### The broken pattern — what was demonstrated

The broken pattern is `payment-api` running without memory limits
(`MemoryMax=infinity MemoryHigh=infinity`), which is the box's state at Day 11
startup. Under that state, a balloon call for mb=400 on a 911MB box with 0B swap
would compete directly with Postgres for physical RAM. As payment-api's RSS
climbed past ~480MB (the "available" figure captured in the BEFORE snapshot),
the kernel would invoke the system-wide OOM killer and score all processes by
their OOM badness heuristic. Postgres, with its large shared buffer pool, would
have a high badness score. The kill selection is non-deterministic — we reasoned
through the counterfactual and did not execute it.

**Observable state at start of day (pre-cap):**
```
MemoryCurrent=12193792   (~11.6 MB idle RSS)
MemoryHigh=infinity      ← NO soft throttle cap
MemoryMax=infinity       ← NO hard OOM kill cap
```

### The correct pattern — what replaced it

1. `sudo systemctl set-property payment-api.service MemoryMax=128M MemoryHigh=96M`
   — transient cap applied via systemd's runtime property interface. Written to
   `/etc/systemd/system.control/payment-api.service.d/50-MemoryHigh.conf` and
   `50-MemoryMax.conf`. Survives service restarts; removed by `systemctl revert`.

2. `MemoryHigh=96M` chosen as ~75% of `MemoryMax=128M`: gives the kernel a
   meaningful reclaim window before the hard kill. If MemoryHigh == MemoryMax,
   the throttle phase is essentially absent.

3. `MemoryMax=128M` chosen as ~14% of total RAM: 128M ≪ 911M, so even a fully
   ballooned payment-api cgroup occupies less than 1/7th of box memory. The
   remaining ~783MB is structurally unavailable to the cgroup OOM killer for
   payment-api. Postgres is safe regardless of what payment-api does.

4. The deployment ordering was strictly enforced:
   - Cap confirmed active (`systemctl show … -p MemoryMax,MemoryHigh,MemoryCurrent`)
   - Only then: `NOVAPAY_DEBUG=1` drop-in written and service restarted
   - Only then: balloon endpoint confirmed live via journald
   - Only then: balloon called

### The failure cascade — what happens at scale

Without the cgroup cap, a payment-api memory leak (or a traffic spike causing
goroutine accumulation) on a shared Postgres box will eventually consume all
available RAM. On a zero-swap box this triggers the system-wide OOM killer
immediately rather than swapping to disk first. The kernel chooses victims by
OOM score (`/proc/PID/oom_score`), influenced by `oom_score_adj`. Postgres with
a large shared buffer pool has a naturally high score. At the moment the killer
fires, any payment in Postgres's WAL that hasn't reached fsync is potentially
lost. This is the exact scenario ADR-011 (Day 12) hardens against with
`OOMScoreAdjust=+200` on both app services, biasing the kernel to kill them
before Postgres.

---

## What was observed

### BEFORE snapshot (box-wide)
```
total: 911Mi   used: 431Mi   free: 207Mi   available: 479Mi   swap: 0B
```

### Cgroup state before balloon (confirmed active post set-property)
```
MemoryCurrent=1994752    (~1.9 MB idle)
MemoryHigh=100663296     (96 MB)
MemoryMax=134217728      (128 MB)
```

### First balloon call (mb=400)
```
curl exit code: 28  (CURLE_OPERATION_TIMEDOUT — 15s timeout)
```
The page-touch loop (`for i := 0; i < len(slab); i += 4096 { slab[i] = 1 }`)
was throttled so severely by `MemoryHigh` reclaim pressure that 400MB of pages
could not be faulted in within 15 seconds. Process stalled at ~107–122MB. This
is the `MemoryHigh` throttle stage — observable as a hung HTTP request and rising
RSS below MemoryMax.

### MemoryCurrent during stall
```
MemoryCurrent=128086016  (~122 MB — pinned at MemoryMax ceiling)
Memory: 122.1M (high: 96.0M max: 128.0M available: 0B peak: 122.6M)
```
`available: 0B` confirms the cgroup is at its limit with no headroom.

### OOM kill (triggered by second balloon call, mb=10)
The first call's handler eventually completed (after curl disconnected, the Go
HTTP server continued running the handler goroutine). The 400MB slab page-touching
pushed RSS to MemoryMax sometime between our second and third SSH sessions. A
second balloon call (mb=10) on the already-at-limit process triggered the kill.

**journald:**
```
Jun 26 09:23:55  payment-api.service: A process of this unit has been killed by the OOM killer.
Jun 26 09:23:55  payment-api.service: Main process exited, code=killed, status=9/KILL
Jun 26 09:23:55  payment-api.service: Failed with result 'oom-kill'.
Jun 26 09:24:00  payment-api.service: Scheduled restart job, restart counter is at 1.
Jun 26 09:24:00  payment-api[4669]: INFO database connected
Jun 26 09:24:00  payment-api[4669]: INFO audit log opened path=/var/log/novapay/transactions.log
Jun 26 09:24:00  payment-api[4669]: INFO debug balloon endpoint enabled — NOT FOR PRODUCTION
Jun 26 09:24:00  payment-api[4669]: INFO payment-api starting port=8080
```
5-second restart gap (default `RestartSec`). New PID 4669.

**dmesg (cgroup OOM kill proof):**
```
[21567.892148] payment-api invoked oom-killer: gfp_mask=0xcc0(GFP_KERNEL), order=0, oom_score_adj=0
[21567.892239] Memory cgroup stats for /system.slice/payment-api.service:
[21567.892343] oom-kill:constraint=CONSTRAINT_MEMCG,...
               oom_memcg=/system.slice/payment-api.service,
               task=payment-api,pid=4404,uid=1000
[21567.892374] Memory cgroup out of memory: Killed process 4404 (payment-api)
               total-vm:2213636kB, anon-rss:130304kB, file-rss:10868kB
```
`constraint=CONSTRAINT_MEMCG` — not `CONSTRAINT_NONE`. This is the cgroup-scoped
kill, not the system-wide OOM killer. PID 925 (Postgres) does not appear.

### Postgres throughout
```
Active: active (exited) since Fri 2026-06-26 03:24:37 UTC; 6h 0min ago
Main PID: 925
```
Running continuously since boot. Undisturbed through both balloon calls,
the MemoryHigh stall, and the OOM kill.

### AFTER snapshot (box-wide, post kill + restart)
```
total: 911Mi   used: 415Mi   free: 200Mi   available: 495Mi   swap: 0B
```
Available went from 479Mi → 495Mi. The balloon's physical pages were returned to
the OS when the cgroup was destroyed. Box never approached system-wide OOM.

### Recovery charge (post-kill)
```
{"payment_id":"96122afa-df44-4077-9b15-6209b5e89d64","status":"approved"}
```
`payment-api` serving correctly after restart.

### EC2 invariant — final
```
0 rows — PASS
Payment count: 11
```

---

## Acceptance criteria — all met ✓

- [x] Balloon endpoint exists ONLY under `NOVAPAY_DEBUG=1` — confirmed 404 without it (teardown step 2)
- [x] `MemoryMax=128M` set and confirmed active before `NOVAPAY_DEBUG=1` ever set
- [x] `MemoryHigh` throttle observed as distinct stage (MemoryHigh stall caused 15s curl timeout)
- [x] Contained cgroup OOM kill of payment-api — `constraint=CONSTRAINT_MEMCG` in dmesg
- [x] systemd restart within 5 seconds — `restart counter is at 1`, PID 4669 started
- [x] Blast-radius proof: `systemctl status postgresql` active throughout; Postgres PID 925 absent from all OOM output
- [x] `free -h` before/after captured — available went UP after kill (479Mi → 495Mi); no system-wide OOM
- [x] Recovery charge succeeds and is approved post-kill
- [x] EC2 invariant 0 rows, 11 payments — ledger balanced throughout
- [x] Teardown verified: debug.conf removed, cap reverted (`MemoryMax=infinity`), endpoint 404, service healthy at 1.9MB RSS
- [x] INC-007 opened via GitHub MCP before any balloon code was written

---

## Problems hit

**MemoryHigh throttle stall exceeded curl timeout:**
The first balloon call (`mb=400`) timed out after 15 seconds (curl exit code 28).
Root cause: `MemoryHigh=96M` causes the kernel to apply reclaim throttle to the
process's page faults. Touching 400MB of pages (102,400 individual page faults)
while the kernel is actively throttling each fault took longer than the 15-second
curl timeout. The handler goroutine continued running after the HTTP connection
dropped (Go's HTTP server does not cancel handlers on client disconnect). The
fix: called the balloon again with `mb=10` on the stalled-at-limit process, which
pushed it cleanly over MemoryMax and produced the OOM kill. This also revealed a
second valuable observation: the "total slabs: 1" response to the second call
showed the process had already been killed and restarted (fresh `balloon` slice),
meaning the OOM kill of PID 4404 happened between SSH sessions.

---

## Commands worth keeping

```bash
# Set transient cgroup memory limits (survives service restart; removed by revert)
sudo systemctl set-property payment-api.service MemoryMax=128M MemoryHigh=96M

# Verify the limits are actually active (never assume — always confirm)
systemctl show payment-api -p MemoryMax,MemoryHigh,MemoryCurrent

# Revert transient set-property (removes .control drop-in dir entirely)
sudo systemctl revert payment-api.service

# Check cgroup OOM kill in kernel ring buffer (constraint=CONSTRAINT_MEMCG = cgroup-scoped)
sudo dmesg | grep -i -E "(oom|kill|memory cgroup|out of memory)" | tail -20

# Write a systemd drop-in env override (same pattern works for any env var)
sudo mkdir -p /etc/systemd/system/payment-api.service.d/
sudo tee /etc/systemd/system/payment-api.service.d/debug.conf > /dev/null <<'EOF'
[Service]
Environment="NOVAPAY_DEBUG=1"
EOF
sudo systemctl daemon-reload && sudo systemctl restart payment-api

# Remove a drop-in and reload
sudo rm /etc/systemd/system/payment-api.service.d/debug.conf
sudo systemctl daemon-reload && sudo systemctl restart payment-api

# Confirm endpoint does not exist (structural 404 — no route registered)
curl -s -o /dev/null -w "%{http_code}\n" 'http://localhost:8080/debug/balloon?mb=10'
# Must print 404 when NOVAPAY_DEBUG is unset

# Box-wide memory snapshot (capture before/during/after any memory experiment)
free -h

# Systemd service memory accounting (includes cgroup high/max/available/peak)
systemctl status payment-api --no-pager
# Look for: Memory: X.XM (high: 96.0M max: 128.0M available: 0B peak: X.XM)
```

---

## Agentic workflow addition

**INC-007 lifecycle via GitHub MCP:**
Issue #6 opened at https://github.com/ChiragVenkateshaiah/novapay-sre/issues/6
before a single line of balloon code was written. Body documented trigger,
expected behavior, safety bound, blast-radius proof plan, and counterfactual.
To be closed by the Day 12 commit that bakes MemoryHigh/MemoryMax permanently
into the unit files (ADR-011).

**Gate-and-confirm discipline:**
Today's session established a multi-gate confirmation protocol:
1. INC opened → 2. code written → 3. /check → 4. /deploy-dry-run → 5. deploy →
6. cgroup cap confirmed → 7. NOVAPAY_DEBUG=1 drop-in → 8. endpoint confirmed
live in journald → 9. Postgres baseline → "confirmed, proceed" → 10. balloon →
11. teardown verified → 12. invariant 0 rows.
Each gate produces literal observed output before proceeding. This pattern is now
documented in the session as the Day 11 observation protocol.

**Discipline signal logged:**
Strong personal pull toward the SRE break/observe/contain/verify/teardown loop
noted in checkpoint.md as a data point for the Week-20 ADR-007 decision.

---

## LinkedIn article notes

- **Hook:** "I OOM-killed my own payment service — on purpose — to prove Postgres
  would survive. Here's the exact output."
- **Strong numbers:**
  - MemoryMax=128M on a 911MB box (14% of total RAM) = structural containment
  - available memory went from 479Mi → 495Mi after the kill (box never stressed)
  - `constraint=CONSTRAINT_MEMCG` in dmesg — the one line that proves cgroup-scoped
  - 5-second restart gap, charge succeeds immediately after
  - Postgres PID 925 running continuously since 03:24:37 — never restarted
- **What NOT to make it about:** Kubernetes memory limits (that's cgroup v2 too,
  but the systemd/bare-metal angle is more differentiated); "crash loops are bad"
  (controlled crash loops with observability are a debugging tool)
- **What resonates for senior engineers:** the ordering discipline — cap first, env
  second, balloon third — and why reversing that order is catastrophic on a
  co-resident Postgres box with zero swap. The line "we do not run the
  counterfactual; the contained version proves the defence" is the SRE angle.

---

## Handoff to Day 12

**Status:** Day 11 complete ✓ · commit pending (D11 tag)

Day 12 closes INC-007 by baking `MemoryHigh`/`MemoryMax`/`OOMScoreAdjust`/
`StartLimit*` permanently into the systemd unit files as IaC (Ansible). The
transient `set-property` approach used today is intentionally temporary — it
proves the values work before committing them. Day 12 makes them permanent and
verifiable from the committed repo rather than from a running instance's
ephemeral state.

**Day 12 starts with:**
1. `/check` — build + vet + local invariant (0 rows required)
2. Read `infrastructure/systemd/payment-api.service` — baseline before edits
3. Add `MemoryHigh=128M`, `MemoryMax=192M`, `OOMScoreAdjust=+200`,
   `StartLimitBurst=5`, `StartLimitIntervalSec=60` to the unit file
   (values from week-02-plan.md: payment-api gets generous headroom over the
   1.9MB observed baseline; Day 11's 128M MemoryMax becomes the permanent cap)
4. Add same to `fake-psp.service` with tighter values (`MemoryHigh=64M`,
   `MemoryMax=96M`)
5. Verify budget arithmetic: sum(MemoryMax) + Postgres reserve < 911MB
6. `/deploy-dry-run` → deploy → `systemctl show` confirms values on EC2
7. Re-run Day 11 balloon under the permanent cap to prove baked-in limits
   contain it exactly as the transient one did
8. Confirm `NOVAPAY_DEBUG` is OFF in deployed config (`/debug/balloon` → 404)
9. Commit ADR-011 + close INC-007 via GitHub MCP
