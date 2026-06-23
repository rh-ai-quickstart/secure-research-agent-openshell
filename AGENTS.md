# Secure Research Agent — Agent Guidelines

## Purpose

Deploy NVIDIA AIQ research agents inside NVIDIA OpenShell sandboxes on OpenShift with five kernel-enforced security layers: network namespace isolation, Landlock filesystem, per-binary network policy, TLS inspection, and credential isolation.

## Skills

This project provides two deployment skills. Read the relevant SKILL.md before executing.

| Skill | Path | Use when |
|-------|------|----------|
| deploy-aiq-openshell | `skills/deploy-aiq-openshell/SKILL.md` | Full-stack deployment (gateway + AIQ + sandbox + agent startup) |
| deploy-openshell-openshift | `skills/deploy-openshell-openshift/SKILL.md` | Gateway-only deployment on OpenShift |

### Skill discovery

On first use, ensure skills are synced to your client's directory:

```bash
ls .cursor/skills/deploy-aiq-openshell/SKILL.md 2>/dev/null || bash scripts/sync-skills.sh
```

## Request Routing

| User Request | Route To |
|--------------|----------|
| "Deploy" / "Install" / "Set up the quickstart" | deploy-aiq-openshell |
| "Deploy the gateway" / "Install OpenShell" | deploy-openshell-openshift |
| "Troubleshoot" / "Fix SSL error" / "403 from proxy" | deploy-aiq-openshell (Troubleshooting section) |
| "Start the agent" / "Run start-sandbox" | deploy-aiq-openshell (Phase 3) |
| "Uninstall" / "Clean up" / "Delete everything" | deploy-aiq-openshell (Cleanup section) |

## Key Architecture

- **No application source code** — This repo is a deployment orchestration layer
- **Helm chart** (`chart/`) — Deploys UI, backend Service, secrets, OpenShift Route
- **Sandbox pod** — Created via `openshell sandbox create`, not Helm
- **Credential isolation** — NVIDIA API key never enters the sandbox; injected by egress proxy via `inference.local`
- **TCP proxy** (`scripts/tcp-proxy.py`) — Bridges root namespace (:8000) to sandbox namespace (10.200.0.2:8000)

## Important Files

| File | Purpose |
|------|---------|
| `config/policy-egress.yaml` | Sandbox security policy (Landlock paths + network endpoints) |
| `config/inference-routes.yaml` | Maps `inference.local` → NVIDIA NIM (baked into image) |
| `config/openshell.env.template` | Template for sandbox environment (copy to `.openshell.env`) |
| `config/config_openshell.yml` | AIQ agent workflow config (LLM endpoints at inference.local) |
| `scripts/start-sandbox.sh` | Agent initialization (CA bundle, TCP proxy, nsenter) |
| `Makefile` | `install`, `start-agent`, `status`, `validate`, `uninstall`, `lint`, `test` |

## Development

```bash
make lint    # ruff + shellcheck + helm lint
make test    # pytest (TCP proxy tests + Helm chart validation)
```

## Core Principles

- **Security by default** — All five OpenShell layers active; credentials isolated at gateway
- **No secrets in code** — API keys passed via env vars or Helm `--set`; never committed
- **Minimal changes** — Don't rewrite working infrastructure for style preferences
- **Verify before done** — Run `make lint && make test` after changes
