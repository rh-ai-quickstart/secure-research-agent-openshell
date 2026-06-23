---
name: deploy-aiq-openshell
description: >-
  Deploy the AIQ secure research agent inside an NVIDIA OpenShell sandbox on
  OpenShift. Covers the full stack: OpenShell gateway, AIQ Helm chart,
  credential isolation (inference.local), sandbox creation, CA bundle, TCP
  proxy, and agent startup via nsenter. Use when the user asks to deploy,
  redeploy, or troubleshoot the AIQ research agent quickstart on OpenShift.
---

# Deploy AIQ Research Agent on OpenShell (OpenShift)

Full-stack deployment: OpenShell gateway + AIQ application + sandbox with
five security layers. This skill is self-contained — it includes the gateway
steps so it works standalone.

## Inputs

```bash
NAMESPACE="${NAMESPACE:-openshell}"
RELEASE_NAME="${RELEASE_NAME:-secure-research-agent}"
OPENSHELL_RELEASE="${OPENSHELL_RELEASE:-openshell}"
CHART_REF="${CHART_REF:-oci://ghcr.io/nvidia/openshell/helm-chart}"
CHART_VERSION="${CHART_VERSION:-0.0.0-dev}"
NVIDIA_API_KEY="${NVIDIA_API_KEY}"               # required
TAVILY_API_KEY="${TAVILY_API_KEY}"               # required
SANDBOX_IMAGE="${SANDBOX_IMAGE:-quay.io/rh-ai-quickstart/aiq-openshell:latest}"
SANDBOX_NAME="${SANDBOX_NAME:-aiq-sandbox}"
EGRESS_POLICY="${EGRESS_POLICY:-config/policy-egress.yaml}"
```

## Step 0 — Environment setup

Before any deployment, verify that the required API keys are available as
shell environment variables. **Do NOT ask the user to paste keys into the
chat.** Instead, instruct them to export the keys in their terminal:

```bash
# Tell the user to run these in their terminal (not in chat):
export NVIDIA_API_KEY="nvapi-..."
export TAVILY_API_KEY="tvly-..."
```

**IMPORTANT — Agent shell caveat**: The Cursor agent shell does NOT inherit
environment variables from the user's terminal. You MUST:
1. Ask the user to export the keys in their IDE terminal FIRST
2. Read the terminal files to pick up the exported values
3. Set the keys in your own agent shell with `export`
4. Verify by checking key *length*, not just existence (empty strings pass `-z`)

```bash
if [ "${#NVIDIA_API_KEY}" -lt 10 ]; then
  echo "NVIDIA_API_KEY is not set or too short. Please run: export NVIDIA_API_KEY=nvapi-..."
  exit 1
fi
if [ "${#TAVILY_API_KEY}" -lt 10 ]; then
  echo "TAVILY_API_KEY is not set or too short. Please run: export TAVILY_API_KEY=tvly-..."
  exit 1
fi
echo "API keys verified (NVIDIA: ${#NVIDIA_API_KEY} chars, Tavily: ${#TAVILY_API_KEY} chars)."
```

Do NOT proceed to any deployment step until the keys are verified with
non-trivial length in the agent shell. Running `helm install` or
`openshell provider create` with empty keys creates broken state that
requires cleanup (`helm upgrade`, provider delete/recreate).

### Create `.openshell.env` from template

If `.openshell.env` does not exist, create it from `config/openshell.env.template`
and fill in the Tavily key. The NVIDIA key stays as a placeholder in the env
file — it is passed to the supervisor via `--env` on `sandbox create` and
injected by the inference routing proxy. Only the Tavily key (a non-inference
service) needs to be in the sandbox environment.

```bash
if [ ! -f .openshell.env ]; then
  cp config/openshell.env.template .openshell.env
  sed -i "s|TAVILY_API_KEY=tvly-\.\.\.|TAVILY_API_KEY=${TAVILY_API_KEY}|" .openshell.env
  echo "Created .openshell.env from template with Tavily key."
else
  echo ".openshell.env already exists."
fi
```

**Validate `.openshell.env`** — confirm critical variables are present before
proceeding. If any are missing the file is likely stale or hand-edited; delete
it and re-run the block above to regenerate from the current template.

```bash
MISSING=""
grep -q "^AIQ_EMBED_BASE_URL=https://inference.local/v1" .openshell.env || MISSING="${MISSING} AIQ_EMBED_BASE_URL"
grep -q "^SSL_CERT_FILE=" .openshell.env                                || MISSING="${MISSING} SSL_CERT_FILE"
grep -q "^REQUESTS_CA_BUNDLE=" .openshell.env                           || MISSING="${MISSING} REQUESTS_CA_BUNDLE"
grep -q "^CONFIG_FILE=" .openshell.env                                  || MISSING="${MISSING} CONFIG_FILE"
if [ -n "${MISSING}" ]; then
  echo "ERROR: .openshell.env is missing required variables:${MISSING}"
  echo "Delete .openshell.env and re-run the template copy step above."
  exit 1
fi
echo ".openshell.env validated — all required variables present."
```

## Phase 1 — OpenShell Gateway

### Step 1 — Verify cluster login

```bash
if ! oc whoami &>/dev/null; then
  echo "Not logged in. Run: oc login <api-server>"
  exit 1
fi
echo "Logged in as $(oc whoami) on $(oc whoami --show-server)"
```

### Step 2 — Prerequisites

```bash
kubectl apply -f https://github.com/kubernetes-sigs/agent-sandbox/releases/latest/download/manifest.yaml
oc new-project "${NAMESPACE}" 2>/dev/null || oc project "${NAMESPACE}"
```

### Step 3 — JWT signing keys

**CRITICAL**: Must exist BEFORE `helm install`. Without this, the gateway pod
stays in `ContainerCreating` with `secret "openshell-jwt-keys" not found`.

```bash
JWT_SECRET="${OPENSHELL_RELEASE}-jwt-keys"
if ! kubectl get secret "${JWT_SECRET}" -n "${NAMESPACE}" &>/dev/null; then
  TMPDIR=$(mktemp -d)
  openssl genpkey -algorithm Ed25519 -out "${TMPDIR}/signing.pem"
  openssl pkey -in "${TMPDIR}/signing.pem" -pubout -out "${TMPDIR}/public.pem"
  openssl rand -hex 16 > "${TMPDIR}/kid"
  kubectl create secret generic "${JWT_SECRET}" -n "${NAMESPACE}" \
    --from-file=signing.pem="${TMPDIR}/signing.pem" \
    --from-file=public.pem="${TMPDIR}/public.pem" \
    --from-file=kid="${TMPDIR}/kid"
  rm -rf "${TMPDIR}"
fi
```

### Step 4 — Privileged SCC

```bash
oc adm policy add-scc-to-user privileged -z openshell-sandbox -n "${NAMESPACE}"
```

### Step 5 — Deploy OpenShell gateway

**IMPORTANT — Supervisor version**: Embedding routing through `inference.local`
requires supervisor **≥ 0.0.63** (PR #1774). Chart version `0.0.48` ships
supervisor 0.0.48 which does NOT support `/v1/embeddings` — embedding requests
get `403 connection not allowed by policy`. Use `0.0.0-dev` (or a tagged
release ≥ 0.0.63 once available) and set `image.tag` / `supervisor.image.tag`
accordingly.

```bash
helm install "${OPENSHELL_RELEASE}" "${CHART_REF}" \
  --version "${CHART_VERSION}" \
  -n "${NAMESPACE}" \
  --set "image.tag=dev" \
  --set "supervisor.image.tag=dev" \
  --set pkiInitJob.enabled=false \
  --set server.disableTls=true \
  --set server.auth.allowUnauthenticatedUsers=true \
  --set podSecurityContext.fsGroup=null \
  --set securityContext.runAsUser=null \
  --wait --timeout 120s
```

### Step 6 — Verify gateway

```bash
kubectl rollout status statefulset/"${OPENSHELL_RELEASE}" -n "${NAMESPACE}" --timeout=120s
```

## Phase 2 — AIQ Application

### Step 7 — Deploy AIQ Helm chart

Deploys the UI, backend Service, OpenShift Routes, and environment secrets.

```bash
helm install "${RELEASE_NAME}" ./chart -n "${NAMESPACE}" \
  --set apiKeys.nvidia="${NVIDIA_API_KEY}" \
  --set apiKeys.tavily="${TAVILY_API_KEY}"
```

### Step 8 — Configure credential isolation

The NVIDIA API key is stored at the gateway level. The agent calls
`inference.local` instead of `integrate.api.nvidia.com`. The egress proxy
intercepts the request and injects the API key — it never enters the sandbox.

**IMPORTANT**: Do NOT suppress stderr with `2>/dev/null || true` on the
`provider create` and `inference set` commands — hidden failures here cause
the sandbox create in Step 9 to fail with `Missing provider: nvidia`.

```bash
oc port-forward svc/${OPENSHELL_RELEASE} 18080:8080 -n "${NAMESPACE}" &>/dev/null &
PF_PID=$!
sleep 3

openshell gateway add http://127.0.0.1:18080 --local --name ocp-qs 2>/dev/null || true
openshell gateway select ocp-qs

openshell provider create --name nvidia --type nvidia \
  --credential "NVIDIA_API_KEY=${NVIDIA_API_KEY}"

openshell inference set --provider nvidia \
  --model "nvidia/nemotron-3-nano-30b-a3b" --no-verify
```

Verify the port-forward is alive before running the `openshell` CLI commands.
If `provider create` fails with a connection error, re-establish the
port-forward and retry.

### Step 9 — Create sandbox

The `--env NVIDIA_API_KEY` passes the real key to the container environment
where the supervisor reads it (via `api_key_env` in the inference routes
file). The sandbox process itself only has the placeholder from `.openshell.env`.

**IMPORTANT — CLI version**: The `--env` flag requires `openshell` CLI **≥ 0.0.62**.
Check with `openshell --version`. Upgrade with `pip install --upgrade openshell`
if needed.

```bash
openshell sandbox create \
  --from "${SANDBOX_IMAGE}" \
  --name "${SANDBOX_NAME}" \
  --provider nvidia \
  --policy "${EGRESS_POLICY}" \
  --env "NVIDIA_API_KEY=${NVIDIA_API_KEY}" \
  --no-tty
```

The exit code will be non-zero because of the expected `connect_path is empty`
error, but the sandbox pod is still created. Check with `kubectl get pod`.

**Expected**: The command may show `connect_path is empty`. This is normal
on Kubernetes — it means the CLI could not establish an interactive SSH
session, but the sandbox pod is created successfully.

Wait for the pod:

```bash
kubectl wait --for=condition=Ready "pod/${SANDBOX_NAME}" -n "${NAMESPACE}" --timeout=300s
```

## Phase 3 — Agent Startup

### Step 10 — Copy environment and config files

```bash
# Copy .env (Tavily key, proxy config, embedding base URL; NVIDIA_API_KEY is a placeholder)
if [ -f .openshell.env ]; then
  oc cp .openshell.env "${NAMESPACE}/${SANDBOX_NAME}:/sandbox/.env" -c agent
else
  oc get secret aiq-sandbox-env -n "${NAMESPACE}" -o jsonpath='{.data.\.env}' \
    | base64 -d \
    | oc exec -i "${SANDBOX_NAME}" -n "${NAMESPACE}" -c agent -- tee /sandbox/.env > /dev/null
fi
oc exec "${SANDBOX_NAME}" -n "${NAMESPACE}" -c agent -- chown sandbox:sandbox /sandbox/.env

# Copy AIQ config (LLM endpoints point to inference.local)
oc cp config/config_openshell.yml "${NAMESPACE}/${SANDBOX_NAME}:/sandbox/config_openshell.yml" -c agent
oc exec "${SANDBOX_NAME}" -n "${NAMESPACE}" -c agent -- chown sandbox:sandbox /sandbox/config_openshell.yml
```

### Step 11 — Create combined CA bundle

The OpenShell egress proxy performs TLS inspection using an ephemeral CA at
`/etc/openshell-tls/openshell-ca.pem`. Python must trust it or all HTTPS
calls fail with `SSL: CERTIFICATE_VERIFY_FAILED`.

The `openshell.env.template` already includes the `SSL_CERT_FILE`,
`REQUESTS_CA_BUNDLE`, and `CURL_CA_BUNDLE` variables pointing to the
combined bundle. This step creates the bundle file they reference.

**IMPORTANT**: The template must have these variables **uncommented** (not
prefixed with `#`). If they are commented out, the `grep -q` check below
matches the comment and skips writing the real values — causing silent
SSL failures at runtime.

```bash
oc exec "${SANDBOX_NAME}" -n "${NAMESPACE}" -c agent -- bash -c '
  cat /etc/ssl/certs/ca-certificates.crt /etc/openshell-tls/openshell-ca.pem \
    > /sandbox/combined-ca-bundle.pem
  chown sandbox:sandbox /sandbox/combined-ca-bundle.pem
'

oc exec "${SANDBOX_NAME}" -n "${NAMESPACE}" -c agent -- bash -c '
  if ! grep -q "^SSL_CERT_FILE=" /sandbox/.env 2>/dev/null; then
    echo "" >> /sandbox/.env
    echo "SSL_CERT_FILE=/sandbox/combined-ca-bundle.pem" >> /sandbox/.env
    echo "REQUESTS_CA_BUNDLE=/sandbox/combined-ca-bundle.pem" >> /sandbox/.env
    echo "CURL_CA_BUNDLE=/sandbox/combined-ca-bundle.pem" >> /sandbox/.env
  fi
'
```

### Step 12 — Label pod and deploy TCP proxy

The agent runs inside a nested network namespace (10.200.0.2). Kubernetes
Services can only reach the pod's root namespace. A TCP proxy bridges the gap.

```bash
oc label pod "${SANDBOX_NAME}" -n "${NAMESPACE}" app=aiq-backend --overwrite

oc cp scripts/tcp-proxy.py "${NAMESPACE}/${SANDBOX_NAME}:/tmp/tcp-proxy.py" -c agent
oc exec "${SANDBOX_NAME}" -n "${NAMESPACE}" -c agent -- \
  bash -c 'nohup python3 /tmp/tcp-proxy.py 8000 10.200.0.2 8000 > /tmp/proxy.log 2>&1 &'
sleep 2
```

### Step 13 — Start agent via nsenter

The agent MUST start inside the sandbox's network namespace. Using plain
`oc exec` runs in the root namespace, which causes `403 Forbidden` from the
egress proxy (wrong network context).

```bash
SLEEP_PID=$(oc exec "${SANDBOX_NAME}" -n "${NAMESPACE}" -c agent -- \
  bash -c 'ps -eo pid,comm --no-headers | grep sleep | head -1 | awk "{print \$1}"' \
  2>/dev/null | tr -d '[:space:]')

if [ -z "${SLEEP_PID}" ]; then
  echo "ERROR: Could not find sandbox sleep process."
  exit 1
fi

oc exec "${SANDBOX_NAME}" -n "${NAMESPACE}" -c agent -- \
  nsenter --net="/proc/${SLEEP_PID}/ns/net" -- \
  bash -c 'set -a; source /sandbox/.env; set +a; export PATH="/app/.venv/bin:$PATH"; python /app/deploy/entrypoint.py'
```

Wait for `Uvicorn running on http://0.0.0.0:8000` in the output.

### Step 13b — Verify sandbox environment

Before proceeding to validation, confirm the sandbox sourced the correct
environment. Both `NVIDIA_API_KEY` and `AIQ_EMBED_BASE_URL` must be set.
`NVIDIA_API_KEY` should show the placeholder (the real key is injected by the
supervisor at inference time). `AIQ_EMBED_BASE_URL` **must** be
`https://inference.local/v1` — if it is empty, embeddings will bypass
credential isolation and fail with `403`.

```bash
oc exec "${SANDBOX_NAME}" -n "${NAMESPACE}" -c agent -- \
  bash -c 'nsenter --net="/proc/$(ps -eo pid,comm --no-headers | grep sleep | head -1 | awk "{print \$1}")/ns/net" -- \
  bash -c "set -a; source /sandbox/.env; set +a; echo NVIDIA_API_KEY=\$NVIDIA_API_KEY; echo AIQ_EMBED_BASE_URL=\$AIQ_EMBED_BASE_URL"'
```

Expected output:
```
NVIDIA_API_KEY=credential-managed-by-openshell-gateway
AIQ_EMBED_BASE_URL=https://inference.local/v1
```

If `AIQ_EMBED_BASE_URL` is empty or missing, the `/sandbox/.env` was not
generated from the current template. Fix by deleting the stale `.openshell.env`
locally, regenerating it from `config/openshell.env.template` (Step 0), and
re-copying it into the sandbox (Step 10). Then restart the agent (Step 13).

## Phase 4 — Validation

### Step 14 — Verify the deployment

```bash
# Health check (from inside the cluster)
oc exec -n "${NAMESPACE}" deploy/aiq-ui -- \
  curl -sf http://aiq-backend.${NAMESPACE}.svc:8000/health

# Or port-forward and test locally
oc port-forward "pod/${SANDBOX_NAME}" 8000:8000 -n "${NAMESPACE}" &>/dev/null &
sleep 2
curl -s http://127.0.0.1:8000/health
# {"status":"healthy"}

curl -s http://127.0.0.1:8000/v1/jobs/async/agents
# {"agents":[{"agent_type":"deep_researcher",...},{"agent_type":"shallow_researcher",...}]}
```

### Step 15 — Test a research query

```bash
JOB_ID=$(curl -s -X POST http://127.0.0.1:8000/v1/jobs/async/submit \
  -H 'Content-Type: application/json' \
  -d '{"input":"What is OpenShift?","agent_type":"shallow_researcher"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['job_id'])")
echo "Job ID: ${JOB_ID}"

# Poll for results
curl -s "http://127.0.0.1:8000/v1/jobs/async/job/${JOB_ID}" | python3 -m json.tool
```

### Step 16 — Get UI URL

```bash
echo "https://$(oc get route aiq-ui -n "${NAMESPACE}" -o jsonpath='{.spec.host}')"
```

## Cleanup

```bash
openshell sandbox delete "${SANDBOX_NAME}" 2>/dev/null
helm uninstall "${RELEASE_NAME}" -n "${NAMESPACE}" 2>/dev/null
helm uninstall "${OPENSHELL_RELEASE}" -n "${NAMESPACE}" 2>/dev/null
oc adm policy remove-scc-from-user privileged -z openshell-sandbox -n "${NAMESPACE}" 2>/dev/null
kubectl delete -f https://github.com/kubernetes-sigs/agent-sandbox/releases/latest/download/manifest.yaml 2>/dev/null
oc delete project "${NAMESPACE}"
```

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Gateway pod `ContainerCreating` | JWT secret missing | Create secret before `helm install` (Step 3) |
| `connect_path is empty` | Expected on K8s | Non-fatal; sandbox pod is created; interact via `oc exec` |
| `SSL: CERTIFICATE_VERIFY_FAILED` | Missing ephemeral CA trust | Run Step 11; ensure `SSL_CERT_FILE` etc. are **uncommented** in `.env` (not prefixed with `#`) |
| `SSL_CERT_FILE` is empty at runtime | Template had CA vars commented out; `grep -q SSL_CERT_FILE` matched the comment and skipped | Use `grep -q "^SSL_CERT_FILE="` (anchored match) or ensure template has vars uncommented |
| `403 Forbidden` from egress proxy | Agent running in root namespace | Start agent via `nsenter` (Step 13), not plain `oc exec` |
| `403 - connection not allowed by policy` on embeddings | Supervisor too old (< 0.0.63), or `AIQ_EMBED_BASE_URL` not set, or routes file missing | Upgrade to chart `0.0.0-dev` with `image.tag=dev` / `supervisor.image.tag=dev`; verify `AIQ_EMBED_BASE_URL=https://inference.local/v1` in `.env` and `OPENSHELL_INFERENCE_ROUTES` is set in the Containerfile |
| `410 Gone — model has reached end of life` on embeddings | Embedding model in `inference-routes.yaml` is deprecated | Update the `model` in the `openai_embeddings` route in `config/inference-routes.yaml` to the current model (e.g. `nvidia/llama-nemotron-embed-vl-1b-v2`), rebuild and push image, then recreate sandbox |
| `address already in use :8000` | TCP proxy and agent in same namespace | TCP proxy runs in root NS (`oc exec`), agent in sandbox NS (`nsenter`) |
| Image pull timeout | Registry unavailable | Delete sandbox and recreate; pod retries automatically |
| `chown: Invalid argument` during `podman build` | Containerfile uses UID 1000660000 which exceeds rootless podman's subuid range | Temporarily change the UID/GID in the Containerfile to a value within range (e.g. 65532), build and push, then revert. OpenShift assigns its own UID via SCC at runtime so the build-time value doesn't matter. Alternatively use `sudo podman build` if available |
| `environment variable NVIDIA_API_KEY not set for route` | Supervisor cannot find NVIDIA key for inference routing | Ensure `--env NVIDIA_API_KEY=${NVIDIA_API_KEY}` was passed on `openshell sandbox create` (Step 9) |
| `Missing provider: nvidia` on sandbox create | `provider create` failed silently | Re-establish port-forward, then run `openshell provider create` without `2>/dev/null` (Step 8) |
| `provider has no usable API key credential` on `inference set` | `provider create` ran with empty `NVIDIA_API_KEY` | Delete provider, verify key has non-trivial length, then recreate (see Step 0 caveat about agent shell) |
| Stale conversations in UI after redeployment | Browser localStorage from prior deploy | Handled automatically by the `cache-guard` nginx sidecar — it injects a deployment-versioned script that clears stale localStorage on first load after a redeploy. If the sidecar is not present (pre-v3 chart), clear browser localStorage manually or open in incognito |

## Credential isolation explained

| Service | Endpoint | Access method | Credential handling |
|---------|----------|--------------|-------------------|
| NVIDIA NIM (LLM) | `inference.local` | Supervisor proxy via inference routes file | Key injected by supervisor — never in sandbox |
| NVIDIA Embeddings | `inference.local` | Supervisor proxy via inference routes file | Key injected by supervisor — never in sandbox |
| Tavily | `api.tavily.com` | Direct via `network_policies` | Key in sandbox `.env` file |

Both LLM and embedding traffic route through `inference.local`. A standalone
inference routes file (`config/inference-routes.yaml`) is baked into the
sandbox image at `/app/inference-routes.yaml`. The supervisor loads it at
startup via the `OPENSHELL_INFERENCE_ROUTES` env var. Each route uses
`api_key_env: NVIDIA_API_KEY` — the supervisor reads the key from the
container environment (passed via `--env` on `sandbox create`) and injects
it into outgoing requests. The sandbox process only has a placeholder key.

The egress policy blocks `integrate.api.nvidia.com`, so even if the sandbox
process somehow obtained the real key, it cannot use it directly.

Tavily uses a direct endpoint because it is a non-inference service without
a provider profile.

## Alternative: Makefile

```bash
make install NAMESPACE=openshell NVIDIA_API_KEY=nvapi-... TAVILY_API_KEY=tvly-...
make start-agent NAMESPACE=openshell
```

See the project README for the full Makefile reference.
