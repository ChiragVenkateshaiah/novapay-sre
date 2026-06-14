---
description: Read checkpoint.md and latest day notes, then print current day context
allowed-tools: Read, Bash
---

Step 1 — Read checkpoint.md from the repo root.

Step 2 — Find and read the latest completed day notes file:
Run this command to find it:
ls notes/month-01/week-01/day-*.md 2>/dev/null | sort | tail -1

Read whichever file that returns. If no files exist, skip this step.

Step 3 — Print a concise summary combining both sources in this format:

---
**Current phase:** [from checkpoint]
**Current week:** [from checkpoint]
**Day status:** [from checkpoint — which days done, which is next]

**What was built through the latest completed day:**
[bullet list — pull key items from both checkpoint Built section
and the latest day notes What was actually built section]

**Last day's key lesson:**
[one paragraph — the most important technical insight from the
latest day notes What I learned section]

**Today's goal:**
[the next incomplete day's goal from checkpoint]

**Acceptance criteria for today:**
[bullet list from checkpoint or week plan]

**Reminders:**
- Run /check after any change to the charge path
- Run /test-charge before committing
- Run /load-test to verify CPU and invariant under failure
- The ledger invariant is non-negotiable
- Commit before deploy — always
---

If checkpoint.md does not exist, say so and stop.
