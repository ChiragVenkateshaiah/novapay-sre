# ADR-014 — Certification Sequence, Target Career Path, and the Paired Linux/Kubernetes Curriculum Structure
**Status:** Accepted
**Date:** 2026-07-01
**Phase:** Phase 1 · Week 2→3 · Linux & Systems Foundations

## Context

- ADR-007's consequences section states certifications "(SAA -> CKA ->
  Terraform Associate -> DevOps Pro) are common prerequisites for all three
  lanes and are pursued in parallel." This ADR revises that stated order.
  ADR-007's actual discipline-neutral decision (SRE/DevOps/Platform
  undecided until the Week-20 checkpoint) is NOT revised here.
- ADR-008 deferred Terraform work inside NovaPay to Phase 4. A separate
  project, Cerberus, has since been started for OpenTofu/Terraform and
  cloud-engineering fundamentals.
- External cert-to-project-deliverable mapping notes were considered and
  rejected as the current plan (most describe work NovaPay has not done);
  a fabricated resume metric surfaced in that research ("cut release cycle
  times by 80% using automated CI/CD") is explicitly rejected and must not
  be used in any future portfolio material.
- Market research (Canada, 2026) compared compensation and role shape across
  Cloud Engineer, Senior Cloud Engineer, SRE, Principal Cloud Engineer, and
  Cloud/Solutions Architect. Principal Cloud Engineer and Architect land in
  a similar top-end band (~190k-217k CAD), but Architect roles carry a
  higher floor/median at equivalent seniority and structurally assume prior
  hands-on engineering credibility — the "hand designs to engineers to
  build" function only works if the architect has been that engineer.
- CKA's curriculum (v1.35) is Cluster Architecture/Install/Config (25%),
  Services & Networking (20%), Workloads & Scheduling (15%), Storage (10%),
  Troubleshooting (30%). Troubleshooting is the largest domain and is
  explicitly a "fixing," not "building," exam — scenarios like a worker
  node in NotReady state that must be SSH'd into and fixed, or a pod in
  CrashLoopBackOff that must be diagnosed. This directly matches NovaPay's
  existing incident-driven Linux/systemd practice (INC-003 through INC-007):
  a NotReady kubelet is a systemd-unit problem wearing a Kubernetes costume;
  a pod OOM-kill is the same cgroup mechanism as INC-007, one layer up.
- The current EC2 instance (t3.micro, 911MB RAM, zero swap) cannot host a
  real kubeadm control plane (etcd, API server, controller-manager,
  scheduler) plus a kubelet plus the existing payment-api/fake-psp/Postgres
  stack. Official kubeadm minimums are 2 vCPU / 2GB RAM per node, before
  application workloads are accounted for.

## Decision

1. NovaPay's build phase adds a permanent second track: Kubernetes,
   structured as a direct costume-layer on top of the existing Linux/
   systemd track, not a replacement for it. Both tracks continue
   indefinitely as co-equal parts of NovaPay's curriculum.
2. The two tracks are paired week-by-week under this rule: a Kubernetes
   week may only start once its paired Linux week is closed, and a new
   Linux topic-week may only start once the previous Kubernetes pairing is
   closed. Neither track is allowed to run more than one pairing ahead of
   the other. Concretely, starting now: Kubernetes Week 1 (calendar Week 3)
   pairs with the already-completed Linux Week 1 (process boundary — pod
   lifecycle, restart policies, probes); Kubernetes Week 2 (calendar Week 4)
   pairs with the already-completed Linux Week 2 (disk-fill/OOM — resource
   limits, pod eviction, PV/PVC); Linux Week 3 (calendar Week 5, new
   content, proposed topic: networking/namespaces/netfilter) is followed by
   Kubernetes Week 3 (calendar Week 6, costume: Services & Networking —
   CoreDNS, Ingress, NetworkPolicies). This alternation continues
   indefinitely.
3. GitHub Issues use a `costume:linux` / `costume:k8s` label pair. Every
   Kubernetes-costume incident's postmortem includes a `counterpart:
   INC-###` line pointing to its paired Linux incident where one exists,
   so the Linux-underneath-Kubernetes relationship is traceable in the
   artifact trail, not only in prose or retrospective write-ups.
4. Infrastructure is upgraded from the single t3.micro to a two-node
   cluster: a control-plane node on t3.small (2 vCPU/2GB) and a worker node
   on c7i-flex.large (2 vCPU/4GB). Two nodes rather than one combined node
   because CKA's largest domain (Troubleshooting, 30%) tests scenarios
   requiring a genuinely separate node to SSH into and fix (e.g. NotReady
   kubelet) — a single combined node cannot reproduce that incident class.
   The worker node is sized above the control-plane node specifically
   because it is the one under real memory pressure: kubelet + kube-proxy +
   CNI coexist there with the full payment-api/fake-psp/Postgres stack
   (the same workload previously running alone on t3.micro under systemd),
   whereas the control-plane node runs only etcd/apiserver/controller-
   manager/scheduler/kubelet/kube-proxy/CNI with no application workload.
   At the confirmed usage pattern (3 hours/day): t3.small control-plane
   ~$1.87/month + c7i-flex.large worker ~$7.63/month = ~$9.50/month total
   (US baseline pricing; ap-south-2 regional pricing was not confirmed and
   likely runs somewhat higher — verify via AWS Pricing Calculator before
   provisioning). This is roughly double the original $5/month target;
   the increase was accepted deliberately in favor of headroom on the
   worker node rather than fighting resource pressure while studying, over
   a cheaper two-t3.small-node alternative (~$3.74/month) that was
   considered and set aside for that reason. The prior t3.micro instance is
   retired once the app stack migrates onto the worker node — it is not
   kept running as a third box.
5. All Terraform/OpenTofu work remains owned exclusively by Cerberus (per
   ADR-008 and unchanged by this ADR).
6. The certification sequence is revised from SAA -> CKA -> Terraform
   Associate -> AWS DevOps Pro to: CKA -> Terraform Associate (via Cerberus)
   -> SAA -> AWS DevOps Pro. SAA's resequencing is an exam-timing choice
   only — existing AWS evidence (EC2 deployment, IAM least-privilege,
   INC-006 security-group debugging, VPC/network fundamentals) already
   supports SAA independent of future work.
7. Target career path is Staff/Principal Cloud Engineer (deep technical
   track) as the primary direction, with Cloud/Solutions Architect noted as
   a possible long-horizon (~20 year) pivot only. This narrows the cert
   sequence, not the SRE/DevOps/Platform discipline choice, which per
   ADR-007 remains open until the Week-20 checkpoint.

## Alternatives considered

**Pivoting NovaPay entirely to containerization, dropping the Linux/systemd
track** — rejected. CKA's largest domain is fundamentally Linux debugging in
a Kubernetes costume; abandoning the Linux track would remove the substrate
the Kubernetes track depends on.

**A separate, standalone Kubernetes project instead of extending NovaPay** —
rejected. NovaPay's existing incident-and-ADR discipline and its real
stateful workload (not a toy app) are the differentiator; a generic
from-scratch K8s-labs repo would lose that.

**Two t3.small nodes (control-plane + worker, symmetric, ~$3.74/month at 3
hrs/day) instead of upgrading the worker to c7i-flex.large** — rejected as
the final choice despite fitting the original $5/month target more cleanly.
Set aside in favor of extra worker-node headroom (kubelet + kube-proxy + CNI
+ the full payment-api/fake-psp/Postgres stack co-resident) so that
Kubernetes weeks aren't spent fighting resource pressure instead of studying
the intended concepts. Documented here as the cheaper fallback if cost
becomes a binding constraint later.

**A single larger EC2 node (e.g. one t3.medium or t3.large, control-plane
taint removed) instead of two nodes** — considered and rejected because it
cannot reproduce the NotReady-node/SSH-and-fix incident class that
Troubleshooting (30% of the CKA exam) specifically tests.

**Keeping the original ADR-007 cert order and Architect-as-primary target**
— rejected for the same reasons recorded in the prior version of this
decision (see Related Decisions).

## Consequences

### What the system gains
- A permanent, paired Linux/Kubernetes curriculum with an explicit
  anti-drift rule (neither track more than one pairing ahead), and a
  traceable costume:linux/costume:k8s incident pairing in GitHub Issues.
- New incident classes reachable only via a real second node (NotReady
  kubelet, pod eviction, scheduling failure), extending the INC-### series.
- A cert sequence and target career path aligned with actual evidence being
  built, and with 2026 Canada market data.

### What the system gives up
- A recurring EC2 cost (previously near-zero on t3.micro) — see cost
  figures above. Likely loses free-tier eligibility on this box.
- checkpoint.md's cert-sequence and architecture-table entries are now
  stale until updated (see Part 2 of this task).
- Cerberus's decisions log needs its Terraform-ownership cross-reference
  note re-added (it was reverted in Part 0).

### CLAUDE.md constraint
"NovaPay runs two permanent, paired tracks: Linux/systemd and Kubernetes.
A Kubernetes week cannot start before its paired Linux week closes; a new
Linux topic cannot start before the previous Kubernetes pairing closes.
GitHub Issues use costume:linux / costume:k8s labels; K8s incidents
reference their Linux counterpart via `counterpart: INC-###`. Cluster
infra: t3.small control-plane + c7i-flex.large worker (two nodes, not one;
worker sized up for headroom running the full payment-api/fake-psp/Postgres
stack alongside kubelet/kube-proxy/CNI) — ~$9.50/month at 3 hrs/day. The
prior t3.micro is retired once the app stack migrates to the worker node.
Cert sequence: CKA -> Terraform Associate (Cerberus) -> SAA -> AWS DevOps
Pro. Target career path: Staff/Principal Cloud Engineer — see ADR-014."

## Related decisions
- ADR-007 — discipline-neutral, Week-20-checkpoint decision, NOT revised
  here; only its stated cert order is revised.
- ADR-008 — Terraform-inside-NovaPay deferral, unchanged; Cerberus split
  was never in its scope.
