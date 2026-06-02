# Five Security Layers for AI Agent Sandboxing

This document explains the five layers of kernel-enforced security that OpenShell provides and how each is implemented in this quickstart. Putting an agent in a container is not enough — OpenShell adds defense-in-depth that protects against prompt injection, data exfiltration, credential theft, and unauthorized access even when the agent itself is compromised.

## Three Modes of Agent Sandboxing

Before diving into the security layers, it helps to understand where this quickstart fits in the broader landscape. Every agent sandboxing approach falls into one of three modes ([source](https://www.redhat.com/en/blog/red-hat-ai-and-openshell-driving-security-enhanced-agent-execution-for-enterprise-ai)):

| Mode | Name | What's sandboxed | When to use |
|------|------|-----------------|-------------|
| **1** | **Sandbox the whole thing** | Agent process + all tool calls + all code execution | Developer tooling, CI/CD, any environment where the host holds credentials the agent should never see |
| **2** | Sandbox via platform APIs | Only the execution environment; reasoning is decoupled (e.g., Anthropic self-hosted, Responses API) | Multi-tenant agent platforms, production workloads with data sovereignty requirements |
| **3** | Sandbox the execution only | Only agent-generated code; agent logic runs unsandboxed with full access | Starting point for adding sandboxing to existing agent deployments |

**This quickstart is Mode 1.** The entire AIQ research agent stack — reasoning (LLM calls), tool execution (web search, knowledge retrieval), and data storage (ChromaDB, SQLite) — runs inside a single OpenShell sandbox with all five enforcement layers active. Nothing goes in or out without explicit policy approval.

Mode 1 is the strongest isolation posture. The agent holds no credentials (NVIDIA API key is injected by the proxy), reaches no external services except through the policy-enforced egress proxy, and cannot modify its own code or system binaries. OpenShell on OpenShift delivers Mode 1 without additional integration — the OpenShift driver creates a sandboxed pod and applies all enforcement layers automatically.

For teams building multi-tenant agent platforms (Mode 2) or adding sandboxing to existing frameworks (Mode 3), see the [Related Reading](#related-reading) section for reference implementations using Anthropic self-hosted sandboxes, the Responses API with OGX, and OpenAI Agents SDK sandbox extensions.

## Overview

| # | Layer | What it protects against | Enforcement point |
|---|-------|------------------------|-------------------|
| 1 | [Network namespace isolation](#1-network-namespace-isolation) | Direct outbound connections bypassing policy | Linux network namespace + veth pair |
| 2 | [Landlock filesystem isolation](#2-landlock-filesystem-isolation) | System binary tampering, config manipulation, credential file access | Landlock LSM (kernel level) |
| 3 | [Per-binary network policy](#3-per-binary-network-policy) | Unauthorized processes reaching allowed endpoints | CONNECT proxy + OPA policy engine |
| 4 | [TLS inspection (ephemeral CA)](#4-tls-inspection-ephemeral-ca) | Payload-level policy evasion, undetected data exfiltration | Proxy TLS termination with per-sandbox CA |
| 5 | [Credential isolation](#5-credential-isolation) | API key exfiltration from compromised agents | Inference routing proxy with gateway-managed providers |

> **Additional automatic layers**: OpenShell also applies **seccomp BPF filtering** (blocking dangerous syscalls like `mount`, `ptrace`, `bpf`, `io_uring_setup`, and namespace creation) and **privilege drop** (`setuid`/`setgid` to the sandbox user with core dumps disabled). These are not user-configurable — OpenShell enforces them automatically on every sandbox. They are not listed as separate layers above because they require no configuration, but they provide critical defense against container escape and privilege escalation.

## 1. Network Namespace Isolation

**Threat**: A compromised agent opens a direct TCP connection to an attacker-controlled server, bypassing any proxy configuration.

**How OpenShell stops it**: Each sandbox runs in a dedicated Linux network namespace with its own network stack. A veth pair connects the sandbox (10.200.0.2) to the host side (10.200.0.1) where the egress proxy listens. The sandbox has no default route to the internet — all traffic must go through the proxy. Even if the agent ignores `HTTP_PROXY` environment variables, it can only reach the proxy.

**In this quickstart**: The AIQ agent runs inside the sandbox namespace at 10.200.0.2. A TCP proxy in the root namespace bridges port 8000 so Kubernetes Services can reach the agent. All outbound traffic from the agent goes through the egress proxy at 10.200.0.1:3128.

```
┌─────────────────────────────────────────┐
│ Pod (root network namespace)            │
│                                         │
│  TCP Proxy (:8000) ──┐                  │
│                      │ veth pair        │
│  ┌───────────────────┼───────────────┐  │
│  │ Sandbox namespace │               │  │
│  │                   ▼               │  │
│  │  AIQ Agent (10.200.0.2:8000)      │  │
│  │       │                           │  │
│  │       ▼                           │  │
│  │  Egress Proxy (10.200.0.1:3128)   │  │
│  │       │                           │  │
│  └───────┼───────────────────────────┘  │
│          ▼                              │
│   Policy check → allow/deny             │
└─────────────────────────────────────────┘
```

## 2. Landlock Filesystem Isolation

**Threat**: A compromised agent modifies system binaries, reads credential files, overwrites TLS trust stores, or changes DNS resolution.

**How OpenShell stops it**: The Linux Landlock LSM restricts filesystem access at the kernel level. The sandbox supervisor applies a ruleset that separates paths into read-only and read-write groups. Even root inside the container cannot bypass Landlock — it is enforced by the kernel, not the application.

**In this quickstart** (from `config/policy-egress.yaml`):

| Access | Paths | Purpose |
|--------|-------|---------|
| Read-only | `/usr`, `/lib`, `/proc`, `/dev/urandom`, `/app`, `/etc`, `/var/log` | System libraries, application code, configuration |
| Read-write | `/sandbox`, `/tmp`, `/dev/null`, `/etc/hosts` | Agent workspace, temporary files |

The agent can read its own code at `/app` but cannot modify it. All persistent data (ChromaDB, SQLite databases, checkpoints) is written under `/sandbox/data`.

## 3. Per-Binary Network Policy

**Threat**: A compromised agent spawns a subprocess (e.g., `curl`, a downloaded script) that exfiltrates data to an allowed endpoint. Standard firewall rules would allow it because the destination is permitted.

**How OpenShell stops it**: The egress proxy identifies which binary initiated each connection by reading `/proc/<pid>/exe` (the kernel-trusted executable path). It SHA-256 hashes each binary on first use (trust-on-first-use). If a binary is replaced mid-session, the hash mismatch triggers an immediate deny. Network policies specify exactly which binaries can reach which endpoints.

**In this quickstart** (from `config/policy-egress.yaml`):

Only these binaries can reach `api.tavily.com`:
- `/app/.venv/bin/python`
- `/app/.venv/bin/python3.12`
- `/usr/bin/python3.12`
- `/app/.venv/bin/dask-worker`
- `/app/.venv/bin/dask-scheduler`
- `/usr/bin/curl`

If a compromised agent downloaded a custom binary and tried to connect to Tavily, the proxy would deny it — the binary hash wouldn't match any allowed entry.

NVIDIA NIM (`integrate.api.nvidia.com`) is not listed in `network_policies` at all — it uses credential isolation through `inference.local` instead (see Layer 5).

## 4. TLS Inspection (Ephemeral CA)

**Threat**: An agent encodes exfiltrated data in HTTPS request headers, paths, or bodies to an allowed endpoint. Without inspecting the encrypted traffic, the proxy can only see the destination host — not what is being sent.

**How OpenShell stops it**: The proxy auto-detects TLS on every tunnel. When a TLS ClientHello is detected, the proxy terminates TLS using a per-sandbox ephemeral CA, inspects the HTTP request, and re-encrypts the traffic to the upstream. This enables:
- L7 inspection (HTTP method, path, headers, body)
- Credential injection (see Layer 5)
- Per-request policy enforcement (audit or enforce mode)

The ephemeral CA is generated at sandbox startup and stored at `/etc/openshell-tls/openshell-ca.pem`. The CA is unique per sandbox instance and destroyed when the sandbox is deleted.

**In this quickstart**: The `start-sandbox.sh` script creates a combined CA bundle (system CAs + OpenShell ephemeral CA) and sets `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`, and `CURL_CA_BUNDLE` so Python and curl trust the proxy's certificates. Without this, Python would reject the proxy's re-encrypted TLS with a `CERTIFICATE_VERIFY_FAILED` error.

## 5. Credential Isolation

**Threat**: A compromised agent reads API keys from environment variables or config files and exfiltrates them (e.g., by encoding them in a legitimate API call to an allowed endpoint).

**How OpenShell stops it**: API keys are stored as **providers** at the gateway level, outside the sandbox. The agent calls a local endpoint (`inference.local`) that carries no credentials. The proxy intercepts the request, looks up the configured provider, injects the API key as a Bearer token, and forwards to the real endpoint. The key never enters the sandbox — there is nothing to steal.

**In this quickstart**:

The NVIDIA API key uses full credential isolation:

```
Agent code                    Egress proxy                    NVIDIA NIM
    │                              │                              │
    │  POST inference.local/v1/    │                              │
    │  (no API key)                │                              │
    ├─────────────────────────────►│                              │
    │                              │  POST integrate.api.nvidia.  │
    │                              │  com/v1/chat/completions     │
    │                              │  Authorization: Bearer       │
    │                              │  nvapi-xxxxx (injected)      │
    │                              ├─────────────────────────────►│
    │                              │                              │
    │                              │◄─────────────────────────────┤
    │◄─────────────────────────────┤                              │
```

Setup:
```bash
# Store the API key at the gateway (done once)
openshell provider create --name nvidia --type nvidia \
  --credential NVIDIA_API_KEY=$NVIDIA_API_KEY

# Configure inference routing
openshell inference set --provider nvidia \
  --model nvidia/nemotron-3-nano-30b-a3b --no-verify
```

The agent config (`config/config_openshell.yml`) points all LLM endpoints to `https://inference.local/v1` instead of `https://integrate.api.nvidia.com/v1`. No `api_key` field exists in the config.

### Why Tavily is different

Tavily (web search) does **not** use credential isolation. Its API key is stored in the sandbox's `.env` file and included directly in API calls. This is because:

1. **No built-in provider profile** — OpenShell ships with provider profiles for `nvidia`, `claude-code`, and `github`. There is no `tavily` profile.
2. **Not an inference endpoint** — The `inference.local` routing is designed for LLM inference APIs. Tavily is a web search service with a different API pattern.
3. **Different auth mechanism** — Tavily uses an API key in the request body, not a Bearer token in the Authorization header. The proxy's credential injection uses `auth_style: bearer` with `header_name: authorization`.

This means the Tavily API key is the only credential inside the sandbox. To mitigate this:
- The egress policy restricts Tavily access to specific binaries (Python, Dask)
- The binary SHA-256 hash verification prevents unauthorized processes from using the key
- Tavily's scope is limited (web search only) compared to an LLM key that could be used for arbitrary inference

A custom provider profile could be created in the future to bring Tavily under the same credential isolation model.

## Verification

After deploying, you can verify each layer is active:

```bash
# 1. Network namespace: Agent runs in isolated namespace
oc exec aiq-sandbox -n openshell -c agent -- ss -tlnp
# Should show egress proxy at 10.200.0.1:3128

# 2. Landlock: Filesystem restrictions applied
openshell logs aiq-sandbox 2>&1 | grep "Landlock"
# Should show: CONFIG:BUILT — Landlock ruleset built [rules_applied:11]

# 3. Binary policy: Only allowed binaries can connect
openshell logs aiq-sandbox 2>&1 | grep "NET:LISTEN"
# Should show proxy listening on 10.200.0.1:3128

# 4. TLS inspection: Ephemeral CA generated
openshell logs aiq-sandbox 2>&1 | grep "TLS termination"
# Should show: CONFIG:ENABLED — TLS termination enabled

# 5. Credential isolation: NVIDIA API key not in sandbox
oc exec aiq-sandbox -n openshell -c agent -- \
  grep "^NVIDIA_API_KEY=" /sandbox/.env
# Should return nothing (exit code 1)
```

## Related Reading

- [Red Hat AI and OpenShell: Driving security-enhanced agent execution for enterprise AI](https://www.redhat.com/en/blog/red-hat-ai-and-openshell-driving-security-enhanced-agent-execution-for-enterprise-ai) — Three sandboxing modes, validated across Anthropic, Responses API, and OpenAI Agents SDK
- [Bringing Claude self-hosted sandboxes to OpenShell on Red Hat AI](https://www.redhat.com/en/blog/bringing-claude-self-hosted-sandboxes-openshell-red-hat-ai) — Credential isolation and inference routing patterns (Mode 2)
- [OpenShell Security Best Practices](https://github.com/NVIDIA/OpenShell) — Full control reference for all enforcement layers
- [NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell) — Open source sandbox runtime for autonomous AI agents
