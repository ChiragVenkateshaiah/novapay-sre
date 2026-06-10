# NovaPay — 12-Month Roadmap (v2)

## Linux-first · build-first · discipline-neutral until the Decision Checkpoint

> **What changed from v1 → v2.** v1 locked to a single lane (SRE) from day one *and* organized everything around break-on-purpose incidents — which is quietly SRE-biased, because incident-hunting **is** the SRE job. v2 fixes both:
>
> 1. **The foundation (Weeks 1–20) is neutral and build-first.** The goal is to *build NovaPay correctly* — a concurrent, observable, reproducible payments system on a stack you understand deeply — not to rack up an incident count. SRE, DevOps, and Platform Engineering all run on this same foundation.
> 2. **You choose your lane at the Decision Checkpoint** (end of Week 20, after SAA + CKA + Terraform Associate), informed by having operated the whole stack — not by a guess on day one.
>
> **Where did "break-on-purpose" go?** It's a *lens*, not the spine. In the foundation you study failure modes only to **harden against them** (build defensively). Deliberately breaking the system to learn how it fails — chaos engineering, incident drills, postmortems-as-content — re-enters **after** the checkpoint, and mainly in the **SRE lane**, where it earns its place.
>
> **Repo name stays `novapay-sre`** for continuity — a label, not a commitment.

---

## The thesis: one foundation, three orientations

The same payments system, the same Kubernetes cluster, the same Terraform — three different sets of questions you eventually ask of it:

| Discipline | The core question it optimizes for | What "good" looks like |
|---|---|---|
| **SRE** | *Is it reliable, and how do we keep it that way at scale?* | SLOs met, error budget respected, toil reduced, incidents resolved fast |
| **DevOps** | *How fast and how safely does a commit reach production?* | High deploy frequency, low change-failure rate, reversible delivery |
| **Platform Engineering** | *Is this a product developers want to build on?* | Self-service golden paths, complexity abstracted, money-safety by default |

**The practical consequence:** Weeks 1–20 are *identical* regardless of which you eventually pick — and they're about **building well**, not breaking. SRE and DevOps are closer to each other than either is to Platform (which lives at a different abstraction layer entirely), but all three rest on the same built foundation. Deferring the choice costs you nothing in skill — only in narrative, which is cheap to redirect.

> **Cadence:** build **daily**; publish **one deep-dive weekly** (Fri). Comment on 5–10 posts daily. Always set an AWS billing alarm and tear down resources after each session.
> **Pace is a guide, not a whip.** If a week needs two, take two.

---

## Foundation principle (Weeks 1–20)

> **Build for correctness, depth-first.** Through Week 20 the north star is a payments system that is *demonstrably correct* — the double-entry invariant holds under concurrency, idempotency is real, the stack rebuilds with one command, and you understand every layer beneath your service. You study failure modes to **harden** against them (every timeout, guard, and check is a defense), not to stage outages. Engineering depth — Go concurrency done right, a ledger treated as a correctness problem, observability built in from the start — is the measure, not incident volume. The break-on-purpose / chaos identity returns after the checkpoint, primarily in the SRE lane.

---

# PART A — THE COMMON CORE (Weeks 1–20)

*Build the payments core and the production stack around it, correctly, across every layer. Three depth threads run the whole way: **(a)** Go written with correct concurrency, **(b)** the double-entry ledger as a data-correctness problem (deep Postgres), and **(c)** observability + reproducibility built in by default. By the end you'll hold three certs and — more importantly — know which kind of work energizes you.*

**Each week reads:** *Learn* (the topic) · *Build* (the slice of NovaPay you add, with depth) · *Harden* (the robustness property you ensure + the failure mode it defends against) · *Publish angle* (the weekly deep-dive).

## Phase 1 — Linux & Systems Foundations (Weeks 1–4)

> **Why it's common-core:** Linux is the substrate under every container, EC2 instance, and CI runner. No discipline skips it. This is also where the Go-concurrency and ledger-correctness threads begin. (Legacy incidents 0001–0002 live here.)

- **Week 1 — Shell, processes & the first running service.** *Learn:* bash, processes, signals, `ps`/`top`/`btop`, the process lifecycle, `/proc`. *Build:* minimal `payment-api` + `fake-psp` in Go, under systemd, with structured JSON logging from day one. *Harden:* correct process & goroutine lifecycle — graceful shutdown on SIGTERM, bounded retries with backoff+jitter on the PSP call, `context` deadlines on every outbound call. (Reproduce a busy-spin or a hung call once in `top`/`ps` to *see* what you're defending against — the deliverable is the robust service, not a postmortem.) *Publish angle:* "Writing a Go payment service that shuts down cleanly and never busy-spins." Milestone: comfortable in tmux + vim.
- **Week 2 — Filesystems, disk, memory.** *Learn:* mounts, inodes, `df`/`du`, page cache, swap, the OOM killer. *Build:* structured, rotated transaction logging; a sane disk layout for logs vs. data. *Harden:* bound disk use (rotation + retention) so a busy day can't fill `/`; understand the OOM killer and set limits so the ledger writer degrades predictably under pressure. *Publish angle:* "Designing a payments box that can't fill its own disk."
- **Week 3 — systemd & logging.** *Learn:* units, `systemctl`, `journalctl`, restart policies, log rotation. *Build:* production-grade unit files for both services; journald integration; restart-on-failure; start-on-boot. *Harden:* correct restart semantics (no crash-loop hiding a real fault), readable structured logs, a defined healthy baseline you can recognize on sight. *Publish angle:* "Running Go services as real systemd units — and reading the truth from journalctl."
- **Week 4 — Networking fundamentals.** *Learn:* TCP/IP, DNS, ports, `ss`, `dig`, `curl`, `tcpdump`, `mtr`. *Build:* `payment-api` ↔ `fake-psp` over the network with sensible timeouts and connection reuse. *Harden:* correct resolution + retry at the PSP boundary, connection-pool sizing; capture a *healthy* charge so you know normal. *Publish angle:* "Network debugging for a payments call, from the packet up." Milestone: finish **Linux Foundation 101**.

## Phase 2 — AWS Core + Observability (Weeks 5–10)

> **Why it's common-core:** every discipline ships on a cloud and lives by its telemetry. SRE defines SLOs on these metrics; DevOps gates deploys on them; Platform exposes them to tenants. Same instrumentation, built once, three uses. **Week 7 is the data-correctness centerpiece.**

- **Week 5 — AWS compute & networking.** *Learn:* EC2, VPC, subnets, security groups, route tables. *Build:* a correctly-segmented VPC (public/private subnets, the API↔DB path). *Harden:* least-open SGs, correct routing; understand SG-block / NACL-lockout / broken-route as what your design avoids. *Publish angle:* "Designing a VPC so a payment API can reach its ledger — and nothing else can."
- **Week 6 — IAM & access.** *Learn:* IAM users/roles/policies, least privilege, STS, KMS basics. *Build:* least-privilege roles per service; encrypt token/PII fields with KMS. *Harden:* scope every permission tightly; understand the permission-denied and KMS-denied paths so access is correct-by-design; rotate credentials. *Publish angle:* "Least-privilege IAM for a payments service, done properly."
- **Week 7 — Storage & databases: the ledger goes to RDS *(DB-depth centerpiece)*.** *Learn:* S3, EBS, RDS; **Postgres operational depth — transaction isolation levels, row locking (`SELECT … FOR UPDATE`), connection pooling, snapshots, restore.** *Build:* move the double-entry ledger to RDS; make the **invariant (debits == credits) hold under *concurrent* charges** — the unique-key idempotency guard at the DB level, atomic two-row writes in one transaction, the right isolation level to prevent lost updates and double-spend; size a connection pool for the workload. *Harden:* prove the invariant under concurrent load; understand pool exhaustion and isolation anomalies (phantom reads, lost updates) as the correctness threats you defend against; rehearse a snapshot restore. *Publish angle:* "Making a double-entry ledger correct under concurrency: Postgres isolation, locking, and the invariant." *(Strong, senior-signaling, lane-neutral deep-dive.)*
- **Week 8 — Load balancing & scaling.** *Learn:* ALB/ELB, target groups, ASG, health checks. *Build:* ALB in front of `payment-api`; ASG behind it; honest health checks reflecting real readiness. *Harden:* graceful connection draining on deploy/scale-in so in-flight charges aren't dropped. *Publish angle:* "Health checks that tell the truth (so payments don't drop when you scale)."
- **Week 9 — CloudWatch & alarms.** *Learn:* metrics, logs, alarms, dashboards, CloudTrail. *Build:* a payment-success-rate metric + dashboard; alarms on real conditions (error rate, latency, the invariant). *Harden:* alarms that fire on genuine signal, validated against a known condition. *Publish angle:* "The handful of metrics a payments service actually needs to watch."
- **Week 10 — Prometheus + Grafana + SLOs.** *Learn:* scraping, PromQL, Grafana; SLI/SLO/error-budget concepts. *Build:* instrument NovaPay end-to-end; dashboards for success rate, p99 latency, and the **ledger-balance invariant**. *Harden:* define SLOs as targets you build toward; make the invariant observable in real time. *Publish angle:* "My first payments SLOs and the invariant they watch." Milestone: **AWS SAA exam (~wk 12).** *First AI step:* Claude summarizes a CloudWatch log dump into plain English.
  - **★ Soft-lean pulse (light, optional):** you've now built the systems, cloud, and observability layers. Jot one line in `checkpoint.md` on which kind of work you're enjoying. Not a decision — just a signal so the Week-20 checkpoint isn't a cold start.

## Phase 3 — Containers & Kubernetes (Weeks 11–16)

> **Why it's common-core:** containers and Kubernetes are the universal runtime. SRE keeps the cluster reliable; DevOps deploys to it; Platform turns it into a self-service substrate. Nobody in the triad skips it.

- **Week 11 — Docker.** *Learn:* images, layers, networking, volumes. *Build:* lean, correct images for both services (multi-stage, small, non-root). *Harden:* minimal images, correct in-container signal handling (graceful shutdown still works), no secrets baked in. *Publish angle:* "Building small, correct Go containers for a payments service."
- **Week 12 — Kubernetes core.** *Learn:* pods, deployments, services, `kubectl`, `k9s`. *Build:* deploy NovaPay to a cluster; correct service wiring. *Harden:* understand CrashLoopBackOff / ImagePullBackOff / misconfigured-service as the failure modes you read fluently and design out. *Publish angle:* "Reading a CrashLoopBackOff like a story." (SAA exam this week.)
- **Week 13 — K8s health & scheduling.** *Learn:* liveness/readiness probes, resource limits/requests. *Build:* correct probes for `payment-api`; right-sized requests/limits. *Harden:* readiness that doesn't flap and drop in-flight payments; limits that prevent an OOMKill of the ledger worker. *Publish angle:* "Probes and limits that keep a payment pod alive mid-charge."
- **Week 14 — K8s networking & storage.** *Learn:* cluster DNS, ingress, ConfigMaps/Secrets, PVCs. *Build:* ingress + secrets for DB/PSP creds; config via ConfigMaps. *Harden:* correct in-cluster DNS to Postgres, ingress config, no missing-ConfigMap surprises. *Publish angle:* "Wiring secrets and DNS for a payments stack on Kubernetes."
- **Week 15 — EKS on AWS + Helm.** *Learn:* EKS, node groups, Helm. *Build:* move NovaPay to EKS; Helm-chart it for repeatable deploys. *Harden:* node-group resilience; clean Helm release + rollback. *Publish angle:* "Packaging a payments stack as a Helm release on EKS."
- **Week 16 — CKA practice.** *Learn:* timed `kubectl` drills. *Build/Harden:* replay your hardening work under exam time pressure; tighten anything fragile. Milestone: **CKA exam (~wk 18–20).** *AI step:* an agent that watches `kubectl` events and flags a likely root cause.

## Phase 4 — Infrastructure as Code + CI/CD (Weeks 17–20)

> **Why it's common-core:** IaC and CI/CD are the connective tissue — "DevOps" in name, but an SRE owns them for reproducibility and a Platform engineer wraps them into golden paths. **This phase completes the shared stack — which is exactly why the checkpoint comes right after.**

- **Week 17 — Terraform basics.** *Learn:* providers, resources, state, variables. *Build:* the entire NovaPay lab as Terraform — one `apply` rebuilds it. *Harden:* reproducibility — destroy and recreate cleanly; state hygiene. *Publish angle:* "I can rebuild my whole payments lab with one command."
- **Week 18 — Terraform state & modules.** *Learn:* remote state, modules, drift, locking. *Build:* modularize (network / data / app); remote state. *Harden:* detect and correct drift; handle state-lock conflicts; the RDS module is correct and recoverable. *Publish angle:* "Modular Terraform for a payments platform — and keeping state honest."
- **Week 19 — CI/CD with GitHub Actions.** *Learn:* pipelines, build/test/deploy, secrets, OIDC. *Build:* a pipeline for `payment-api` — build, **test (including the invariant + idempotency tests)**, deploy; OIDC instead of long-lived keys. *Harden:* a pipeline that **fails safely** — it won't ship a build that breaks the invariant; an automated rollback path. *Publish angle:* "A payments pipeline that refuses to ship a ledger-breaking build." *(Strong deep-dive.)*
- **Week 20 — GitOps intro.** *Learn:* Argo CD or Flux, declarative deploys. *Build:* GitOps for NovaPay; git as the source of truth. *Harden:* drift-correction, rejected-sync handling. Milestone: **HashiCorp Terraform Associate exam. → Common core complete. STOP at the checkpoint.**

---

# ★ THE DECISION CHECKPOINT (end of Week 20)

> **The gate the whole v2 plan is built around. The executing model (Sonnet) must stop here and ask you directly — do not auto-proceed into Part B.** This is also where the **break-on-purpose / chaos** identity (re)enters, *if and as your lane warrants*.

## Why the checkpoint is here

By the end of Week 20 you will have:
- **Built** the payments core correctly across Linux, AWS, Kubernetes, and IaC/CI-CD — every layer of the shared stack, with the invariant holding and the whole thing reproducible.
- **Earned SAA, CKA, and Terraform Associate.**
- A felt sense of which work energized you — because you'll have *done* all three flavors of it.

That dissolves the "blurry picture" problem. You choose from experience, not a guess.

## What you're choosing between (read this with your repo open)

Look back at the work and ask which parts you *enjoyed most*:
- **Reliability work** — chasing root cause through `/proc`, tuning an SLO, the idea of designing chaos experiments → **you lean SRE.**
- **Delivery work** — making a deploy safe and reversible, the pipeline that fails safely, shrinking the path from commit to prod → **you lean DevOps.**
- **Leverage work** — building something reusable other services inherit, paving a road so money-safety is automatic, one-command onboarding → **you lean Platform.**

| You probably lean… | …if these are true |
|---|---|
| **SRE** | Happiest when the system is *provably* stable. You think in percentiles and budgets. You'd rather prevent the 3am page than ship the feature. |
| **DevOps** | Happiest when the *flow* is smooth. Allergic to manual steps. You measure yourself in deploy frequency and lead time. |
| **Platform** | Happiest building *for builders*. You think one level up — not "fix this service" but "make it impossible for any service to have this bug." |

## What NovaPay becomes after you choose

Your pick sets the **spine** of Weeks 21–34 — and decides how the build/break balance shifts:

- **Choose SRE** → reliability & chaos becomes the spine. **This is where break-on-purpose lives:** deliberate FIS experiments, error-budget policy, postmortems-as-code. The scope ceiling stays tight.
- **Choose DevOps** → delivery becomes the spine. You *build* the release system (progressive delivery, GitOps, supply-chain, DORA); failures become stress-tests of what you built. **Relax the scope ceiling** — "this demonstrates delivery capability" is a valid reason to build.
- **Choose Platform** → the internal developer platform becomes the spine. You *build* the golden paths, scaffolding, and portal; breaking gets applied to the *platform's* blast radius. **Relax the scope ceiling** — building to demonstrate platform capability is the point.

## Mechanics

1. **Evidence-based, not final.** The cert backbone (DevOps Pro + CCA-F) serves all three; you can blend or pivot. This sets a *primary lens*, not a life sentence.
2. **Sonnet pauses at Week 20 and asks.** You answer SRE / DevOps / Platform (or "blend, lean X"). Opus then plans the chosen branch in full weekly detail.
3. **Log your reasoning in `checkpoint.md`** so the choice is traceable.

> **➡️ ACTION AT WEEK 20** — Sonnet asks: *"You've built the common core correctly and hold SAA + CKA + Terraform Associate. Reviewing the work, which energized you most — reliability (SRE), delivery (DevOps), or building for other developers (Platform)? Pick a primary lane and I'll plan Weeks 21–34 around it."*

---

# PART B — SPECIALIZATION (Weeks 21–34)

> **Summaries, not full plans.** The branch you pick gets expanded into detailed weekly briefs *at the checkpoint*. All three reconverge at CCA-F (weeks 33–34) and feed the same market-entry phase.

## Branch S — SRE lane *(break-on-purpose is the spine here)*
- **Wk 21–22 — Chaos with AWS FIS.** Graduate to managed chaos: instance termination, latency injection on `fake-psp`, API throttling. Post: "From building a payments system to breaking it on purpose."
- **Wk 23–24 — Error budgets in practice.** Burn-rate alerts; a policy that *halts a deploy* when the budget is spent. Post: "What an error budget decides when money's on the line."
- **Wk 25–26 — Runbooks & postmortems as code.** Blameless format; rewrite past failures as proper postmortems. Post: "The anatomy of a blameless payments postmortem."
- **Wk 27–28 — Capacity & resilience patterns.** Circuit breakers, graceful degradation; break a retry storm and stop it. Post: "Designing payments that fail gracefully."
- **Wk 29–32 — AIOps (SRE flavor).** An agent that triages alerts → proposes root cause → (gated) remediates wedged workers; never money movement.
- *Optional cert:* **Prometheus Certified Associate.**

## Branch D — DevOps lane *(build-heavy)*
- **Wk 21–22 — Progressive delivery.** Canary + blue-green for `payment-api`; promotion gated on metrics. Post: "Shipping payments without a maintenance window."
- **Wk 23–24 — Advanced GitOps & environments.** Multi-env promotion via Argo CD; drift correction; sealed secrets. Post: "GitOps for money: declarative all the way down."
- **Wk 25–26 — Supply chain & pipeline security.** SBOMs, image signing, dependency scanning, OIDC. Post: "Securing the path from commit to charge."
- **Wk 27–28 — DORA & deployment reliability.** Instrument lead time, deploy frequency, change-failure rate, MTTR. Post: "Measuring delivery the way the best teams do."
- **Wk 29–32 — AIOps (DevOps flavor).** An agent that correlates a regression to the offending change and drafts the rollback.
- *Cert focus:* lean hard into **AWS DevOps Engineer – Professional** here.

## Branch P — Platform lane *(build-heavy)*
- **Wk 21 — Golden path.** A templated service skeleton shipping with idempotency middleware, the ledger-invariant check, OpenTelemetry, and an SLO template *by default*. Post: "I made financial-safety the default." *(Headline candidate.)*
- **Wk 22 — Self-service scaffolding.** One-command onboarding wiring a tenant into Terraform, CI/CD, and observability (`copier`/Backstage + a thin CLI). Post: "Onboarding a payment service in one command."
- **Wk 23 — Developer portal & catalog.** Stand up Backstage (or a light portal): services, owners, runbook links, the golden-path template, TechDocs. Post: "A developer portal for a one-person payments platform."
- **Wk 24 — DevEx metrics & platform SLOs.** Instrument onboarding time + deploy frequency; an SLO for the platform itself. Post: "Measuring a platform like a product."
- **Wk 25–28 — Reliability/chaos applied to the platform.** FIS + error budgets targeting the platform's blast radius and the golden path's guarantees.
- **Wk 29–32 — AIOps (Platform flavor).** Ship an AI incident responder *as a platform capability* every tenant inherits via MCP.
- *Milestone:* **platform layer shipped** — demo a golden path, self-service onboarding, a catalog, and DevEx metrics in an interview.

## Reconvergence (all branches)
- **Weeks 33–34 — CCA-F prep + exam.** Anthropic Academy's free Skilljar courses; your planner/executor rig is already exam-relevant. Milestone: **Claude Certified Architect – Foundations.**

---

# PART C — MARKET ENTRY (Weeks 35–52)

*Keep the daily build + weekly deep-dive; tilt from learning toward landing, framed to your chosen lane.*

- **Month 8 — Portfolio polish.** `novapay-sre` becomes a clean case-study README. Reframe your LinkedIn headline to your lane (SRE / DevOps / Platform, all with FinTech + AI-ops). Posts shift to retrospectives.
- **Month 9 — AWS DevOps Engineer – Professional + Canadian targeting.** The money cert for all three lanes. Map your résumé to **NOC 21231** (design-led) and build a Canadian FinTech/cloud target list.
- **Month 10 — Applications + ATS optimization.** Optimize keywords to your lane (Terraform, Kubernetes, CI/CD, observability — plus *SLOs/SRE* **or** *release engineering* **or** *platform/golden paths/IDP*).
- **Month 11 — Interview prep.** System-design + incident-response drills weighted to your lane. Mock interviews.
- **Month 12 — Active applications, networking & close.** Engage Canadian communities; a year of public deep-dives is your social proof. Referrals beat cold applies.

---

## The spine, in one line

Payments core → **build it correctly: Linux → AWS + observability → Kubernetes → IaC/CI-CD (the common core)** → **★ choose your lane** → reliability/chaos (SRE) *or* delivery (DevOps) *or* platform (Platform) → AIOps, with **SAA → CKA → Terraform Associate → DevOps Pro** as the discipline-flexible backbone and **CCA-F** as the differentiator.

## The story you'll be able to tell

> "For a year I built and operated a production-like payments platform — a real double-entry ledger that stays balanced under concurrency, a money-movement API written with proper Go concurrency and deep Postgres correctness. I built the whole stack from a bare Linux box to EKS-on-Terraform, earned SAA + CKA + Terraform + DevOps Pro, and then — once I'd actually operated all of it — chose my specialty deliberately and went deep. Publicly, with a year of receipts."

That answers an SRE, a DevOps, *and* a platform interviewer — and shows judgment most candidates can't, because you built the foundation first and chose your lane from experience.
