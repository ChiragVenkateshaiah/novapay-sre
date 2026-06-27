---
description: Regenerate README.md as a senior-level portfolio document from current repo state
model: opus
disable-model-invocation: true
allowed-tools: Read, Write, Bash, Glob
---

You are regenerating README.md from scratch based on the CURRENT state
of the entire repo. This is NOT an append operation — the existing
README is a snapshot from a prior day and must be treated as reference
material only, not as content to preserve verbatim. Read everything
fresh and write a complete, accurate, up-to-date replacement.

STEP 1 — Gather context, in this order:
1. Read CLAUDE.md in full (architecture, constraints, conventions)
2. Read checkpoint.md in full (current phase, week, day status, what's built)
3. Read every file in docs/decisions/ (all ADRs — note count and titles)
4. Read every file in docs/plans/ (week plans)
5. List the structure of app/ (payment-api, fake-psp) — read main.go
   files to confirm what's actually implemented, don't infer from
   checkpoint.md alone
6. List infrastructure/ (ansible, systemd, logrotate, journald) to
   confirm what's actually deployed as IaC
7. Using the GitHub MCP, list ALL issues (open and closed) on the repo
   — these are the incidents (INC-003 onward). Note issue numbers,
   titles, and status for each.
8. Check notes/ directory structure (now public) — note the week/day
   range covered, but do not need to read every note file in full;
   checkpoint.md and ADRs are the primary source of truth for what
   was built and why.

STEP 2 — Identify what's changed since the README was last generated:
Compare what you just read against the CURRENT README.md content.
Note explicitly (to yourself, not in the output) what's new: which
days completed, which incidents opened/closed, which ADRs added,
which workflow commands added.

STEP 3 — Write the new README.md with this structure:

# NovaPay
One-line tagline capturing what this is and why it's different from
a typical portfolio CRUD project (the break-on-purpose, build-first,
discipline-neutral angle).

## What this is
2-3 paragraphs: the payments platform as a learning environment, built
from scratch (not cloned) for postmortem credibility, the discipline-
neutral foundation with the Week-20 decision checkpoint, the pivot
story (briefly — this was originally scoped as an SRE war room and
deliberately replanned).

## Architecture
ASCII diagram: WSL2 (build) → Ansible → EC2 (runtime), payment-api +
fake-psp + PostgreSQL, systemd-managed, current port/service layout.
Update this from the actual current state of infrastructure/, don't
copy a stale diagram.

## What's built
Table: Component | What it does | Key property — covering payment-api,
fake-psp, the PostgreSQL schema, systemd units, the Ansible deploy
pipeline, the audit logging system, log rotation, memory limits —
reflect ONLY what's actually implemented as of the latest completed
day, not future plan items.

## Incidents — engineered, observed, resolved
Table: Incident | Failure mode | Defence built | GitHub issue link |
Status (open/closed). Pull this directly from the GitHub MCP issue
list in Step 1.7 — every incident must have a real, working issue
link. This table is the single most important proof-of-work section
in the README; do not approximate it from memory.

## Architecture Decision Records
One sentence + link to docs/decisions/. State the current ADR count
accurately (count the actual files).

## The agentic workflow
Paragraph covering: Claude Code CLI, CLAUDE.md as project intelligence,
the current count and list of custom commands (read .claude/commands/
to get this right, don't guess), the PreToolUse deploy-blocking hook,
the GitHub-issue-driven incident lifecycle, the human-approval deploy
gate sequence. This section is the technical differentiator — keep it
accurate and specific, not generic AI-tooling language.

## Tech stack
Concise list, current as of today — don't carry forward anything
deprecated or replaced.

## Running locally / Deploying
Keep these sections accurate to the CURRENT main.go and CURRENT
deploy.yml — verify commands against the real files, don't reuse
stale examples from the old README if anything has changed.

## What's next
Brief, pulled from checkpoint.md's stated next steps — don't invent
plans not actually recorded there.

## Status
One line: current phase, current week, days complete, last updated
date (today's actual date).

---
Tags/footer: GitHub repo link, license if any.

STEP 4 — Before writing the file, show me a summary of what changed
section-by-section compared to the previous README (new incidents
added, new ADRs referenced, new commands listed, any sections that
needed correction because they no longer matched reality) — so I can
review the diff in substance before it's written, not just trust the
regeneration blindly.

STEP 5 — Write the new README.md, overwriting the old one entirely.

STEP 6 — Do NOT commit. Stop after writing the file and show me the
final result. I will review and commit manually, the same as every
other change in this project.
