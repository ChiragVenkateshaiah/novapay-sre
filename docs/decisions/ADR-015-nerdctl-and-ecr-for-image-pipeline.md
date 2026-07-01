# ADR-015 — Local Image-Build Tooling and Container Registry: nerdctl and Amazon ECR
**Status:** Accepted
**Date:** 2026-07-01
**Phase:** Phase 1 · Week 2→3 · Linux & Systems Foundations

## Context

- The development laptop has 8GB RAM. Docker Desktop runs its own VM layer
  on top of WSL2 (a second virtualization layer, not a lightweight
  addition), plus a GUI and background daemon suite, consuming roughly
  2.5GB and causing noticeable slowdowns on this machine.
- Kubernetes removed direct Docker Engine support (dockershim) starting at
  v1.24 (2022). kubelet only talks to CRI-compliant runtimes. kubeadm-based
  clusters, including the one in ADR-014, default to containerd directly —
  Docker Engine is not present on the cluster nodes regardless of what's
  used locally to build images.
- Docker Desktop itself runs containerd internally to do the actual
  container work — the skill actually being sought (writing Dockerfiles,
  multi-stage builds, layer caching, image size optimization) does not
  require Docker Engine specifically, only something that can read a
  Dockerfile and produce an OCI-compliant image.
- nerdctl is containerd's native CLI, built to be command-compatible with
  Docker's CLI syntax (`nerdctl build`, `nerdctl run`, `nerdctl images`),
  and reads the same Dockerfile format.
- A locally built image exists only on the machine that built it. The
  worker node is a separate EC2 instance and has no access to the WSL2
  filesystem — it must fetch the image from a network-reachable registry.
  Three registries were considered: Amazon ECR, GitHub Container Registry
  (GHCR), and Docker Hub.
- The project already has an IAM user (`novapay-cli`) with least-privilege
  policies, established for EC2/security-group access.

## Decision

Use nerdctl + buildkitd in WSL2 for local image builds. Do not install
Docker Desktop. Dockerfile authoring (multi-stage builds, layer caching,
`.dockerignore`, image size optimization) remains a first-class skill to
build — only the local tool that executes it changes, not the skill
itself. This keeps the local build environment on the same runtime family
(containerd) as the cluster nodes it deploys to, avoiding a class of
"works locally, behaves differently on the node" discrepancy.

Push built images to Amazon ECR. The worker node's IAM role is granted
pull permissions on the ECR repository, reusing the project's existing
IAM setup rather than introducing a separate credential system. This
choice is scoped narrowly to image storage and access control — it does
not make the Kubernetes work itself AWS-specific; kubeadm, kubectl, and
everything CKA tests remain vendor-neutral regardless of which registry
backs them.

## Alternatives considered

**Docker Desktop** — rejected. Its VM-on-top-of-WSL2 layer plus GUI and
daemon suite is redundant given WSL2 is already a virtualization layer,
and its ~2.5GB footprint causes real slowdowns on an 8GB machine. The
Dockerfile-authoring skill Docker Desktop would teach is fully available
through nerdctl without the resource cost.

**GitHub Container Registry (GHCR)** — rejected as the primary choice.
Free for the project's already-public repository and would avoid adding a
new AWS surface, but the worker node would still need a separate
credential (e.g. a GitHub PAT) to authenticate pulls, rather than reusing
IAM that already exists.

**Docker Hub** — rejected. Free tier available, but anonymous/free-tier
pull rate limits are a real risk during active iteration, when the same
image may be pulled repeatedly while testing.

## Consequences

### What the system gains
- Lightweight local build environment (tens of MB idle footprint vs.
  gigabytes), no VM-on-VM redundancy on WSL2.
- Consistent runtime family (containerd) between local builds and cluster
  nodes.
- Dockerfile-authoring skill remains fully transferable to any
  Docker-based environment later, since the file format is identical.
- Registry access reuses existing IAM infrastructure rather than adding a
  second credential system.

### What the system gives up
- No Docker Desktop GUI (visual dashboard, one-click image/container
  cleanup) — CLI-only workflow, consistent with this project's existing
  manual-CLI discipline elsewhere.
- Image storage is coupled to AWS specifically (a portability trade-off,
  accepted deliberately — see Related Decisions on the project's
  AWS-first Cloud Engineer target).
- The worker node's network path to the ECR endpoint must be verified
  reachable (pre-flight check, per ADR-013's pattern) before it is assumed
  to work — this is now a required line item in the Kubernetes Week 1
  prerequisite checklist, not an assumption.

### CLAUDE.md constraint
"Local container image builds use nerdctl + buildkitd in WSL2, not Docker
Desktop — see ADR-015. Dockerfile syntax is unaffected; only the local
build tool differs. Cluster nodes run containerd (kubeadm default, no
Docker Engine present). Built images are pushed to Amazon ECR; the worker
node's IAM role has pull permissions on the ECR repository."

## Related decisions
- ADR-014 — the two-node kubeadm cluster this tooling builds images for,
  and the Staff/Principal Cloud Engineer / AWS-first target this registry
  choice is consistent with.
