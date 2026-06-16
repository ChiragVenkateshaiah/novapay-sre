# ADR-004 — Full-Jitter Exponential Backoff for PSP Retries
**Status:** Accepted
**Date:** 2026-06-16
**Phase:** Phase 1 · Week 1 · Linux & Systems Foundations

## Context
`callPSP` retries on HTTP 5xx from fake-psp. Three retry strategies existed:
no jitter (fixed delay), equal jitter (random between cap/2 and cap), and
full jitter (random between 0 and cap). The choice affects whether goroutines
retry in lockstep or spread out.

## Decision
Full jitter: `delay = random(0, min(maxDelay, baseDelay × 2^attempt))`.
Implemented as `rand.Int63n(capMS + 1)` where `capMS = baseDelayMS << attempt`,
capped at `maxDelayMS`.

## Alternatives considered
**No jitter (fixed exponential delay)** — rejected. Every goroutine that
received a 5xx at the same time will retry at exactly the same moment. Under
a PSP outage where all goroutines get 5xx simultaneously, the retry wave hits
as a single burst — the thundering herd. The PSP (or the network) receives the
same load spike at each retry interval. This worsens the outage.

**Equal jitter (random between cap/2 and cap)** — rejected. Better than no
jitter — retries are spread across the top half of the backoff window. But half
the window is still unused. Under load, retry density in the lower half is zero
and the upper half sees twice the rate it needs to. Full jitter is strictly
better: it uses the entire window and produces a uniform distribution.

**No retry at all** — rejected. Transient PSP errors (network blips, PSP
restarts) are expected. A single attempt that fails returns 503 to the caller,
forcing the caller's retry policy to handle what could have been resolved
in-service. Three attempts with full jitter absorbs transient failures
invisibly to the caller.

## Consequences
### What the system gains
- Proven by AWS research ("Exponential Backoff and Jitter", 2015) to minimise
  total work done during a dependency outage compared to all other strategies.
- Goroutines that received 5xx simultaneously will retry at uniformly
  distributed random offsets — no thundering herd, no correlated retry spikes.
- The total retry window is bounded: 3 attempts, max cap 1000ms, so the
  worst-case callPSP duration (ignoring PSP_HANG) is ~2200ms before exhaustion.

### What the system gives up
- Some retries happen near delay=0, which is suboptimal if the PSP needs
  recovery time. Acceptable: a PSP that can't respond in 0ms is unlikely to
  respond in 100ms either; the subsequent retry has the full cap.
- The random seed is not fixed — test assertions cannot predict exact delay
  values. Unit tests for retry logic must assert behaviour, not timing.

### CLAUDE.md constraint to add
"Retry backoff must use full jitter, never equal jitter or fixed delay — see ADR-004"

## Related decisions
- ADR-006 (two-layer PSP timeout) — the 5s context deadline on callPSP means
  the total retry budget (including jitter delays) is bounded by the deadline,
  not just by maxAttempts.
