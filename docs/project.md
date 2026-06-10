# NovaPay — A Systems Engineering Lab (SRE · DevOps · Platform)

### A production-grade payments lab on AWS — a real payments core you **build correctly**, operate, and grow one layer at a time. The discipline lens (SRE / DevOps / Platform) is chosen deliberately at a checkpoint, once you've built and operated enough to choose it well.

> **Repo:** `novapay-sre` (public, name retained for continuity). The theme: money is the one thing a system is never allowed to lose track of. You build a payments core that stays *provably correct* — and over a year it becomes a portfolio no other candidate has.
>
> **v2 framing — build-first and neutral.** This project does **not** lock to a single discipline up front, and it does **not** organize the foundation around break-on-purpose incidents (that's SRE-flavored, and it belongs after the checkpoint). Through Week 20 the orientation is neutral: *build NovaPay well* — concurrent, correct, observable, reproducible — on a stack you understand deeply. The three disciplines share this foundation. You choose your lane at the **Decision Checkpoint** (end of Week 20) — see §5–§6.

---

## 1. The idea

Instead of fifty disconnected demos, you build and operate **one** realistic payments service for a year. You build it the way money systems must be built — idempotent, balanced, observable — and you study how payment systems *fail* in order to build defenses against those failures. The chaos/break-on-purpose work (deliberately breaking it to learn how it falls over) is a **lens** that belongs mainly to the SRE lane and enters *after* the checkpoint.

The week-by-week roadmap (`roadmap.md`) isn't replaced by this doc; each phase **adds a layer to this same system**. Legacy incidents 0001–0002 stay as early chapters. By month 12 you don't have a résumé bullet — you have a running payments platform, deep build write-ups, dashboards, and (lane-dependent) an incident library, a delivery showcase, or a developer platform — all in one repo with a year of receipts, and a *chosen specialty* you can defend from experience.

---

## 2. What you're building — and the hard scope ceiling

A deliberately **minimal payments core** — small enough to fully understand, rich enough to be *correct under real conditions*. You build it yourself (not cloned) so every write-up credibly explains the engineering in code you wrote.

**The scope ceiling (read this every time you're tempted to add a feature):**

> The app is *done enough* the moment it can: accept a payment request, write a **balanced double-entry ledger transaction correctly under concurrency**, call the (fake) bank, **dedupe on an idempotency key**, and emit metrics + logs. After that, add a feature only if it **deepens a foundational competency** — concurrency, data correctness, systems, observability, reproducibility — or, post-checkpoint, serves your chosen lane. Adding payment *features* for their own sake (refunds, disputes, multi-currency, webhooks) is scope creep. Deepening *correctness and operational depth* is not.

This is your strongest defense against the thing most likely to kill a year-long solo project: overload. Protect the cadence over the ambition.

**Engineering-depth threads (what "building well" means here):**
- **Go with correct concurrency** — idempotency under concurrent requests, atomic ledger writes, `context` deadlines and timeouts at the dependency boundary, graceful shutdown.
- **The ledger as a data-correctness problem** — the invariant (debits == credits) holding under load; Postgres isolation levels, row locking, connection pooling, restore drills (deep in Week 7).
- **Observability + reproducibility by default** — structured logs, metrics, and traces built in from the start; the whole stack rebuilds with one `terraform apply`.

**Target architecture (you grow into this — not day one):** `payment-api` (Go) · double-entry ledger (Postgres → RDS) · idempotency/cache (Redis) · `fake-psp` (a controllable stub "bank") · ALB → ASG/EKS · CloudWatch + Prometheus/Grafana + OpenTelemetry · 100% Terraform · GitHub Actions → GitOps · *(post-checkpoint, lane-dependent)* a chaos suite (SRE), a progressive-delivery pipeline (DevOps), or a golden-path/portal platform layer (Platform) · an AI incident-response agent via MCP.

> **Reference, don't clone.** Study Blnk (`blnkfinance/blnk`) and a Go+Postgres double-entry walkthrough for the *patterns*, then write your own slimmer version. No real PSP, no PCI scope, no live money.

---

## 3. Repo structure

```
novapay-sre/
├── README.md                # The case-study hub (portfolio front door)
├── app/
│   ├── payment-api/         # The Go service you build and operate
│   └── fake-psp/            # The controllable "bank"
├── infrastructure/          # Terraform + Ansible (one box → whole stack)
├── platform/                # Golden-path templates, scaffolding, portal config (Platform lane)
├── monitoring/              # Prometheus, Grafana dashboards, alert rules, SLOs
├── chaos/                   # FIS experiments (activates post-checkpoint, SRE lane)
├── runbooks/                # Runbooks-as-code
├── postmortems/             # Legacy 0001–0002; reactivates post-checkpoint (SRE)
├── scripts/                 # Helper + test tooling
├── agent/                   # AI incident-response agent + MCP config
└── docs/
    ├── roadmap.md
    └── operations-handbook.md
```

> The repo is intentionally discipline-neutral. `monitoring/` + `chaos/` lean SRE, CI config + `infrastructure/` lean DevOps, `platform/` leans Platform — they coexist, and your checkpoint choice decides which gets the deepest investment.

---

## 4. The year arc (each phase = a layer on the same payments core)

The first four phases are the **common core** — build-first and identical under every discipline. The checkpoint sits after them; the back half reweights by your choice.

| Phase | Weeks | Lane | Layer added to NovaPay | Cert milestone |
|---|---|---|---|---|
| 1. Linux foundations | 1–4 | **common core** | `payment-api` + `fake-psp` on one EC2 box, built correctly | — |
| 2. AWS + observability | 5–10 | **common core** | Real VPC/ALB/RDS/ASG; CloudWatch + Prometheus/Grafana; first SLO; **ledger correct under concurrency (wk 7)** | **AWS SAA (~wk 12)** |
| 3. Containers + K8s | 11–16 | **common core** | Containerize, move to EKS | **CKA (~wk 18–20)** |
| 4. IaC + CI/CD | 17–20 | **common core** | Whole stack in Terraform; GitHub Actions; GitOps | **Terraform Associate** |
| **★ DECISION CHECKPOINT** | **end of 20** | **choose lane** | **Pick SRE · DevOps · Platform — from experience** | — |
| 5. Specialization | 21–32 | **your lane** | Reliability/chaos **or** delivery/release-eng **or** platform/IDP (+ AIOps) | (lane-specific; e.g. PCA) |
| 6. CCA-F | 33–34 | all | AI responder via MCP, productized | **CCA-F** |
| 7. Market entry | 35–52 | your lane | Polish to case studies; apply; interview | **AWS DevOps Pro** |

### The failure modes a payments system must defend against

These are the deep, real-world failure modes a payments core has that a generic app never could. In the **foundation** you *build defenses* against them (that's what "Harden" means in the roadmap). **Post-checkpoint, the SRE lane** turns them into deliberate chaos experiments and incident drills. They are also the richest source of build-and-explain content:

- **Idempotency failure / double charge** — same key, concurrent requests → defend with a DB-level unique-key guard + correct isolation.
- **Ledger won't balance** — a partial write leaves debits ≠ credits → defend with atomic two-row transactions + an invariant check.
- **Stuck inflight transactions** — a two-phase flow half-completes → defend with timeouts + a clear terminal state.
- **Dual-write inconsistency** — DB commits but cache/webhook doesn't → defend with ordering + reconciliation.
- **Reconciliation drift** — ledger and PSP records disagree → defend with an end-of-day reconciliation check.
- **Retry storm / thundering herd** — a slow `fake-psp` amplifies load → defend with backoff+jitter, caps, circuit breaking.
- **Resource exhaustion** — unbounded waits hold goroutines/connections/fds → defend with deadlines + bounded pools.

The rule: **never add a layer you can't operate correctly.**

---

## 5. The three disciplines (what you're choosing between)

**Site Reliability Engineering (SRE).** Reliability as a feature you engineer: SLOs, error budgets, blameless postmortems, chaos experiments, toil reduction, incident lifecycle. *Optimizes for: provably stable at scale.* In NovaPay: the reliability/chaos spine — **this is where break-on-purpose becomes the organizing model.**

**DevOps / Release Engineering.** The path from commit to production, perfected: pipelines, automation, progressive delivery (canary, blue-green), supply-chain security, DORA. *Optimizes for: change is fast, safe, reversible.* In NovaPay: the delivery spine — build the release system; failures stress-test it.

**Platform Engineering.** The platform as a product whose users are developers: golden paths, self-service scaffolding, developer portals so complexity (and money-safety) is abstracted away by default. *Optimizes for: developers productive and safe without touching the plumbing.* In NovaPay: the IDP spine — build the paved roads.

**The shared truth:** all three run on the same foundation you build in Phases 1–4. The cert backbone (**SAA → CKA → Terraform Associate → DevOps Pro**, plus **CCA-F**) serves all three. The choice sets your *primary lens*, not your toolset — and isn't irreversible.

---

## 6. ★ The Decision Checkpoint (end of Week 20)

> **Built into the plan on purpose. The executing model (Sonnet) must stop here and ask directly — it must not auto-proceed into Phase 5.** Full criteria live in `roadmap.md`; the essentials:

**Why now:** by Week 20 you've *built* the payments core correctly across Linux, AWS, Kubernetes, and IaC/CI-CD, and you hold SAA + CKA + Terraform Associate. The picture is no longer blurry.

**How to decide:** look back at the work and ask which energized you —
- reliability work (root cause, SLOs, the idea of chaos) → **SRE**
- delivery work (safe deploys, rollbacks, pipelines) → **DevOps**
- leverage work (reusable scaffolding others inherit, paved roads) → **Platform**

**The prompt Sonnet will issue at Week 20:**
> *"You've built the common core correctly and hold SAA + CKA + Terraform Associate. Which work energized you most — reliability (SRE), delivery (DevOps), or building for other developers (Platform)? Pick a primary lane and I'll plan Weeks 21–34 around it."*

**What changes after you answer:**
- **The spine** of Weeks 21–34 (reliability/chaos · delivery · platform).
- **Break-on-purpose** (re)enters — as the spine for SRE; as stress-testing for DevOps/Platform.
- **The scope ceiling** — stays tight for SRE; **relaxes** for DevOps/Platform, where "this demonstrates capability" becomes a valid reason to build.

Log your reasoning in `checkpoint.md`. You may answer *"blend, lean X"* — most senior engineers blend — and you can revisit later without restarting.

---

## 7. Definition of done (your month-12 portfolio)

*Common-core items are fixed; the capstone depends on your checkpoint choice.*

- A **reproducible** system — `terraform apply` rebuilds the whole lab. *(common)*
- A **demonstrably correct** payments core — the double-entry invariant holds under concurrent load, idempotency is real, both proven by tests. *(common)*
- **Live SLO dashboards** — success rate, p99 latency, ledger-balance invariant (screenshots in `docs/` so they survive teardown). *(common)*
- A body of **weekly deep-dives** — build/learning write-ups through the foundation, then lane-specific. *(common)*
- **A lane capstone — one of:** a chaos suite + incident library + postmortems (SRE) · a progressive-delivery pipeline with DORA metrics (DevOps) · a shipped platform layer — golden path, self-service onboarding, portal, DevEx metrics (Platform).
- An **AI incident-response agent** wired via MCP. *(common)*
- An **operations handbook** + a **README that reads like a case study**. *(common)*
- Four certs in the backbone + CCA-F. *(common)*

---

## 8. Content & consistency plan (weekly deep-dive model)

**Cadence: one deep-dive per week, published Friday.** Through the foundation, these are **build/learning write-ups** — "how I made the ledger correct under concurrency," "how I built a pipeline that won't ship a ledger-breaking build." Failure-analysis is *optional* here, and a build-and-explain post on a young system is usually *stronger* than a manufactured incident. **Post-checkpoint, the SRE lane shifts to incident postmortems as the spine;** DevOps/Platform stay build-and-ship oriented.

**Decouple practice from publishing.** Build *daily*; publish *weekly*.

**The multiplier (keep daily — highest-ROI habit):** comment substantively on 5–10 others' posts every day. Engage Canadian SRE/DevOps/Platform/FinTech voices — your future network and referrals.

**Format & hook:** first 2 lines (~210 chars) decide everything — lead with the engineering problem or the money stakes, not the setup. Sweet spot ~1,200–1,500 chars; once a month, a carousel/architecture breakdown.

**Weekly rhythm:** Mon pick + Opus plans · Tue–Thu build/harden/verify/document · Fri publish + a one-line "what I'm learning next" · Daily comment + commit.

> **Foundation principle (standing, through Week 20):** *build for correctness, depth-first.* You study failure modes to harden against them, not to stage outages. Reproducibility and demonstrable correctness are the measure. The **open-book / break-on-purpose** stance — owning that incidents are deliberately self-injected — returns after the checkpoint, primarily in the SRE lane, where it's the honest framing for chaos work.

---

## 9. Operating rituals

- **Daily:** plan → build → harden → verify → document → commit. Comment on 5–10 posts.
- **Weekly:** Mon pick + plan, Tue–Thu work, Fri publish the deep-dive, then tear down billable resources.
- **Monthly:** update the README; check progress against the phase table; book the cert exam when its phase ends.
- **At Week 20:** stop. Run the Decision Checkpoint. Choose your lane.

---

## The narrative you'll own in 12 months

> "For a year I built and operated a production-like payments platform — a real double-entry ledger that stays balanced under concurrency, a money-movement API written with proper Go concurrency and deep Postgres correctness. I built the whole stack from a bare Linux box to EKS-on-Terraform, earned SAA + CKA + Terraform + DevOps Pro, and then chose my specialty *after* operating all of it — not before. I built each layer to be correct, hardened it against the ways payment systems fail, and (in my lane) automated the response. All in the open, all reproducible with one command."

Most candidates can't say a sentence like that. You'll have the repo to prove it — and the judgment to back it.
