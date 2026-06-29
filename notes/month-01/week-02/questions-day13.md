# Daily Learning Questions — Day 13
*Paste these into Claude.ai chat to dig deeper on each topic.*

---

## Go Fundamentals
*(Anchored to Day 13 concepts: package-level variables, goroutine lifecycle,
file I/O under ENOSPC, and signal-driven fd reopen)*

1. **[Basic]** In Go, what is the difference between a package-level variable and
   a local variable declared inside a function? Which one can the garbage collector
   reclaim, and why?

2. **[Basic]** When a Go function writes to a file and the filesystem is full,
   what does `f.Write(data)` return? How do you check for the specific ENOSPC error
   vs. any other write error?

3. **[Applied]** In `debug.go`, `balloon [][]byte` is declared at package level
   (outside any function). The `handleBalloon` handler appends a new slab to it
   each call. Explain why the garbage collector cannot free any slab from a previous
   call — even after the HTTP request that triggered that call has completed and the
   handler has returned.

4. **[Applied]** The `handleBalloon` goroutine does not check `r.Context().Done()`
   inside its page-fault loop. When curl disconnects (because `-m 30` fires), the
   goroutine keeps running. Rewrite the inner loop so it stops as soon as the client
   disconnects. What is the trade-off of adding that check vs. leaving the loop alone?

5. **[Deep]** In `payment-api/main.go`, the SIGHUP signal handler reopens the
   audit log file descriptor. Go's `signal.Notify` runs the signal in the process's
   main goroutine? its own goroutine? neither? Explain the actual signal-delivery
   mechanism in Go's runtime, and why a buffered channel (`make(chan os.Signal, 1)`)
   is used instead of an unbuffered one.

---

## Linux & Systems
*(Based on Day 13: cgroup v2 memory accounting, OOM scoring, loop devices,
ENOSPC at the VFS layer, and systemd drop-in mechanics)*

1. **[Basic]** What is a loop device in Linux? What command turns a regular file
   into a mountable block device, and what happens to the loop device entry in
   `/dev` after you `umount` it?

2. **[Basic]** What does `ENOSPC` stand for, and at which layer of the Linux
   storage stack is it produced — the VFS layer, the filesystem (ext4), or the
   block device driver? Can a process receive ENOSPC even if the physical disk has
   free space? Explain.

3. **[Applied]** The gauntlet's Stage 3 runs `sudo logrotate -f /etc/logrotate.d/novapay`
   followed by `systemctl kill -s HUP payment-api.service` (in the postrotate
   script). Walk through what happens to the audit log file descriptor between the
   moment logrotate renames `transactions.log` to `transactions.log.1` and the
   moment the SIGHUP handler calls `os.OpenFile` on the new `transactions.log`.
   During that window, where do audit log writes go?

4. **[Applied]** In today's dmesg output, the OOM kill record said
   `constraint=CONSTRAINT_MEMCG`. What is the other possible value, when would you
   see it instead, and which one is more dangerous for a co-resident database?
   Describe exactly what `OOMScoreAdjust=500` on fake-psp means numerically to the
   kernel's badness calculation.

5. **[Deep]** The gauntlet's Stage 4 checked `S4_UMOUNT_OK` before deleting the
   backing file. Explain what would happen at the kernel level if you ran
   `rm -f backing.img` while a loop device still had the file open and mounted.
   Why can this leave the filesystem in a state that is difficult to recover
   without a reboot?

---

## Shell & Scripting
*(Based on the gauntlet script design: pipefail edge cases, exit codes,
process substitution, and cleanup correctness)*

1. **[Basic]** What does `set -e` do in a bash script? Why did the gauntlet
   explicitly NOT use it, even though `set -e` is commonly recommended?

2. **[Basic]** `grep -c pattern file` exits with code 1 when there are 0 matches
   and still writes `"0"` to stdout. Explain why `COUNT=$(grep -c pattern file || echo "0")`
   produces the string `"0\n0"` instead of `"0"`, and what the correct fix is.

3. **[Applied]** The gauntlet uses `KEY_PREFIX="g$(date +%s)-$$"` to generate
   unique idempotency keys per run. What does `$$` expand to in bash? Why is
   combining the epoch timestamp with `$$` more collision-resistant than using
   `$(date +%s)` alone?

4. **[Deep]** The Stage 4 cleanup block uses this pattern:
   ```bash
   S4_UMOUNT_OK=true
   if ! sudo umount "${MOUNT_POINT}" 2>/dev/null; then
       S4_UMOUNT_OK=false
       sudo lsof +D "${MOUNT_POINT}" 2>/dev/null || true
   fi
   ```
   Why is the explicit boolean variable `S4_UMOUNT_OK` preferable to evaluating
   the umount exit code inline with `&&` chaining at the PASS/FAIL decision point?
   What subtle bug could appear if you used `&&` chaining across multiple cleanup
   steps instead?

---

## Ansible
*(Based on today's dry-run gate + ad-hoc baseline capture)*

1. **[Basic]** What is the difference between `ansible -m shell` (ad-hoc) and
   `ansible-playbook` (playbook)? When would you prefer each?

2. **[Applied]** The dry-run used `--check --diff`. The `--check` flag prevents
   changes; the `--diff` flag shows file content differences. When a task shows
   `changed` in check mode but no diff, what does that indicate about that task's
   idempotency?

3. **[Deep]** The gauntlet creates systemd drop-in files directly via `sudo tee`
   on EC2, not via Ansible. What is the Ansible-idiomatic way to manage drop-in
   files, and why is it acceptable to bypass Ansible here for ephemeral test
   artefacts? Where is the line between "this should be IaC" and "this is safe
   to do by hand"?

---

## Cloud & AWS Concepts
*(Connecting today's single-node resource accounting to AWS-native patterns)*

1. **[Basic]** Today's budget arithmetic showed: payment-api MemoryMax 192 MiB +
   fake-psp 96 MiB + Postgres ~44 MiB + OS = ~462 MiB of 911 MiB. On a t3.micro
   with 1 GiB RAM and no swap, what happens to the box if total RSS reaches ~850 MiB?
   How does the system-wide OOM killer differ in behavior from the cgroup-scoped kill?

2. **[Applied]** The gauntlet proved all five Week 2 defences are reproducible via
   `ansible-playbook deploy.yml` alone — no post-deploy manual steps. In AWS terms,
   this is the property that makes an AMI vs. user-data distinction meaningful.
   Explain the difference between baking a configuration into an AMI vs. applying
   it via user-data on first boot, and which approach the current NovaPay IaC most
   closely resembles.

3. **[Deep]** Journald is capped at 200M on the 8 GB root volume. At Day 13,
   journald is at 164.3M — 82% of the cap. In a production AWS environment, what
   CloudWatch metric would you create to alert before the cap is hit? What is the
   correct threshold (% of cap) to alert at, given that journald rotation is not
   instantaneous? Describe the alert → runbook → resolution chain for this specific
   case.

---

*Difficulty guide: Basic = recall and understand · Applied = use in context ·
Deep = explain the why and the trade-offs*
