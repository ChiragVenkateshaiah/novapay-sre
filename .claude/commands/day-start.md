---
description: Read checkpoint.md and print the current day context and goal
allowed-tools: Read
---

Read the file `checkpoint.md` in the repo root.

Then print a concise summary in this format:

---
**Current phase:** [from checkpoint]
**Current week:** [from checkpoint]
**Day status:** [which days are done, which is next]

**What was built so far this week:**
[bullet list from "Built" section]

**Today's goal:**
[the next incomplete day's goal from week-01-plan.md]

**Acceptance criteria for today:**
[bullet list of what must be true before today is done]

**Reminders:**
- Run /check after any change to the charge path
- Run /test-charge before committing
- The ledger invariant is non-negotiable
---

If checkpoint.md does not exist, say so and stop.
