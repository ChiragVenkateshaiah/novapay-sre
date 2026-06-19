# Day 04 — Harden: Resilient Dependency Calls
**Date:** 2026-06-14
**Phase:** Phase 1 · Week 1 · Linux & Systems Foundations
**Status:** complete ✓
**Commit:** `2eef3e9`

---

## Goal
Harden `payment-api` against a flaky PSP dependency. Observe what an unbounded
retry does to CPU and PSP load under partial failure, then build the real defence:
bounded retries with exponential backoff and full jitter.

---

## What was actually built

### 1. `app/fake-psp/main.go` — PSP_ERROR_RATE knob
New env var placed between the latency and hang checks:
```go
if rate := os.Getenv("PSP_ERROR_RATE"); rate != "" {
    if r, err := strconv.ParseFloat(rate, 64); err == nil {
        if rand.Float64() < r {
            w.WriteHeader(http.StatusInternalServerError)
            json.NewEncoder(w).Encode(map[string]string{
                "error": "psp_transient_failure",
            })
            return
        }
    }
}
```
- `PSP_ERROR_RATE=0.5` → ~50% of calls return HTTP 500
- `PSP_ERROR_RATE=0.9` → ~90% of calls return HTTP 500
- Unset or 0 → always approve (default, unchanged behaviour)

### 2. `app/payment-api/main.go` — bounded retry in callPSP
Replaced the naive unbounded loop with:
- **Max 3 attempts** (1 original + 2 retries)
- **Only retry HTTP 5xx** — not 4xx, not context cancellation, not network errors
- **Full jitter backoff:**
  `delay = random(0, min(1000ms, 100ms × 2^attempt))`
- **slog.Warn on each retry** with `attempt`, `delay_ms`, `psp_status`
- **Failed charges return 503 and never touch the DB** — transaction only opens after PSP succeeds

---

## Key concepts

### Why PSP_ERROR_RATE matters
Real banks fail transiently — network blips, brief overloads, rolling restarts.
`PSP_ERROR_RATE` lets you reproduce that failure mode deterministically and test
your defence before the real thing happens. It is the most useful knob in the system.

### The naive retry trap
The naive implementation was a `for {}` loop with no sleep and no cap:
```go
for {
    status, ref, err := callPSP(ctx, amount, currency)
    if err == nil { break }
    // no sleep, no cap — retry instantly
}
```

What you observe at `PSP_ERROR_RATE=0.5`:
- 10 charges → 23 total PSP calls (13 wasted retries)
- All 10 eventually returned `approved`

**The trap:** the service *looks* correct. Every charge succeeded. But the behaviour
is structurally broken. As error rate rises:

| PSP_ERROR_RATE | Expected calls per charge | 100 concurrent charges → PSP calls/sec |
|---|---|---|
| 0.5 | ~2 | ~200 |
| 0.9 | ~10 | ~1000 |
| 0.99 | ~100 | ~10,000 |

At 0.9, your retries hammer the already-struggling PSP with 10× more traffic.
A struggling dependency gets MORE overloaded, not less. This is the **thundering
herd** / **retry storm** — you make the outage worse by trying to recover.

Three separate problems compound each other:
- No cap → runs forever, delays the 503 indefinitely
- No sleep → CPU pins, goroutines busy-spin
- No jitter → all goroutines retry in lockstep, spike the PSP simultaneously

### Exponential backoff
Each attempt waits longer before retrying:
- Attempt 1 (first retry): up to 200ms
- Attempt 2 (second retry): up to 400ms

This gives the PSP breathing room to recover before the next request arrives.

### Full jitter — why random?
Instead of sleeping exactly 200ms (which means all goroutines wake simultaneously),
you sleep a *random* duration between 0 and the backoff ceiling:
```
delay = random(0, min(1000ms, 100ms × 2^attempt))
```

The jitter observed in the Day 4 load test: 26ms, 82ms, 117ms, 290ms — each
goroutine sleeping a different amount. This **spreads PSP load over time** instead
of concentrating it into spikes.

AWS published research showing full jitter (random between 0 and cap) outperforms
"equal jitter" (random between cap/2 and cap) in reducing total work done during
an outage. The intuition: the wider the spread, the less the thundering herd.

### Only retry 5xx — why not all errors?
- **5xx** → transient server-side problem on the PSP. The same request might succeed
  if retried. This is the right case to retry.
- **4xx** → your request was malformed. The PSP understood it and rejected it.
  Retrying the same bad request always gets the same 4xx. Do not retry.
- **Network error** → something is wrong at the transport layer. Could be a brief
  blip (retry-worthy) or a hard failure (not retry-worthy). Treating it the same
  as a 5xx risks hiding misconfiguration. For now: do not retry.
- **Context cancellation** → the client disconnected or the deadline expired. Retrying
  a cancelled context always fails immediately. Never retry.

### The invariant guarantee under failure
The most important correctness property: **a failed PSP call never writes to
the ledger.**

```
handleCharge sequence:
1. Idempotency check
2. Resolve account IDs (custID, pspID)
3. callPSP — with bounded retry
      ↓
   All 3 attempts exhausted → return 503 early
   ← code returns here, never reaches step 4
      ↓
4. db.Begin() — transaction only opens here
5. INSERT payments
6. INSERT ledger_entries (debit + credit)
7. tx.Commit()
```

Step 4 only executes if step 3 succeeds. A failed PSP call exits `handleCharge`
before any DB work begins. This is why `load-test-3` (the one 503) left zero rows —
no payment row, no ledger entries, DB completely untouched.

---

## What was observed

### Naive meltdown (Part 2, not committed)
```
Charges fired:             10
Total PSP /authorize calls: 23
Wasted retry calls:         13  (23 − 10)
All charges succeeded:     yes — that's the trap
Time to complete all 10:   ~5.2 seconds
```
The insidious part: everything looked correct from the outside. The correctness
was an illusion maintained only by statistical luck at 0.5 error rate.

### Load test under bounded retry (Part 4)
```
PSP_ERROR_RATE=0.5, 10 sequential charges:

Charges succeeded:          9 / 10
Charges returned 503:       1 / 10 (load-test-3, all 3 attempts exhausted)
Panics / unexpected errors: none
Idempotency:                holds — repeated key returned cached result
Ledger invariant:           0 rows (no imbalance)
load-test-3:                no payment row, no ledger entries — DB untouched
Every approved payment:     exactly 2 ledger rows (9 × 2 = 18 rows)
CPU:                        baseline — no spin, jitter absorbed the load
```

Retry delay observations: 26ms, 82ms, 117ms, 290ms — full jitter working,
never zero, never uniform.

---

## Agentic workflow addition — GitHub Issue via MCP

Before fixing the naive meltdown, INC-003 was created as a GitHub Issue via the
GitHub MCP. After the commit, it was closed with the resolution comment. Pattern:

```
observe failure → create GitHub issue → fix → commit → close issue
```

This builds a public incident history. By Week 10, the repo has an Issues tab
showing every failure mode observed, how it was diagnosed, and how it was fixed —
concrete evidence of operating the system, not just building it.

---

## Acceptance criteria — all met ✓

- [x] PSP_ERROR_RATE=0.5 knob works in fake-psp
- [x] Naive retry meltdown observed — the amplification effect documented
- [x] Bounded retry (max 3, 5xx only, full jitter) implemented
- [x] Under PSP_ERROR_RATE=0.5: CPU at baseline, graceful degradation
- [x] Ledger invariant holds under load: 0 unbalanced rows
- [x] Failed charges (503) write zero DB rows
- [x] Idempotency holds under retry
- [x] Deployed to EC2, EC2 invariant clean
- [x] GitHub Issue INC-003 created and closed
- [x] Committed `2eef3e9` and pushed

---

## Problems hit (none critical)

**Naive meltdown not visible in WSL2 CPU metrics**
At `PSP_ERROR_RATE=0.5` with only 10 charges, WSL2 CPU sampling masked the
busy-spin behind I/O wait. The amplification is structural, not always immediately
visible in `top` at low concurrency. At higher error rates (0.9+) or higher
concurrency (100+ goroutines), the effect is unmistakable. Lesson: absence of
visible CPU spike at low concurrency does not mean the retry strategy is safe.

---

## Commands worth keeping

```bash
# Run fake-psp with 50% failure rate
PSP_ERROR_RATE=0.5 go run .

# Run fake-psp with 90% failure rate (stress test)
PSP_ERROR_RATE=0.9 go run .

# Full jitter formula (Go)
// delay = random(0, min(maxDelay, baseDelay * 2^attempt))
baseDelay := 100 * time.Millisecond
maxDelay  := 1000 * time.Millisecond
cap       := min(maxDelay, baseDelay*(1<<uint(attempt)))
delay     := time.Duration(rand.Int63n(int64(cap)))
time.Sleep(delay)

# What to check after adding retry logic
# 1. Confirm invariant still holds under load
# 2. Confirm failed charges write 0 DB rows
# 3. Confirm idempotency holds on repeated keys
# 4. Confirm CPU stays at baseline (no busy-spin)
```

---

## LinkedIn article notes
_Raw material for the Day 7 deep-dive._

**The strongest angle from Day 4:**
The naive retry trap — "all 10 charges returned approved" looks correct but is
structurally broken. The correctness was statistical luck. This is the kind of
insight that reads senior: you're not just fixing a bug, you're explaining why
the system *appeared* to work and why that's dangerous.

**Hook ideas:**
- "My payment service handled 50% PSP failures perfectly. Every charge returned
  approved. It was still wrong. Here's why."
- "The retry strategy that works at 50% error rate will destroy your system at
  90%. The difference is one line of math."
- "I deliberately made my bank return errors on half of all calls. Here's what
  I built to handle that without melting the CPU."

**Specific numbers worth using:**
- 10 charges → 23 PSP calls with naive retry (13 wasted)
- `PSP_ERROR_RATE=0.9` → 10× PSP calls per charge → thundering herd
- Jitter delays observed: 26ms, 82ms, 117ms, 290ms (never zero, never uniform)
- Load test: 9/10 succeeded, 1/10 returned 503, invariant 0 rows

**The geometric distribution insight:**
At error rate p, expected calls per charge = 1/(1-p).
At p=0.5: 2 calls. At p=0.9: 10 calls. At p=0.99: 100 calls.
This is the mathematical proof that unbounded retries are dangerous — write it
as a formula, not just intuition.

---

## Handoff to Day 05
**Status:** Day 04 complete ✓ · deployed `2eef3e9`

**Day 05 goal:** correct process and goroutine lifecycle.
- Demonstrate zombie/orphan processes by shelling out a child process per charge
  that is never reaped — watch `<defunct>` accumulate in `ps`
- Build the correct in-process goroutine for receipt generation:
  bounded concurrency, no leaked goroutines, cleaned up on shutdown
- Verify: zero `<defunct>` processes after fix; goroutine count stays stable under load

**What Day 05 starts with:**
1. Add a `shell-out receipt generator` to `handleCharge` (deliberately broken)
2. Drive load, observe `<defunct>` via `ps -el | grep defunct`
3. Explain WHY they aren't reaped (no wait/SIGCHLD handling)
4. Replace with correct in-process goroutine
5. Verify zero defunct, stable goroutine count
6. Commit: `D5: correct goroutine lifecycle — no leaks, no zombies`
