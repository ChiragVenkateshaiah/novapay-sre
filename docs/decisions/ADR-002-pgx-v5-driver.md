# ADR-002 — pgx/v5 as PostgreSQL Driver
**Status:** Accepted
**Date:** 2026-06-16
**Phase:** Phase 1 · Week 1 · Linux & Systems Foundations

## Context
NovaPay needed a Go PostgreSQL driver. The standard choice in the Go ecosystem
is `database/sql` (the stdlib interface) paired with a driver like `lib/pq` or
`pgx/v5` in compatibility mode. The alternative is pgx/v5 used natively,
bypassing the `database/sql` shim entirely.

The project is Postgres-first by design — no other databases will ever be
supported, so portability is not a constraint.

## Decision
Use pgx/v5 natively with `pgxpool.Pool` for connection pooling. Do not use
the `database/sql` compatibility layer.

## Alternatives considered
**database/sql + lib/pq** — rejected. `lib/pq` is in maintenance mode (pgx is
the recommended successor). The `database/sql` interface is a lowest-common-
denominator abstraction: it loses pgx-specific types, extended query protocol
defaults, and native error types. Specifically, `database/sql` returns
`sql.ErrNoRows`; pgx returns `pgx.ErrNoRows` — distinguishing these in the
idempotency check path requires the pgx-native type.

**database/sql + pgx/v5 in compat mode** — rejected. Takes the maintenance
overhead of wiring pgx through database/sql while still losing access to
pgx-native features. No upside over native pgx for a Postgres-only codebase.

## Consequences
### What the system gains
- `pgxpool.Pool` manages connection pooling, prepared statement caching, and
  connection health checks without additional configuration.
- `pgx.ErrNoRows` is returned directly from `QueryRow().Scan()` — the
  idempotency check (`errors.Is(err, pgx.ErrNoRows)`) is unambiguous.
- Extended query protocol is used by default — parameterised queries are sent
  to Postgres as binary, not as string-interpolated SQL.
- Access to pgx-native types (e.g. pgx batch queries, `pgxpool.Conn`) if
  needed in future weeks.

### What the system gives up
- No portability to MySQL, SQLite, or other databases. Intentional — NovaPay
  is Postgres-only and that will not change.
- Fewer online examples (most Go database tutorials use database/sql).

### CLAUDE.md constraint to add
"Always pgx/v5 with pgxpool, never database/sql + lib/pq — see ADR-002"

## Related decisions
- ADR-001 (double-entry ledger) — the atomic transaction that writes payment +
  two ledger entries in a single `pgxpool.Tx` depends on pgx's transaction API.
- ADR-003 (idempotency constraint) — `pgx.ErrNoRows` detection in the
  idempotency check path is a direct consequence of this driver choice.
