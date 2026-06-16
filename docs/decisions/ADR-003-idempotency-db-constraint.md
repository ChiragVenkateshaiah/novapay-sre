# ADR-003 — Idempotency Enforced at Database Level
**Status:** Accepted
**Date:** 2026-06-16
**Phase:** Phase 1 · Week 1 · Linux & Systems Foundations

## Context
Payment APIs receive duplicate requests — network retries from the client,
retry loops in upstream services, or accidental double-submits. NovaPay must
guarantee that a given `idempotency_key` moves money at most once, regardless
of how many times the same request arrives.

The question was where to enforce this guarantee: in application code, in the
database, or both.

## Decision
Enforce idempotency at the database level via a `UNIQUE(idempotency_key)`
constraint on the `payments` table, plus an application-level pre-check that
returns the original result before attempting the PSP call.

## Alternatives considered
**Application-only check (SELECT then INSERT)** — rejected. Under concurrent
load, two goroutines handling the same idempotency_key can both execute the
SELECT and see no existing row, then both proceed to the PSP call and INSERT.
The result is a double charge. The application-level check is a necessary UX
optimisation (return the original result without a DB error) but cannot be the
only enforcement layer.

**DB constraint only, no pre-check** — rejected. Without the pre-check, a
duplicate request would hit the PSP, get authorised, then fail on INSERT due
to the unique constraint — resulting in a charge that succeeded at the PSP but
was never recorded. The authorised amount would hang in the PSP's clearing
queue. The pre-check prevents the PSP call from ever being made for duplicates.

## Consequences
### What the system gains
- The DB rejects the second INSERT atomically even under concurrent load —
  the race condition that defeats application-only checks is structurally
  impossible.
- Idempotency survives application restarts: the constraint lives in the
  database, not in application memory.
- The pre-check returns the original `payment_id` and `status` for duplicates,
  which is the correct API contract for idempotent endpoints.
- Defence in depth: two independent layers, each sufficient alone.

### What the system gives up
- Slightly more complex error handling: the INSERT can fail with a unique
  constraint violation, which must be caught and treated as "already exists"
  rather than a real error. (Currently handled by the pre-check making the
  constraint failure unreachable in normal flow.)
- The pre-check adds one SELECT per charge — negligible at this scale.

### CLAUDE.md constraint to add
"Idempotency enforced at DB level (UNIQUE constraint), not app-only — see ADR-003"

## Related decisions
- ADR-001 (double-entry ledger) — the idempotency guarantee is especially
  critical because a duplicate charge would produce two sets of balanced
  ledger entries, both passing the invariant check independently.
- ADR-002 (pgx/v5) — `pgx.ErrNoRows` detection in the pre-check path
  depends on the driver returning the pgx-native error type.
