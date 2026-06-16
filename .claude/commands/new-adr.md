---
description: Create a new Architecture Decision Record in docs/decisions/
allowed-tools: Bash, Write
---

$ARGUMENTS should be a short kebab-case title, e.g. "redis-for-idempotency"

Step 1: Find the next ADR number:
  ls docs/decisions/ADR-*.md 2>/dev/null | sort | tail -1

Step 2: Increment by 1 and zero-pad to 3 digits (e.g. ADR-008)

Step 3: Create docs/decisions/ADR-NNN-$ARGUMENTS.md with this template:

# ADR-NNN — [Title]
**Status:** Proposed
**Date:** [today]
**Phase:** [current phase from checkpoint.md]

## Context
What situation or requirement forced this decision?
What constraints existed? What was the pressure?

## Decision
What was decided? State it clearly in one sentence.

## Alternatives considered
What other options were evaluated and why were they rejected?
Be specific — "option X was rejected because Y" not just "we tried X."

## Consequences
### What the system gains
Positive outcomes, properties guaranteed, future options enabled.

### What the system gives up
Negative trade-offs, constraints imposed, future options foreclosed.

### CLAUDE.md constraint to add
One-line constraint for CLAUDE.md so Claude Code respects this decision:
"Never [do X] — see ADR-NNN"

## Related decisions
Links to other ADRs that this decision depends on or affects.

Step 4: Print the file path and first 5 lines to confirm creation.
