# Article Draft: "Designing a payments box that can't fill its own disk"

**Target:** LinkedIn long-form post
**Status:** draft — Day 13 (rewritten)
**Publish:** Day 14

---

## Draft

---

The `dd` command exited the way I wanted it to:

```
dd: writing to '/mnt/novapay-audit-test/fill': No space left on device
```

A 64 MB loopback filesystem, mounted, then filled byte-for-byte until the kernel refused to give me one more block. I had pointed my payments service's audit log at that filesystem on purpose. Then I fired a charge into it and waited to watch something break.

```
HTTP 200  {"payment_id":"...","status":"approved"}
HTTP 200  {"payment_id":"...","status":"approved"}
HTTP 200  {"payment_id":"...","status":"approved"}
```

Three charges, three 200s, money moved, ledger balanced. The disk the service writes to was completely full and the service did not care. That is the correct behaviour — and getting to the point where I could say that with a straight face took a week of being wrong first.

The thing being filled is an audit log. NovaPay is a small payments platform I'm building on a single t3.micro — 1 vCPU, 1 GB of RAM, an 8 GB root volume — running a Go payment API, a fake PSP (a stub bank I can make fail on command), and PostgreSQL holding a double-entry ledger. Every charge writes two ledger rows that must sum to zero, and every charge also appends one JSON line to `/var/log/novapay/transactions.log`: idempotency key, payment ID, amount, status, timestamp. That file is the human-readable record an operator or a compliance process reconciles against the database at end of day.

My first instinct for the failure case was the obvious one, and it was wrong: if you can't write the audit log, fail the charge. Refuse the money. Safe, conservative, defensible in a meeting. Except it inverts the entire system. By the time the audit write runs, Postgres has already committed the debit and the credit inside one transaction. The charge *happened*. To "fail" it now, I'd have to roll back a committed database transaction because a log file write returned an error — which means I've quietly promoted a log file to the role of distributed coordinator, and made it the arbiter of whether money moved. A file append is a far less reliable thing than a Postgres commit. You do not let the weaker component overrule the stronger one.

So the principle I settled on is the inversion of the instinct: **the audit log records what happened; it does not decide whether it happened.** The ledger is the source of truth. The log is an observer. If the observer can't write, the observer logs its own failure and the charge proceeds. In Go that's three lines, and the comment is the whole point:

```go
if err := writeAuditEntry(entry); err != nil {
    slog.Error("audit write failed", "err", err, "payment_id", paymentID)
    // charge is committed — we do NOT return an error to the caller
}
```

That's what the experiment proved. While those three charges returned 200, journald carried the other half of the story:

```
payment-api[8459]: ERROR audit write failed err="write /mnt/novapay-audit-test/transactions.log: no space left on device"
```

Loud, specific, and pointed at the exact cause — without ever touching the money path. Afterwards the invariant query returned zero rows: every charge produced exactly one debit and one credit summing to zero. The audit trail had a gap; the ledger did not. Those are supposed to be two independent statements, and the experiment is what lets me make them independently.

But "the service survives a full disk" only matters if the disk doesn't fill silently in the first place, on a box where the API, the database, and the logs all share one root filesystem. So the real defence runs earlier. The audit log is rotated by logrotate at 50 MB, seven compressed generations — and the detail that earns a senior engineer's nod is in the `postrotate` hook. A file descriptor refers to an inode, not a path. When logrotate renames `transactions.log` to `transactions.log.1` and creates a fresh empty file at the old name, my process is still holding an open fd to the *renamed* inode. It happily keeps writing to a file that, as far as anyone listing the directory is concerned, is the wrong one. So `postrotate` sends `SIGHUP`, the Go process catches it, opens the new path, swaps the fd under a write lock while in-flight appends drain, and closes the old one. I deliberately did *not* use `copytruncate`, the option most logrotate tutorials reach for, because it has an unpreventable window between copy and truncate where a line written in that gap exists in neither file. For an operational log, fine. For a financial audit trail, a missing line is an unexplained charge — and that is the kind of thing that turns into a regulatory finding, not a shrug.

I verified the handoff rather than trusting it. Force a rotation, then check that `transactions.log.1` has exactly the pre-rotation line count and the next charge lands as line one of a brand-new active file. Zero lines lost across the swap. The second vector — journald itself growing unbounded — is capped at `SystemMaxUse=200M`. Together that's a worst case of roughly 200 MB of audit plus 200 MB of journal against 2.8 GB free. The defence is arithmetic, not hope.

Disk is one finite resource on a 1 GB box; memory is the other, and it has a nastier failure mode. If the API leaks and the kernel's OOM killer fires system-wide, it might pick *Postgres* to kill — the one process holding the truth. So each service gets a cgroup-v2 cap (`MemoryMax=192M` for the API) and an explicit OOM-score ordering: fake-psp at 500, payment-api at 200, Postgres at 0. The stub bank dies first, the API next, the database last. When I drove the API into its cap during testing, dmesg showed the line I was hoping for:

```
oom-kill:constraint=CONSTRAINT_MEMCG, oom_memcg=/system.slice/payment-api.service, task=payment-api,pid=8459
```

`CONSTRAINT_MEMCG`, not `CONSTRAINT_NONE`. That one token is the difference between "the API's own cgroup hit its limit and the kernel killed only inside it" and "the whole machine ran out of memory and the kernel killed whatever it felt like." Postgres stayed active. The API restarted in five seconds and the next charge succeeded.

None of this is the part of the work I'd have predicted would be hardest. The hardest bug in the whole exercise was a shell idiom. My OOM detection counted dmesg matches with `grep -c "CONSTRAINT_MEMCG" || echo "0"`. When `grep -c` finds nothing it prints `0` *and* exits non-zero, so under `pipefail` the `|| echo "0"` fired too and the variable became `"0\n0"` — and every integer comparison after it died with `integer expression expected`. The fix is `|| true`, which suppresses the exit code without adding a second line of output. It is a stupid little bug and it cost me real time, and I'm including it because that is what learning a system from first principles actually looks like: the principles are clean, and the ground is covered in small sharp objects.

That's the honest frame here. I'm building this deliberately and verifying every claim on the live box, because the alternative — deploy and hope — is exactly the habit this whole project exists to break. The whole configuration is committed as Ansible: one `deploy.yml` against a fresh instance brings up the logrotate config, the journald cap, the memory limits, and the OOM ordering, with no manual step. A defence that needs a human to remember a post-deploy command is a defence that won't be there at 3 a.m. when you need it.

The money path stayed correct through every one of these — full disk, forced rotation, cgroup OOM kill. The system's loudest component is allowed to fail. The source of truth is not.

---

*Building NovaPay — a production-like payments system — as a structured learning environment for SRE and platform engineering. Day 13 of the build log.*

---

## Editorial notes for finalization (Day 14)

- Opens in the room: the `dd` ENOSPC line and the three 200s land before any explanation. The counterintuitive result is the hook, not a buried payoff.
- Narrative arc is intact: wrong instinct (fail the charge) → correct principle (log observes, ledger decides) → the rotation/journald defence that stops the disk filling at all → memory as the symmetric second resource → the `grep -c` bug as the honest human note → IaC reproducibility close.
- Load-bearing specifics kept and grounded in observed output: ENOSPC dmesg/journald lines, `200s=3 non-200s=0`, `CONSTRAINT_MEMCG` vs `CONSTRAINT_NONE`, SIGHUP fd-reopen vs copytruncate, the `"0\n0"` double-output bug, OOM ordering 500/200/0, PID 8459, t3.micro numbers.
- Section headers removed — it now reads as continuous prose, per the "too many breaks interrupted the story" note. No bullet lists in the body except the literal command/code output blocks.
- Length: ~1,200 words — in the 1000–1300 target.
- The `grep -c` bug doubles as the "honest about learning context" beat — keep it; it's the most relatable paragraph for the hiring-manager audience.
- Tags: #SRE #SystemsEngineering #Linux #Payments #Infrastructure
- Final pass before publish: confirm the JSON in the 200 responses matches the real handler output shape, and consider whether to name INC-006/INC-007 for readers following the series (currently omitted to keep it self-contained).
