---
description: Generate daily learning questions for Go, Linux, Ansible, Terraform, and cloud based on the day's work
allowed-tools: Read, Bash
---

Step 1 — Read context:
- Read checkpoint.md for current state and what was built
- Run: ls notes/month-01/week-01/Day_*.md 2>/dev/null | sort | tail -1
- Read that file for today's specific concepts and code

Step 2 — Generate questions in this exact format:

---
# Daily Learning Questions — Day $ARGUMENTS
*Paste these into Claude.ai chat to dig deeper on each topic.*

## Go Fundamentals
*(Anchor every question to actual code from today's NovaPay work)*

1. [Basic] ...
2. [Basic] ...
3. [Applied] Based on today's work: [question about actual code written]
4. [Applied] ...
5. [Deep] ...

## Linux & Systems
*(Based on today's Linux concepts)*

1. [Basic] ...
2. [Basic] ...
3. [Applied] ...
4. [Applied] Based on what you observed in ps/top today: ...
5. [Deep] ...

## Ansible
*(If Ansible was used today, otherwise skip)*

1. [Basic] ...
2. [Applied] ...
3. [Deep] ...

## Terraform
*(Include from Week 2 onward once Terraform is in the workflow)*

1. [Basic] ...
2. [Applied] ...
3. [Deep] ...

## Cloud & AWS Concepts
*(Concepts that connect to current or upcoming phases)*

1. [Basic] ...
2. [Applied] ...
3. [Deep] ...

---
*Difficulty guide: Basic = recall and understand, Applied = use in context,
Deep = explain the why and the trade-offs*
---

Step 3 — Calibrate Go questions to current learning level:
- The user is currently learning: variables, slices, arrays
- Anchor questions to NovaPay code that uses these concepts
  (e.g., the chargeRequest struct fields, the receiptWorker channel,
  the ledger_entries slice in queries)
- Progress from "what does this do" → "why was it designed this way"
  → "what would break if you changed it"

Step 4 — Include one "connect to NovaPay" question per category:
A question that directly links the concept to something in the
novapay-sre codebase. This makes abstract concepts concrete.

Output the full question set as clean markdown ready to copy into
Claude.ai chat.
