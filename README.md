# NovaPay SRE Lab

A simulated production environment for a fictional fintech payment platform.

## What this is
90 days of real SRE work — incidents, diagnosis, resolution, and postmortems.
Every incident is documented here and published on LinkedIn.

## Repository Structure
- `postmortems/` — incident postmortems following Google SRE format
- `runbooks/` — step-by-step response guides for known incident types
- `infrastructure/` — server configs, systemd units, deployment scripts
- `monitoring/` — alert rules and dashboard configs
- `scripts/` — automation scripts

## Stack
- AWS EC2 (ap-south-2) — Ubuntu 24.04 LTS
- Docker + k3s (Phase 2)
- Prometheus + Grafana (Phase 2)

## Incident Log
| ID | Title | Severity | Status |
|---|---|---|---|
| INC-001 | SSH Disconnection During Payment Service Verification | P3 - Low | Resolved |
| INC-002 | Disk Exhaustion on NovaPay Payment Server | P1 - Critical | Resolved |
