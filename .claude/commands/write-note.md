---
description: Generate a deep technical learning note for the completed day and save to notes/
allowed-tools: Read, Write, Bash
---

Day number provided: $ARGUMENTS
Target file: notes/month-01/week-01/Day_$ARGUMENTS.md

Before writing, gather context:
1. Read checkpoint.md — for current phase, week, what was built, commit hash
2. Run: ls notes/month-01/week-01/Day_*.md 2>/dev/null | sort | tail -1
   Read that file — the previous day's note gives handoff context
3. Use the current conversation session for today's specific details,
   commands run, output observed, decisions made, and errors hit

Then create notes/month-01/week-01/Day_$ARGUMENTS.md with this exact structure.
Write every section in full — do not summarise or leave placeholders.
This document is a permanent technical reference, not a summary.

─────────────────────────────────────
# Day $ARGUMENTS — [title of what was built/hardened today]
**Date:** [today's date]
**Phase:** Phase 1 · Week 1 · Linux & Systems Foundations
**Status:** complete ✓
**Commit:** [commit hash from today's work]

---

## Goal
One paragraph. What was the day's objective and why it matters
for the foundation. What failure mode or competency was being addressed.

---

## What was actually built
List every file changed with the exact code changes made.
Include function names, package-level variables, imports added/removed.
Show the actual Go/YAML/INI code that was written — not pseudocode.
Explain the role of each change in one sentence.

---

## Core concept — [the main Linux/Go/systems concept of the day]
This is the deepest section. Explain the concept as if teaching it
from scratch to a junior engineer who will use it in production.

Required sub-sections (use ### headings):

### The concept explained from first principles
What is it, how does Linux/Go handle it at the OS/runtime level,
what are the data structures involved.

### Why it matters for a payments service specifically
Not generic — tie it to the invariant, the charge path, or money correctness.

### The broken pattern — what was demonstrated
Exact description of the deliberately broken version. What it looked like
in code. What was observable (ps output, top output, log lines, error messages).
Include the actual observed output with numbers.

### The correct pattern — what replaced it
The correct implementation with explanation of every design decision.
For each decision: what was chosen, what alternatives existed, why this choice.

### The failure cascade — what happens at scale
If the broken pattern ran in production under load, what would eventually fail.
Be specific: which resource exhausts, what the symptom looks like, at what scale.

---

## What was observed
The exact output from the observation step. Numbers, ps rows, log lines,
curl responses. Paste the real data. This is the forensic record.

---

## Acceptance criteria — all met ✓
Checkbox list. Every item from the day plan, marked complete.

---

## Problems hit
Every error encountered during the day, even minor ones.
For each: what the error said, root cause, fix applied, lesson.
If nothing went wrong, write "None — execution matched the plan."

---

## Commands worth keeping
Every command that will be reused in future days or in production.
Include inline comments explaining what each does and when to use it.
Group by category (Linux process inspection, Go debugging, Ansible, etc.)

---

## Agentic workflow addition
What was added to the Claude Code workflow today that it did not have
before. New custom command, MCP usage, hook behaviour, checkpoint update.
Include the GitHub issue pattern if used (INC-NNN opened → closed).
State: what does the workflow gain today that it lacked yesterday?

---

## LinkedIn article notes
Raw material only — not polished prose.
- The strongest technical angle (one sentence hook)
- The specific numbers worth using (observed metrics, counts, timings)
- What NOT to make the article about
- The moment that would resonate with a senior engineer

---

## Handoff to Day [N+1]
**Status:** Day $ARGUMENTS complete ✓ · deployed [commit hash]

What the next day will do — goal, the broken pattern to demonstrate,
the defence to build, the verification sequence.

What Day [N+1] starts with — numbered list of first steps.
─────────────────────────────────────

After writing the file, print:
"✓ Day_$ARGUMENTS.md written to notes/month-01/week-01/"
Then show the first 10 lines of the file to confirm it was created correctly.
