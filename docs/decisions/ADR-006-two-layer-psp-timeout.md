# ADR-006 — Two Independent Timeout Layers on PSP Calls
**Status:** Accepted
**Date:** 2026-06-16
**Phase:** Phase 1 · Week 1 · Linux & Systems Foundations

## Context
`callPSP` used `http.DefaultClient.Do(req)` with no timeout. When `fake-psp`
was configured with `PSP_HANG=true`, every charge goroutine blocked indefinitely
waiting for a response that never came. The `/healthz` endpoint continued to
respond (liveness ≠ healthy). Goroutines accumulated: 7 baseline → 19 after
3 hung charges (4 goroutines per hung charge: handler + HTTP transport internals).

The goroutine count was not visible in any monitoring signal until `runtime.NumGoroutine()`
was added to `/healthz`. This created INC-005.

Two timeout strategies were evaluated: a single timeout layer vs two independent
layers.

## Decision
Two independent timeout layers:
1. **Context deadline (primary):** `context.WithTimeout(ctx, 5*time.Second)` derived
   at the top of `callPSP`, passed to `http.NewRequestWithContext`. This is the
   Go-runtime-level cancellation signal.
2. **HTTP client timeout (backstop):** `var pspClient = &http.Client{Timeout: 6 * time.Second}`
   declared at package level. This is the transport-level deadline, enforced by
   the `net/http` transport regardless of context state.

The 1-second gap (5s context, 6s client) ensures the context deadline fires first,
enabling `errors.Is(err, context.DeadlineExceeded)` log discrimination.

## Alternatives considered
**Single context deadline only** — rejected. If the context deadline fires but
the HTTP transport has a bug or is not correctly wired to the context, the
goroutine can still hang. Context cancellation propagates through
`http.NewRequestWithContext`, but the transport-level timeout is an independent
enforcement path. Defence in depth at a financial dependency boundary is correct.

**Single HTTP client timeout only** — rejected. The `http.Client.Timeout`
enforces a wall-clock deadline but does not produce `context.DeadlineExceeded`
in the error chain. Without the context deadline, `errors.Is(err, context.DeadlineExceeded)`
returns false and the log discrimination (WARN vs ERROR) is lost. Timeouts at
a PSP boundary are expected and should log at WARN, not ERROR, to avoid alert
fatigue.

**No timeout, rely on PSP SLA** — rejected. This was the original broken
state. A dependency's uptime guarantee is not a substitute for a local
timeout. The PSP can hang (connection accepted, response never sent) in ways
that no SLA prevents. The service must protect itself.

**Package-level client vs per-request client** — package-level was chosen.
A per-request `&http.Client{}` allocation bypasses connection pooling (Keep-Alive
connections are per-client). One allocation at startup, reused on every request,
preserves the connection pool.

## Consequences
### What the system gains
- Hung PSP connections fail fast: 503 returned to caller in ~5.01s, not after
  minutes or hours.
- Goroutine count returns to baseline after timeouts resolve: observed 7→19
  during 3 hung charges, back to 7 after all three returned 503.
- `errors.Is(err, context.DeadlineExceeded)` correctly traverses the error
  chain through `fmt.Errorf("http: %w", urlErr)` — wrapping does not break
  the check.
- Log discrimination: PSP timeout logs as WARN (expected, temporary, self-
  resolving), other PSP errors log as ERROR (unexpected, requires investigation).
- `runtime.NumGoroutine()` in `/healthz` makes goroutine pile-up visible
  without SSH access.

### What the system gives up
- Legitimate slow PSP calls (>5s) will time out and return 503. A PSP taking
  >5s on a single authorisation is a PSP problem, not a timeout problem.
- The 5s deadline covers the entire callPSP call including all retry attempts.
  Under `PSP_ERROR_RATE=0.5`, a run of three 5xx responses with full-jitter
  backoff can consume the budget before completing. Acceptable — a PSP returning
  5xx for 5+ seconds is degraded and the caller should know.

### CLAUDE.md constraint to add
"PSP calls must have two timeout layers: context deadline + HTTP client — see ADR-006"

## Related decisions
- ADR-004 (full-jitter retry) — the retry backoff select was updated from
  `ctx.Done()` to `pspCtx.Done()` so the 5s deadline fires even during a
  backoff sleep, not only when the HTTP request is in flight.
- ADR-005 (in-process goroutines) — both decisions bound goroutine count.
  ADR-005 prevents goroutines from accumulating via zombie children;
  ADR-006 prevents goroutines from accumulating via hung HTTP connections.
