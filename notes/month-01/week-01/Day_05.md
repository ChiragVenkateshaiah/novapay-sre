# Day 05 — Correct Process and Goroutine Lifecycle
**Date:** 2026-06-15
**Phase:** Phase 1 · Week 1 · Linux & Systems Foundations
**Status:** complete ✓
**Commit:** `a68b831`

---

## Goal
Replace a broken shell-out receipt generator (`exec.Command` without `.Wait()`)
with a correct in-process goroutine design. Learn the Linux process lifecycle
by observing zombie accumulation, then eliminate it structurally.

---

## What was actually built

### Part 1 — shell-out (deliberately broken, not committed)
```go
exec.Command("sh", "-c", "sleep 0.1 && echo receipt-ID >> /tmp/novapay-receipts.txt")
cmd.Start() // cmd.Wait() deliberately omitted — the bug
```

### Part 2 — zombie observation
15 charges fired → 15 `<defunct>` processes confirmed via:
```
ps aux | grep "[d]efunct"   — 15 rows, state Z, PPID 1770
ps -el | awk '$2 == "Z"'   — confirmed same 15
```

### Part 3 — in-process goroutine replacement (committed)
- Package-level buffered channel: `var receiptWorker = make(chan string, 50)`
- Single worker goroutine started in `main()` via `go receiptLoop()`
- `handleCharge` sends `paymentID` non-blocking (`select` with `default` — never delays the HTTP response path)
- `receiptLoop`: `for range` on channel, writes receipt, exits when channel closed
- SIGTERM handler: `signal.Notify` catches `SIGTERM`/`SIGINT`, `close(receiptWorker)` called, `sync.WaitGroup.Wait()` ensures worker drains before process exits

---

## Linux process concepts — the foundation

### 1. The process lifecycle on Linux
Every process is created by `fork()` — a copy of the parent. The child then calls `exec()` to replace itself with a new program. When the child finishes, it calls `exit()` and enters state `Z` (zombie) — it has stopped executing but its process table entry remains. The OS keeps it there so the parent can call `wait()` to collect the child's exit status (exit code, resource usage). Only after `wait()` does the OS remove the process table entry completely. This is called **reaping**. A process that has exited but not been reaped is a zombie. A process whose parent exits before reaping it is an orphan — orphans are adopted by PID 1 (init/systemd), which reaps them automatically.

### 2. What SIGCHLD is and why it matters
When a child process changes state (exits, stops, continues), the OS sends `SIGCHLD` to the parent. The default action is to ignore it. A parent that wants to reap children must either: install a `SIGCHLD` handler that calls `waitpid()`, or call `wait()`/`waitpid()` explicitly after starting the child.

`exec.Command().Run()` does this automatically — it calls `Wait()` internally.
`exec.Command().Start()` does NOT — it starts the child and returns immediately. The caller is responsible for calling `cmd.Wait()` later. If they never do, every child becomes a zombie.

### 3. Why zombie processes are dangerous
A zombie holds no memory, no CPU, no file descriptors. But it holds a process table entry, and each entry has a PID. Linux has a fixed PID limit (typically 32768 on most systems, viewable via `cat /proc/sys/kernel/pid_max`). At one zombie per successful charge, a payment service under sustained load will eventually exhaust all available PIDs — at which point the OS cannot fork any new processes at all. systemd cannot restart a crashed service. SSH cannot accept new connections. The system becomes unrecoverable without a reboot. This is **PID exhaustion** — the zombie's actual danger.

### 4. The 1:1 relationship observed
15 charges → 15 zombies, exactly. Each charge called `cmd.Start()` once. Each child ran `sleep 0.1`, wrote the receipt line, and exited. Each entered state `Z` and waited to be reaped. `payment-api` never called `cmd.Wait()`. The receipts were written correctly — the zombie's work was done. That is what makes this class of bug insidious: everything looks correct from the outside. The only signal is the growing defunct count in `ps`.

### 5. Orphan vs zombie — the distinction
- **Zombie:** child finished, parent alive, parent never called `Wait()`. Process table entry held open by the parent.
- **Orphan:** child still running, parent has exited. Adopted by PID 1, which will reap it automatically when it finishes.

In Day 5 the processes were zombies, not orphans: `payment-api` (the parent) was still running. The children had finished. The parent never reaped them.

---

## Why shell-out receipt generation created zombies

`exec.Command("sh", "-c", "...")` creates a child process via `fork+exec`. `cmd.Start()` starts it and returns immediately — `payment-api`'s goroutine continues to the next line. The child runs independently, writes the receipt, and exits. It enters state `Z`. `payment-api` never calls `cmd.Wait()`, so it never sends `SIGCHLD` acknowledgement, and the OS never clears the process table entry. Repeat for every charge: one new zombie per call.

The pattern:
```
handleCharge called
    ↓
charge succeeds, response written
    ↓
cmd.Start() forks child          ← child now exists, state S (sleeping)
    ↓
handleCharge returns             ← parent goroutine done, no Wait() queued
    ↓
child: sleep 0.1 completes
    ↓
child: echo >> /tmp/...
    ↓
child: exits → state Z (zombie)  ← waiting forever for parent to wait()
    ↓
payment-api: never calls Wait()  ← zombie persists until process exits
```

---

## What was observed (the zombie accumulation)

```
Command: ps aux | grep "[d]efunct"
Result: 15 rows, each showing:
  - USER: chira (same as payment-api)
  - PPID: 1770 (payment-api's PID)
  - STAT: ZN (zombie state)
  - COMMAND: [sh] <defunct>

Command: ps -el | awk '$2 == "Z"'
Result: 15 rows, state Z, all PPID 1770 confirmed
```

Also confirmed: `/tmp/novapay-receipts.txt` had exactly 15 lines — the zombies had completed their work before becoming defunct. The bug was invisible to the caller.

GitHub: INC-004 created before the fix, closed after commit `a68b831`.

---

## The correct design — in-process goroutine

The fix eliminates child processes entirely. No `fork`, no `exec`, no `SIGCHLD`, no zombies structurally possible.

### Architecture
```go
var receiptWorker = make(chan string, 50)  // buffered work queue

// main(): start one worker goroutine
go receiptLoop(&wg)

// handleCharge(): non-blocking send after writing HTTP response
select {
case receiptWorker <- paymentID:
    // queued
default:
    // channel full — skip silently, charge path unaffected
}

// receiptLoop(): single worker, exits cleanly when channel closed
func receiptLoop(wg *sync.WaitGroup) {
    defer wg.Done()
    for id := range receiptWorker {
        time.Sleep(100 * time.Millisecond)
        fmt.Fprintln(f, "receipt-"+id)
    }
}
```

### Why each design decision

**Buffered channel (size 50):** decouples the charge handler from the receipt writer. The handler never blocks waiting for the receipt to be written. If receipts fall behind (e.g. slow disk), up to 50 are queued before the `select default` kicks in and silently drops.

**Single worker goroutine:** serialises receipt writes — no concurrent file access, no locking needed. One goroutine, one file, always safe.

**Non-blocking send (`select` + `default`):** the HTTP response path has a deadline. Receipt generation does not. If the worker is busy, skip it — a missing receipt is better than a delayed charge response.

**`for range` on channel:** the idiomatic Go pattern for draining a channel. When the channel is closed and empty, the range exits automatically. The goroutine terminates cleanly — no explicit stop signal needed.

---

## The SIGTERM drain — why it matters for a payments service

When systemd restarts or stops `payment-api`, it sends SIGTERM. Without a SIGTERM handler, Go's default behaviour is to exit immediately — any receipt IDs queued in the channel are lost. For a payments service, lost receipts are a data integrity problem.

The shutdown sequence:
```
1. SIGTERM received
2. signal.Notify delivers to sigCh
3. close(receiptWorker) — signals the worker that no more IDs are coming
4. wg.Wait() — blocks until receiptLoop drains the channel and exits
5. slog.Info("receipt worker drained")
6. os.Exit(0)
```

This guarantees: every `paymentID` that was sent to the channel before shutdown will have its receipt written. The channel is fully drained before exit. The systemd `RestartSec=5s` delay gives this drain time to complete.

---

## Go concurrency concepts used today

### 1. Goroutines vs OS threads vs OS processes
- **OS process:** heavy — separate address space, PID, file descriptor table, page tables. `fork` is expensive. 15 processes = 15 process table entries.
- **OS thread:** lighter — shared address space with parent, but still kernel-managed. Context switches are expensive.
- **Goroutine:** extremely lightweight — managed by the Go runtime, multiplexed onto OS threads (M:N threading). Stack starts at 2KB and grows as needed. `payment-api` can run thousands of goroutines with the same memory footprint as a handful of OS threads. No process table entries. No PID consumption.

### 2. Buffered vs unbuffered channels
- **Unbuffered** (`make(chan string)`): sender blocks until receiver is ready.
- **Buffered** (`make(chan string, 50)`): sender can put up to 50 items in the channel without waiting. Only blocks when the buffer is full.

For receipt generation: we want the charge handler to be as fast as possible. The buffered channel lets it "fire and forget" the receipt ID without waiting for it to be written to disk.

### 3. `select` with `default` — non-blocking channel operations
```go
select {
case ch <- value:  // send if channel has space
default:           // if channel is full, do this instead
}
```
Without `default`, a send to a full channel blocks forever. With `default`, it falls through immediately. For a payment service: always prefer to drop a receipt than to delay a charge response.

### 4. `sync.WaitGroup` for coordinating goroutine shutdown
```go
wg.Add(1)           // before starting the goroutine
defer wg.Done()     // inside the goroutine
wg.Wait()           // in the shutdown path
```
This is the standard Go pattern for "wait until this goroutine finishes." Without it, the process might exit before the goroutine has written the last receipt — data loss.

### 5. `for range` on a channel — the drain pattern
```go
for id := range ch { ... }
```
This is equivalent to:
```go
for {
    id, ok := <-ch
    if !ok { break }  // channel closed and empty
    ...
}
```
When `close(ch)` is called, any remaining items in the buffer are still delivered before the range exits. This is what makes the drain work — `close()` signals "no more items coming" but doesn't discard buffered items.

---

## Acceptance criteria — all met ✓

- [x] Shell-out receipt generation wired and zombie accumulation observed
- [x] 15 charges → 15 `<defunct>` processes confirmed (`ps -el | awk '$2=="Z"'`)
- [x] Root cause explained: no `Wait()` call, no `SIGCHLD` handling, no reaping
- [x] Replaced with in-process goroutine (buffered channel, single worker)
- [x] Zero `<defunct>` processes under load after fix
- [x] Clean SIGTERM drain — `wg.Wait()` before exit
- [x] `/check` PASS, `/test-charge` PASS
- [x] Ledger invariant: 0 rows throughout
- [x] INC-004 opened before fix, closed after commit
- [x] Deployed to EC2 (`a68b831`), EC2 invariant clean

---

## Problems hit (none critical)

The zombie accumulation was exactly as expected — 1:1 with charges, visible immediately in `ps`, with correct receipt output confirming the children had done their work before dying.

One nuance: WSL2 process table entries appear differently from native Linux. Confirm zombie behaviour on EC2 if ever in doubt — EC2 runs a real Linux kernel.

---

## Commands worth keeping

```bash
# Check for zombie processes (square brackets prevent grep matching itself)
ps aux | grep "[d]efunct"

# Show all processes in zombie state
ps -el | awk '$2 == "Z"'

# Check PID limit on the system
cat /proc/sys/kernel/pid_max

# Show parent-child relationships in a tree
pstree -p $(pgrep payment-api)

# Correct exec.Command pattern (if you ever must shell out)
cmd := exec.Command(...)
cmd.Start()
go func() { cmd.Wait() }()  // reap asynchronously — never skip Wait()

# Check thread count for a process (proxy for goroutine stability)
ps -p <pid> -o nlwp=
```

---

## Agentic workflow addition

Same pattern as Day 4:
```
observe failure → GitHub issue → fix → commit → close issue
```
INC-004 was created via GitHub MCP before Part 3, closed after commit `a68b831`. The Issues tab now shows two incidents (INC-003: retry meltdown, INC-004: zombie accumulation) — a growing public operational record.

Next addition to consider: expose `runtime.NumGoroutine()` in the `/healthz` response. This makes goroutine leaks visible without requiring `ps` access — a monitoring signal that works both locally and on EC2 via `/ec2-status`.

---

## LinkedIn article notes
_Raw material for the Day 7 deep-dive._

**Strong angles:**
- "15 charges. 15 zombies. The receipts were written correctly. Everything looked fine." — the insidious part, lead with it.
- The 1:1 relationship is concrete and immediately surprising to most engineers.
- PID exhaustion as the real danger — not memory, not CPU, not disk. PIDs. A finite resource most engineers never think about until it runs out.
- The fix removes the problem class entirely: no child processes = no zombies structurally possible. That is a better guarantee than "we call `Wait()` properly."

The `exec.Command` vs goroutine comparison maps perfectly to a "pick the right tool" lesson — OS process vs goroutine is not a style choice, it's a resource consumption choice.

**Hook ideas:**
- "My payment service handled receipts correctly. Every file was written. Every charge succeeded. There were also 15 zombie processes. Here's why that matters."
- "There's a Linux process state most engineers only see once — right before their system stops accepting connections. State Z. Here's how I built it deliberately, then eliminated it."
- "A zombie process holds no memory, no CPU, no file descriptors. What it holds is a PID. Linux has a finite supply of those."

**Specific numbers worth using:**
- 15 charges → 15 zombies, exactly 1:1
- 0 zombies after fix, same 15 charges
- Thread count: 9 stable across 20 charges — goroutine lifecycle correct
- `cat /proc/sys/kernel/pid_max` → the number that caps your system

---

## Handoff to Day 06
**Status:** Day 05 complete ✓ · deployed `a68b831`

**Day 06 goal:** timeouts + graceful shutdown under `PSP_HANG`.
- Set `PSP_HANG=true`: `fake-psp` accepts connections and never responds
- `payment-api` has no timeout on the PSP call — goroutines pile up silently
- Observe: service looks healthy (systemd running, `/healthz` responds) but every charge goroutine is blocked forever — liveness ≠ doing work
- Build the defence: `context.WithTimeout` on the PSP call, HTTP client timeout, graceful shutdown that drains in-flight requests on SIGTERM
- The lesson: an unbounded wait on a dependency is the silent failure mode — no crash, no error, just accumulating resource exhaustion

**What Day 06 starts with:**
1. Set `PSP_HANG=true` in `fake-psp`, fire charges, observe goroutine pile-up
2. Build `context` deadline + HTTP client timeout on `callPSP`
3. Verify: hung PSP fails fast, service stays responsive
4. Commit: `D6: context deadlines + HTTP client timeouts on PSP calls`
