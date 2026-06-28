# ADR-011 — systemd Memory Limit Strategy

**Date:** 2026-06-28
**Status:** Accepted
**Decider:** Chirag Venkateshaiah

---

## Context

NovaPay runs two Go services (`payment-api`, `fake-psp`) and Postgres on a single
t3.micro: 911 MB total RAM, zero swap, cgroup v2, systemd 255. Postgres holds the
double-entry ledger — the source of financial truth. There is no replica, no RDS,
no failover.

Day 11 (INC-007) established the problem by observation: at box startup, both app
services ran with `MemoryMax=infinity MemoryHigh=infinity`. Under that state, a
memory leak or traffic spike in `payment-api` competes directly with Postgres for
physical RAM. On a zero-swap box, exhausting available memory triggers the
**system-wide OOM killer**, which selects victims by OOM badness score across all
processes. Postgres, with its shared buffer pool, carries a naturally high score.
The kill selection is non-deterministic — Postgres could be chosen. An OOM kill of
Postgres mid-transaction loses uncommitted WAL data and takes the ledger offline
until recovery completes.

Day 11 also established the safety mechanism: cgroup v2 (`cgroup2fs`, unified
hierarchy) assigns each systemd service its own cgroup slice. A `MemoryMax` cap
on that slice activates the **cgroup-scoped OOM killer**, whose scope is strictly
the capped cgroup — it cannot touch sibling cgroups. `constraint=CONSTRAINT_MEMCG`
in dmesg is the proof token that a kill was cgroup-scoped rather than system-wide.

Day 11 used transient `systemctl set-property` to validate specific values before
committing them. This ADR bakes those values into the committed unit files as IaC.

---

## Decision

### 1. Two-stage containment: MemoryHigh (soft throttle) then MemoryMax (hard kill)

Both services carry two memory directives in their `[Service]` section:

| Service | MemoryHigh | MemoryMax |
|---|---|---|
| `payment-api` | 128 MB | 192 MB |
| `fake-psp` | 64 MB | 96 MB |

**The two stages serve distinct purposes:**

`MemoryHigh` is a soft reclaim throttle. When a cgroup's usage crosses this value,
the kernel slows the cgroup's page faults and begins reclaiming pages from it.
No kill occurs; the process stalls under memory pressure. This is the visible
signal that a service is growing unexpectedly — the stall manifests as slow HTTP
responses and `MemoryCurrent` pinned near `MemoryHigh` in `systemctl status`.

`MemoryMax` is a hard ceiling. When the cgroup cannot satisfy a new allocation
without exceeding this value, the cgroup OOM killer fires. It selects a victim
strictly within the cgroup — `constraint=CONSTRAINT_MEMCG` — and sends SIGKILL.
systemd catches the exit, records `Failed with result 'oom-kill'` in the journal,
and (with `Restart=on-failure`) schedules a restart.

Setting `MemoryHigh == MemoryMax` eliminates the throttle stage entirely. The
64 MB gap between MemoryHigh and MemoryMax on payment-api gives the kernel a
meaningful reclaim window before the hard kill fires. Day 11 observed this stall
phase empirically: RSS climbed slowly from 128 M toward 192 M over roughly two
minutes as the kernel throttled each page fault.

**Budget arithmetic (from Day 12 live EC2 measurement):**

| Component | Observed RSS | MemoryMax cap | Headroom |
|---|---|---|---|
| payment-api | 8.8 MB idle | 192 MB | 21× idle |
| fake-psp | 3.9 MB idle | 96 MB | 24× idle |
| Postgres (all workers) | ~75 MB | uncapped (intentional) | — |
| OS + kernel + journald | ~80 MB | — | — |
| Safety margin | — | 50 MB reserve | — |
| **Total worst-case** | — | **493 MB** | **418 MB free (46% of box)** |

Even if both services balloon to their `MemoryMax` simultaneously, the box retains
418 MB headroom. The cgroup OOM killer's scope is bounded to each service's own
cgroup — Postgres is structurally unreachable from either kill.

### 2. OOMScoreAdjust=+200 on both app services

`OOMScoreAdjust=200` is set in `[Service]` for both `payment-api` and `fake-psp`.

The Linux OOM killer scores every process by combining its memory footprint with
`/proc/PID/oom_score_adj` (range −1000 to +1000). A positive adjustment raises
the score — making the kernel *more* likely to kill that process under system-wide
memory pressure. Postgres runs at the default `oom_score_adj=0`.

**Why this matters beyond the cgroup cap:** the `MemoryMax` cap and its
cgroup-scoped OOM killer handle the nominal case — a single runaway service.
`OOMScoreAdjust` handles the tail case: genuine system-wide pressure not caused
by either app service (e.g., a kernel memory leak, a third process introduced
later, or both services approaching their caps simultaneously). In that scenario
the system-wide OOM killer fires, and without a score adjustment it makes a
non-deterministic choice. `OOMScoreAdjust=+200` on the app services biases the
kernel to kill them before Postgres under any pressure scenario — the ledger
survives regardless of the kill pathway.

The ordering guarantee is: **app services die before the ledger dies.** A dead
app service restarts in 5 seconds (`RestartSec=5s`). A dead Postgres mid-WAL is
an outage until recovery completes. This priority ordering is intentional and
non-negotiable for a co-resident single-box deployment.

### 3. Crash-loop guard: StartLimitBurst=5 / StartLimitIntervalSec=60

Both services carry in their `[Unit]` section (not `[Service]` — these directives
moved to `[Unit]` in systemd v229; placing them in `[Service]` on systemd 255 is
silently ignored):

```
StartLimitIntervalSec=60
StartLimitBurst=5
```

**Rationale:** `Restart=on-failure` combined with `MemoryMax` creates a structural
restart loop: OOM kill → systemd restart → service starts → OOM kill again, if the
root cause is not a transient spike but a genuine memory leak or misconfiguration.
Without a rate limit, this loop runs indefinitely — the service thrashes at full
restart cadence, consuming CPU and generating journal noise with no operator alert.

With `StartLimitBurst=5` and `StartLimitIntervalSec=60`: if five OOM kills
accumulate within any 60-second window, systemd stops restarting and enters
`failed (Result: oom-kill)`. This is visible in `systemctl status` and generates
a clean journal entry: `"Start request repeated too quickly."` The failed state
requires operator intervention (`systemctl reset-failed`) — making the crash loop
a detectable, actionable signal rather than silent thrash.

**Day 12 verification:** the crash-loop guard was triggered deliberately using a
transient `MemoryMax=20M` override (to achieve rapid kills). systemd entered
`failed` state after accumulating sufficient starts within a 60-second window.
`NRestarts=10` at the point of failure reflects cumulative restarts across the
entire session (including Part 4's single restart); the `StartLimitBurst` counter
is a separate sliding-window mechanism maintained internally by systemd.

### 4. Deployed as committed IaC

Memory limits are in the committed unit files at `infrastructure/systemd/`, not
applied via transient `set-property`. The distinction matters: `set-property`
writes to `/etc/systemd/system.control/<unit>.d/` (runtime, wiped by
`systemctl revert`). The committed unit files survive redeploys, instance
replacements, and future `systemctl revert` calls without losing the limits.

`deploy.yml` already copies both unit files and runs `daemon-reload` + restart —
no additional Ansible tasks are required. The limits are present on any box
provisioned from the committed repo.

---

## Alternatives rejected

| Alternative | Reason rejected |
|---|---|
| `MemoryMax` only, no `MemoryHigh` | Eliminates the throttle stage; the hard kill fires with no prior warning signal; no reclaim window for the kernel |
| One global slice limit (`system.slice`) | Less precise; a rogue process in any service could consume the entire slice budget; per-service caps provide tighter blast radius |
| Relying on kernel OOM defaults (no limits) | The original state (INC-007); system-wide OOM killer with non-deterministic victim selection; Postgres could be killed |
| `OOMScoreAdjust` on Postgres (negative, to protect it) | Protects Postgres in isolation but does not guarantee app services are chosen first; adjusting Postgres's score is also operationally fragile since Postgres is managed by its own package installer |
| `MemorySwapMax=0` to disable swap usage | Swap is already zero on this box; this directive would be a no-op and adds noise |
| Transient `set-property` as the permanent solution | Runtime-only; wiped by `systemctl revert`; not reproducible from the committed repo; not verifiable without SSH access to the live instance |

---

## Consequences

- Both app services are bounded to their `MemoryMax` values on every deployment,
  without manual post-deploy steps. `systemctl show <unit> -p MemoryMax,MemoryHigh`
  is the verification command.
- A runaway `payment-api` or `fake-psp` cannot exhaust box RAM. Postgres is
  protected by both the cgroup boundary (`CONSTRAINT_MEMCG`) and the OOM score
  ordering (`OOMScoreAdjust=+200`).
- Memory leaks in app services produce observable stalls at `MemoryHigh` before
  the hard kill — giving operators a signal window if monitoring is in place.
- Repeated OOM kills produce a `failed` state rather than infinite restart thrash,
  making the condition detectable and requiring explicit operator acknowledgement
  via `systemctl reset-failed`.
- `MemoryMax=192M` for payment-api is generous headroom over the 8.8 MB observed
  idle baseline. The cap should be revisited if Week 7's deep concurrency work
  (connection pooling, goroutine accumulation under load) materially raises the
  service's steady-state RSS.
- The `NOVAPAY_DEBUG=1` balloon endpoint (`debug.go`) remains compiled into the
  binary but is only registered in the HTTP mux at startup when the env var is
  present. It is never set in the committed unit files or drop-ins. Any accidental
  re-enablement is visible in the startup journal line:
  `"debug balloon endpoint enabled — NOT FOR PRODUCTION"`.
