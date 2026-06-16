# ADR-005 — Side Effects in In-Process Goroutines, Not Shell-Out
**Status:** Accepted
**Date:** 2026-06-16
**Phase:** Phase 1 · Week 1 · Linux & Systems Foundations

## Context
Receipt generation needed to happen after a successful charge without blocking
the HTTP response path. Two implementation options existed: shell out to a child
process (`exec.Command`) or handle it in a goroutine within the `payment-api`
process.

The shell-out pattern was implemented first (deliberately broken) and the zombie
accumulation was observed before the fix was built.

## Decision
Side effects (receipt generation, and any future notifications or async tasks)
must be implemented as in-process goroutines using a buffered channel and a
single worker, never via `exec.Command` shell-out.

## Alternatives considered
**exec.Command with .Start() and no .Wait()** — rejected and observed to be
broken. Every `cmd.Start()` call forks a child process. When the child exits,
it enters state Z (zombie) because the parent (`payment-api`) never calls
`cmd.Wait()`. The zombie holds no memory or CPU, but it holds a process table
entry and a PID. Under sustained load (1 charge/second), PID exhaustion occurs
at approximately `pid_max / call_rate` seconds — on a default Linux system
with `pid_max=32768`, that is ~9 hours of continuous load before `fork()` fails
system-wide. At that point: systemd cannot restart services, SSH cannot accept
connections, the system is unrecoverable without reboot.

Observed: 15 charges → 15 `<defunct>` processes, PPID matching `payment-api`,
STAT=Z. The receipts were written correctly — the bug was invisible to callers.

**exec.Command with explicit .Wait() in a goroutine** — rejected as unnecessary
complexity. If the goal is "run work without blocking the handler", a goroutine
accomplishes this without creating a new process, scheduling a new OS thread, or
allocating a new address space. The only reason to shell out is if the work
cannot be expressed in Go (e.g. running an existing binary). Receipt generation
is pure Go file I/O.

## Consequences
### What the system gains
- Zero child processes — zombie accumulation is structurally impossible, not
  just "handled correctly."
- Goroutine overhead is ~2KB stack vs ~1MB minimum for a new process.
- The buffered channel (size 50) absorbs bursts without blocking the handler.
- `for range receiptWorker` drains the channel cleanly on `close()`.
- SIGTERM handler closes the channel and waits (`sync.WaitGroup`) for the
  worker to drain before exit — no receipt IDs are lost on restart.

### What the system gives up
- A panic in `receiptLoop` will crash `payment-api` (no isolation). Acceptable
  at this stage — receipt generation is simple file I/O with negligible panic
  risk. Post-checkpoint, a separate receipt service may be warranted.
- If the channel fills (>50 pending receipts), new receipts are silently
  dropped (the `select { default: }` path). Intentional: charge path latency
  takes priority over receipt completeness.

### CLAUDE.md constraint to add
"Side effects (receipts, notifications) always in-process goroutines,
never shell-out via exec.Command — see ADR-005"

## Related decisions
- ADR-006 (two-layer PSP timeout) — both decisions deal with bounded resource
  consumption (goroutine count, not PID count). Together they ensure `payment-api`
  holds a stable, bounded number of goroutines under any PSP behaviour.
