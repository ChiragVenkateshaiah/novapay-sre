# Day 09 — INC-006 Disk-Fill Observation: ENOSPC Without a Broken Charge

**Date:** 2026-06-22
**Phase:** Phase 1 · Week 2 · Linux & Systems Foundations
**Status:** complete ✓
**Commits:** `393f44c` (ADR-008/012/013 + runbook + /check), `6c60b68` (checkpoint cleanup), `b4c2197` (checkpoint locked-decisions restored)

---

## Goal

Prove the ADR-009 resilience claim under real conditions: a completely full audit-log
filesystem (ENOSPC) must degrade observability without degrading correctness. Every
charge must still return 200, the ledger invariant must hold, and the failure must
surface in journald — not silently disappear. The observation also surfaced a second,
unplanned failure: a security-group port restriction that caused an 11-minute silent
hang, which became ADR-013 and a new pre-flight guard in `/check` and the runbook.

---

## What was actually built

No application code changed today. All work was documentation, tooling guards, and
ADRs derived from what the observation revealed.

### `docs/decisions/ADR-008-terraform-deferred-to-phase-4.md` (new)

Boundary record for the Week-2 Terraform deferral decision. Documents the three
implementation questions the idea reached before being declined, the false-confidence
risk of learning HCL syntax at 3-resource scale, and the ADR-013 link (manual
provisioning's inability to detect SG drift is the cost of this deferral until
Phase 4).

### `docs/decisions/ADR-012-omnigent-meta-harness-deferred.md` (new)

Decision not to adopt Omnigent (multi-agent meta-harness) for the NovaPay agentic
workflow. Documents the evaluation done from first principles after Day 8 closed.
Core reasoning: NovaPay's value lives in the hand-built guardrail layer (deploy-
blocking hook, ADR constraints, incident lifecycle), not in which orchestration
framework sits underneath it. A meta-harness is an answer to a question NovaPay
has not asked.

### `docs/decisions/ADR-013-preflight-checks-over-subagent.md` (new)

Decision record for the INC-006 discovery: port 22 and port 8080 security-group
rules are independent and can drift independently. A validation subagent was
considered and rejected — the failure was one binary fact (is port 8080 reachable)
answerable by one curl and an exit code. Documents the principle: a reachability
check is a fact with an exit code, not a judgment with a prompt.

### `scripts/disk-fill-demo.sh` — header comment + step 4 pre-flight (modified)

Added 3-line comment block to the file header:
```bash
# ADR-013 pre-flight: port 8080 and port 22 have independent SG rules.
# INC-006 produced an 11-min silent hang because SSH worked but the app port
# was blocked by a stale IP allowlist. Run step 4 before firing any charges.
```

Inserted new step 4 in the INSTRUCTIONS heredoc before "Fire charges" (original
steps 4–7 renumbered to 5–8):
```
4. Pre-flight: confirm port 8080 is reachable from the machine you will fire
   charges FROM (security group rules for different ports can drift independently
   of SSH access — this is exactly what produced an 11-min hang in INC-006):
     curl -m 5 http://<EC2_IP>:8080/healthz
   If this times out or fails, STOP. Check the EC2 security group inbound rules
   for port 8080 and confirm your current public IP is allowed. SSH working does
   NOT guarantee app ports are reachable — see ADR-013.
```

### `.claude/commands/check.md` — EC2 reachability step (modified)

Added optional step 5 to the `/check` command. Reads EC2 IP from
`infrastructure/ansible/inventory.ini` dynamically, runs a 5-second curl against
port 8080, and reports PASS (HTTP 200) or FAIL with an ADR-013 reference. Non-
blocking — the other four checks always complete regardless of EC2 state:

```bash
EC2_IP=$(grep ansible_host infrastructure/ansible/inventory.ini | grep -oP 'ansible_host=\K[^ ]+')
HTTP_CODE=$(curl -m 5 -s -o /dev/null -w "%{http_code}" "http://${EC2_IP}:8080/healthz" 2>/dev/null || echo "FAIL")
if [ "${HTTP_CODE}" = "200" ]; then
  echo "EC2:8080 PASS (HTTP 200)"
else
  echo "EC2:8080 FAIL (got '${HTTP_CODE}') — check security group inbound rules for port 8080; SSH access does not guarantee app-port reachability — see ADR-013"
fi
```

### `CLAUDE.md` — three new architectural constraint lines (modified)

```
- Terraform is not introduced before Phase 4; EC2/SG/key-pair provisioning
  remains manual + Ansible-managed until then → ADR-008
- No meta-harness (Omnigent or equivalent); single Claude Code CLI agent with
  Sonnet/Opus split is the workflow ceiling → ADR-012
- Pre-flight checks (network reachability, environment state) are deterministic
  shell guards, not LLM subagents; port 22 and port 8080 SG rules are independent
  — SSH access does not guarantee app-port reachability → ADR-013
```

The stale placeholder `ADR-008 reserved for Phase-4 Terraform boundary decision —
do not create before Phase 4` was replaced with the actual constraint now that
ADR-008 exists.

### `checkpoint.md` (modified)

- Last updated line bumped to 2026-06-22
- Locked-decisions section: long Terraform paragraph removed (content now lives in
  ADR-008); one-line ADR pointer appended below the bullet list:
  `Workflow and tooling decisions are recorded as ADRs in docs/decisions/ — see ADR-008 (Terraform), ADR-012 (Omnigent), ADR-013 (pre-flight validation).`
- Stale `See Locked decisions.` reference in the Week-1 agentic log updated to
  `see ADR-008.`

---

## Core concept — Filesystem Isolation and the ENOSPC Failure Mode

### The concept explained from first principles

A Linux filesystem is a block device formatted with a filesystem type (ext4, xfs,
etc.) and mounted at a path. Writes to that path consume blocks from that device
until the device is full. At that point, any write returns `ENOSPC` — error 28,
"No space left on device."

A **loopback device** is a kernel abstraction that treats a regular file as a block
device. `fallocate -l 64M disktest.img` pre-allocates a 64MB file on the
underlying filesystem (root, in this case). `mkfs.ext4 disktest.img` writes an
ext4 filesystem structure inside that file. `mount -o loop disktest.img
/mnt/novapay-logtest` asks the kernel to use the loop driver to expose the file as
a block device (`/dev/loop0` or similar) and mount it at the given path.

Once mounted, writes to `/mnt/novapay-logtest/` consume blocks from the 64MB
ext4 filesystem — **not** from the underlying root filesystem. The root filesystem
only pays the cost of the backing file itself (64MB, allocated upfront by
`fallocate`). The critical invariant: `df -h /` before and after the fill shows
identical free space (minus the backing file, which was already there at mount
time). The fills go into the loop device; root is structurally insulated.

### Why it matters for a payments service specifically

`payment-api` writes to its audit log on every charge. In production, the audit
log path (`/var/log/novapay/transactions.log`) lives on the same root volume as
the Postgres data directory, the Go binary, and the OS. If the audit log fills the
root filesystem, three things happen in sequence:

1. The audit write returns ENOSPC.
2. On the next charge, Postgres cannot write its WAL — Postgres crashes or stalls.
3. `payment-api` cannot commit the transaction — the charge fails with 500.

The ledger invariant is broken not by a logic bug but by a storage failure.
ADR-009's resilient write (audit ENOSPC → journald ERROR, charge returns 200) is
a first line of defence, but it only holds while root is not yet full. Day 10's
logrotate + retention closes the gap at the policy level.

### The broken pattern — what was demonstrated

INC-006 deliberately filled the audit-log filesystem to 100%:

1. 64MB loopback fs mounted at `/mnt/novapay-logtest`.
2. `dd if=/dev/zero of=/mnt/novapay-logtest/filler bs=1M count=60` — fills ~94%.
3. `dd if=/dev/zero of=/mnt/novapay-logtest/filler2 bs=1M` — fills to 100% (dd
   exits with ENOSPC itself, expected).
4. `systemctl set-property payment-api.service Environment=TRANSACTION_LOG_PATH=...`
   redirected writes to the full filesystem.
5. 5 charges fired.

Result from journald (actual observed output):

```
Jun 22 ... payment-api[...]: ERROR audit log write failed err="write /mnt/novapay-logtest/transactions.log: no space left on device"
Jun 22 ... payment-api[...]: INFO  charge complete payment_id=<uuid> idempotency_key=inc006-fill-1 status=approved latency_ms=94
Jun 22 ... payment-api[...]: ERROR audit log write failed err="write /mnt/novapay-logtest/transactions.log: no space left on device"
Jun 22 ... payment-api[...]: INFO  charge complete payment_id=<uuid> idempotency_key=inc006-fill-2 status=approved latency_ms=3
[repeated for charges 3, 4, 5 — all latency_ms=3]
```

Every charge returned HTTP 200 and "approved". The audit trail had 0 new lines
(the file could not be written). The DB had 5 new rows. Invariant: 0 unbalanced
rows.

### The correct pattern — what replaced it

Nothing was "replaced" — ADR-009's design held exactly as written. The correct
pattern is the `auditWriter` already in `main.go`:

```go
func (w *auditWriter) Write(p []byte) (int, error) {
    _, err := w.f.Write(p)
    if err != nil {
        slog.Error("audit log write failed", "err", err)
    }
    return len(p), nil  // always return nil — caller sees success
}
```

The key design decision: returning `nil` to the slog caller means slog does not
suppress future write attempts. If ENOSPC is temporary (e.g. a file was deleted),
the next write succeeds. If it is permanent, every charge produces one ERROR in
journald — a clear, per-charge signal to the operator — without the charge path
branching on the audit result.

### The failure cascade — what happens at scale

If log rotation is absent and the audit log lives on root (no loopback isolation):
- At ~2.8G of charges on a t3.micro, the root filesystem reaches 100%.
- Next Postgres WAL write returns ENOSPC → Postgres enters recovery mode or
  panics, depending on the WAL write failure path.
- `payment-api` can no longer commit transactions → all charges return 500.
- The `systemd` `Restart=on-failure` kicks in → payment-api restarts → it cannot
  open its audit log → `initAuditLog()` logs ERROR, sets `txLog=nil` → service
  starts but journald itself may also be failing to write to a full disk.
- At this point the box is effectively bricked: no charges, no logs, Postgres
  potentially corrupt if the WAL write was mid-transaction.

Day 10's logrotate + `SystemMaxUse` on journald prevents the disk from reaching
this state under normal operation.

---

## What was observed

### INC-006 disk-fill (on EC2, charges fired from localhost on the box)

**Before fill — `df -h /`:**
```
Filesystem      Size  Used Avail Use% Mounted on
/dev/root       6.8G  3.9G  2.8G  60% /
```

**Loop fs at 100% — `df -h /mnt/novapay-logtest`:**
```
Filesystem      Size  Used Avail Use% Mounted on
/dev/loop0       55M   55M     0 100% /mnt/novapay-logtest
```

**Journald during charges (5 charges, exact output):**
```
ERROR audit log write failed err="write /mnt/novapay-logtest/transactions.log: no space left on device"
INFO  charge complete payment_id=... status=approved latency_ms=94
ERROR audit log write failed err="write /mnt/novapay-logtest/transactions.log: no space left on device"
INFO  charge complete payment_id=... status=approved latency_ms=3
[×3 more — all latency_ms=3]
```

**Latency detail:**
- Charge 1 (first after redirection): 94ms
- Charges 2–5: 3ms each
- Interpretation: the first charge opens and fails to write the file handle (cold
  path); subsequent charges find the same pre-opened handle and fail immediately
  (hot path). ENOSPC is fast and stable — not a degrading or escalating cost.

**Ledger invariant after 5 charges:**
```
 payment_id | debits | credits
------------+--------+---------
(0 rows)
```

**After teardown — `df -h /`:**
```
Filesystem      Size  Used Avail Use% Mounted on
/dev/root       6.8G  3.9G  2.8G  60% /
```
Root unchanged. Structural containment proven.

### Unplanned: INC-006 security-group hang (from WSL2)

Initial attempt to fire charges from WSL2 (the intended path for the runbook):

```bash
for i in $(seq 1 5); do
  curl -s -X POST http://18.60.42.210:8080/charge \
    -H "Content-Type: application/json" \
    -d '{"idempotency_key":"inc006-fill-'$i'",...}'
  echo ""
done
```

Result: **zero output for 11 minutes 15 seconds**. No error, no timeout, no
journald entries on EC2.

**Diagnosis via AWS CLI:**

```json
// aws ec2 describe-instances --instance-ids i-0b65d9fb63ede2e26 ...
"SecurityGroups": [
  { "GroupId": "sg-0a61886f7e6077913", "GroupName": "launch-wizard-1" }
]

// aws ec2 describe-security-groups --group-ids sg-0a61886f7e6077913
"IpPermissions": [
  {
    "IpProtocol": "tcp", "FromPort": 22, "ToPort": 22,
    "IpRanges": [{ "CidrIp": "49.43.241.98/32" }]
  }
]
```

**Findings:** port 8080 has no inbound rule at all — the entry is entirely absent
from `IpPermissions`. Port 22 is open to a single IP (`49.43.241.98/32`). SSH
worked because that IP is the current WSL2 public IP. The port-8080 rule did not
exist at all on the security group; there was no stale or mismatched CIDR to find,
just a missing entry. SSH working gave false confidence — a security group has
one rule per port, each rule managed independently, and the absence of a port-8080
rule was invisible to every service-layer tool.

The hang was curl's default no-timeout behaviour against a firewall that drops
packets silently (no TCP RST, no ICMP unreachable — just silence).

**Note on console vs CLI:** an edit attempt via the AWS console appeared to reflect
a change but did not persist — confirmed by re-running `aws ec2
describe-security-groups` directly, which showed the rule still absent. The AWS
CLI/API is the authoritative source; the console view can be stale or misleading
about whether a save actually committed. When a console-based change doesn't take
effect as expected, verify via CLI rather than re-checking the same console view.

### `/check` EC2:8080 canary — end-of-day verification

After restoring the port 8080 SG rule:

```
1. payment-api build    → PASS
2. fake-psp build       → PASS
3. go vet               → PASS
4. Ledger invariant     → PASS — 0 rows
5. EC2:8080 reachability → EC2:8080 PASS (HTTP 200)
```

The canary works end to end. Had step 5 been in `/check` before the Day 9 charges
were fired from WSL2, it would have caught the missing port-8080 rule instantly.

---

## Acceptance criteria — all met ✓

- [x] Loop fs capped at 64M; `df -h /` root free space unchanged before/during/after.
- [x] During fill: `df -h /mnt/novapay-logtest` = 100%; charges return 200; `count(*)`
      increments (5 new rows); invariant 0 rows.
- [x] `journalctl -u payment-api` shows the ENOSPC write error per charge during full window.
- [x] Clean teardown: unmounted, backing file removed, root reclaimed, services healthy,
      invariant 0 rows.
- [x] ADR-008, ADR-012, ADR-013 committed.
- [x] `disk-fill-demo.sh` has pre-flight step referencing ADR-013.
- [x] `/check` has EC2:8080 reachability step; end-of-day run shows PASS.
- [x] INC-006 observation comment posted to GitHub issue #5.
- [x] checkpoint.md updated; locked-decisions section restored with ADR pointer.

---

## Problems hit

### 1. Port 8080 missing from EC2 security group — 11m15s silent hang

**Error observed:** `curl` loop hung completely for 11 minutes 15 seconds. Zero
output, zero journald entries on EC2.

**Root cause:** EC2 security group `sg-0a61886f7e6077913` had no inbound rule for
port 8080 at all — the rule was entirely absent, not stale or pointing at an old
IP. Port 22 had a correct, working rule (`49.43.241.98/32`). SSH worked; the app
port was firewalled. The firewall drops packets silently (no RST, no ICMP), so
curl's default no-timeout behaviour produced an indefinite hang.

**Why it wasn't caught earlier:** every diagnostic tool available — `/healthz`
(reports the app), `systemctl status` (reports the unit), `journalctl` (reports
the logs) — works at the service layer. None sits at the WSL2-to-EC2 network
boundary. SSH working actively obscured the failure.

**Fix applied:** port 8080 inbound rule added via AWS CLI (confirmed authoritative
via `describe-security-groups` — a prior console edit attempt did not persist):
```bash
aws ec2 authorize-security-group-ingress \
  --group-id sg-0a61886f7e6077913 \
  --protocol tcp --port 8080 \
  --cidr 49.43.241.98/32 \
  --region ap-south-2
```
The runbook and `/check` were updated with a `curl -m 5` pre-flight step (ADR-013).

**Lesson:** SSH reachability and app-port reachability are independent properties.
A security group has one rule per port; a missing rule and a stale rule are both
invisible to service-layer tools. When a console-based SG change doesn't take
effect, verify via `aws ec2 describe-security-groups` directly — the CLI/API is
authoritative; the console view can be stale about whether a save committed.

### 2. `checkpoint.md` locked-decisions section was removed then needed back

During the session, the locked-decisions section was removed as specified in the
original task. The user then requested it be restored (with the ADR pointer kept
as well). Three commits resulted: `393f44c` (add ADRs), `6c60b68` (remove
section), `b4c2197` (restore section with pointer). A minor churn in the commit
history, but each commit was correct for its stated purpose.

---

## Commands worth keeping

### AWS CLI — EC2 and security group inspection
```bash
# Find EC2 instance ID and security groups by public IP
aws ec2 describe-instances \
  --filters "Name=ip-address,Values=18.60.42.210" \
  --query 'Reservations[0].Instances[0].{InstanceId:InstanceId,SecurityGroups:SecurityGroups}' \
  --output json

# List all inbound rules for a specific security group
aws ec2 describe-security-groups \
  --group-ids sg-0a61886f7e6077913 \
  --region ap-south-2 \
  --output json

# Add an inbound rule for a port (replace CIDR with your IP /32 or 0.0.0.0/0)
aws ec2 authorize-security-group-ingress \
  --group-id sg-0a61886f7e6077913 \
  --protocol tcp --port 8080 \
  --cidr <YOUR_IP>/32 \
  --region ap-south-2
```

### Loopback filesystem — setup and teardown
```bash
# Create a bounded backing file (kernel enforces the size cap)
fallocate -l 64M /opt/novapay/disktest.img

# Format as ext4 (quiet)
mkfs.ext4 -q /opt/novapay/disktest.img

# Mount via loop device
mkdir -p /mnt/novapay-logtest
mount -o loop /opt/novapay/disktest.img /mnt/novapay-logtest

# Verify it's a separate block device from root
df -h /mnt/novapay-logtest   # shows /dev/loopN, not /dev/root

# Fill to ~94% (leaves headroom for file metadata)
dd if=/dev/zero of=/mnt/novapay-logtest/filler bs=1M count=60

# Fill to 100% — dd itself will exit with ENOSPC (expected)
dd if=/dev/zero of=/mnt/novapay-logtest/filler2 bs=1M

# Teardown
umount /mnt/novapay-logtest
rm -f /opt/novapay/disktest.img
rmdir /mnt/novapay-logtest
```

### systemd drop-in environment override (non-destructive, reversible)
```bash
# Override a single env var for a unit without editing the unit file
sudo systemctl set-property payment-api.service \
  Environment="TRANSACTION_LOG_PATH=/mnt/novapay-logtest/transactions.log"
sudo systemctl restart payment-api

# Revert to the unit's original environment (removes the drop-in)
sudo systemctl revert payment-api
sudo systemctl daemon-reload && sudo systemctl restart payment-api

# Confirm which environment vars are in effect
systemctl show payment-api --property=Environment
```

### Pre-flight reachability check (ADR-013 pattern)
```bash
# Quick port probe from WSL2 before firing any charges
curl -m 5 http://<EC2_IP>:8080/healthz
# Exit 0 + HTTP 200 = app reachable.
# Timeout or non-200 = STOP, fix SG rule first.
```

---

## Agentic workflow addition

**EC2:8080 reachability step in `/check` (ADR-013 canary)**

The workflow now has a permanent, automatically-run guard against the silent-hang
class of failure. Every `/check` run tests whether the EC2 app port is reachable
from WSL2 — not just whether the service is running on EC2. The step reads the IP
from `inventory.ini` dynamically (no hardcoded IPs) and reports PASS or FAIL with
the ADR-013 reference, but never blocks the four core checks from completing.

**GitHub MCP — INC-006 observation comment**

INC-006 (#5) received a structured resolution comment documenting the exact
observed output (journald lines, latency numbers, invariant result, root-volume
snapshots) and the latency detail (94ms first charge, 3ms subsequent). The issue
stays open for Day 10's defence phase. This follows the same pattern as INC-003
through INC-005: observe → comment → leave open → close on the defence commit.

**ADR corpus: 008, 012, 013 added**

The ADR library now covers tooling decisions (Terraform deferral, Omnigent
deferral) in addition to code decisions. This is new territory — all prior ADRs
were about the application or the system; these three are about the project's
own tooling and methodology. The precedent is now set for recording infrastructure
and workflow decisions in the same canonical format.

---

## LinkedIn article notes

**Strongest technical angle:**
"SSH said the box was reachable. It was — but the app port was firewalled. Eleven
minutes of silence taught me that reachability is per-port, not per-host."

**Specific numbers worth using:**
- 11m15s hang with zero output — the concrete pain of the gap
- 94ms first charge under ENOSPC, 3ms for the next four — ENOSPC is not slow
- 0 unbalanced ledger rows during 100% disk fill — correctness held
- `df -h /` identical before and after — structural containment, not luck

**What NOT to make the article about:**
- The ADR writing process (too meta for this stage)
- Omnigent / meta-harness deferral (too niche for a broad engineering audience)
- The Terraform deferral (not the story of this day)

**The moment that resonates with a senior engineer:**
The SSH false-promise. Any engineer who has debugged a "service is running but
unreachable" issue will immediately recognise the trap: SSH works, `systemctl
status` is green, `journalctl` is clean — and the app is firewalled at the network
boundary that none of those tools can see. The instinct to "check the service" is
correct but insufficient. The fix is one curl with a 5-second timeout; the lesson
is that service-layer tools only see the service layer.

---

## Handoff to Day 10

**Status:** Day 9 complete ✓ · last commit `b4c2197`

Day 10 is the **defence phase** of INC-006. The observation (Day 9) proved the
failure mode is real and contained. Day 10 closes the gap so the failure cannot
occur under normal operation:

- **logrotate** configured for `/var/log/novapay/transactions.log`: daily rotation,
  7-day retention, `compress`, `delaycompress`, `postrotate` sends SIGHUP to
  payment-api to reopen the log file handle.
- **SIGHUP handler** in `payment-api`: closes `txLogWriter.f`, opens the new file
  (already scaffolded as `txLogWriter *auditWriter` at package level in ADR-009).
- **journald cap** (`SystemMaxUse` in `/etc/systemd/journald.conf`): prevents
  journald from consuming unbounded disk on the root volume.
- All three delivered as Ansible IaC (logrotate config + journald config as
  templates in `deploy.yml`), **not** manual SSH steps.
- **ADR-010** documents the rotation + reopen design.
- **INC-006 closed** on the Day 10 commit.

**Day 10 starts with:**
1. `/check` — confirm clean baseline (EC2:8080 canary should PASS)
2. `/ec2-invariant` — confirm ledger balanced on EC2
3. Confirm teardown from Day 9 is complete: `mount | grep novapay-logtest` returns
   nothing; `ls /opt/novapay/disktest.img` returns "no such file"
4. Confirm `payment-api` is running with default `TRANSACTION_LOG_PATH`
   (i.e. `systemctl revert` was run and service restarted after Day 9 teardown)
5. Write SIGHUP handler in `main.go` → build → test locally
6. Write logrotate config → write Ansible task to deploy it
7. Test rotation locally: force rotate, send SIGHUP, confirm new file receives
   the next charge's audit line
8. Deploy to EC2, confirm log rotation is live, close INC-006
