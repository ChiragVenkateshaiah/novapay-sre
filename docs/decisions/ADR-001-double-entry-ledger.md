# ADR-001 — Double-Entry Ledger
**Status:** Accepted
**Date:** 2026-06-16
**Phase:** Phase 1 · Week 1 · Linux & Systems Foundations

## Context
NovaPay needed to record money movement for every charge. The simplest option
was a single `accounts` table with a running balance — a balance update per
charge, one row per account. It is easy to implement and easy to query.

The question was whether a simpler model would survive the correctness
requirements of a real payments system.

## Decision
Use a double-entry ledger: every payment produces exactly two `ledger_entries`
rows — a debit from one account and a credit to another — with the invariant
that debits must equal credits per payment, enforced by a verification query.

## Alternatives considered
**Single balance table with running total** — rejected. A balance update
records only the new state, not the cause. If a bug double-credits an account,
the account balance reflects the error with no evidence that two credits
were applied. The error is undetectable after the fact without a transaction
log separate from the balance table. Forensic recovery requires reconstructing
intent from application logs, not from the database itself.

## Consequences
### What the system gains
- The invariant `sum(debits) == sum(credits)` per payment is verifiable at
  any time via a query against `ledger_entries` — no reconstruction needed.
- Partial writes (payment row committed, second ledger entry not) are
  detectable: the invariant query returns the broken payment_id.
- Built-in audit trail: every money movement has a timestamped, immutable row.
- Foundation for reconciliation: sum all ledger entries per account to
  reconstruct any account balance at any point in time.

### What the system gives up
- Two rows per payment instead of one balance update — 2× write amplification.
- Queries that need account balance must aggregate ledger rows, not read a
  single column.
- Schema migrations (e.g. adding currencies) touch more tables.

### CLAUDE.md constraint to add
"Never replace double-entry ledger with single balance table — see ADR-001"

## Related decisions
- ADR-002 (pgx/v5) — the driver choice is informed by the need for
  per-payment transactions that write payment + two ledger rows atomically.
- ADR-003 (idempotency constraint) — idempotency is enforced at the DB level
  in part because the ledger cannot tolerate duplicate rows.
