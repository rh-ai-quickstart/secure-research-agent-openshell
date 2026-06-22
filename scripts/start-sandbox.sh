#!/usr/bin/env bash
# Initialize and start the AIQ agent inside an OpenShell sandbox on OpenShift.
#
# Usage:
#   ./scripts/start-sandbox.sh [NAMESPACE]
#
# Prerequisites:
#   - Sandbox pod (aiq-sandbox) must be running
#   - OpenShell gateway port-forward active on localhost:18080
#   - NVIDIA provider configured (openshell provider create --name nvidia ...)
#   - .openshell.env in the repo root (or sandbox-env-secret deployed via Helm)
#
# Credential isolation:
#   The NVIDIA API key is stored at the gateway level and injected by the
#   OpenShell inference routing proxy. The agent calls inference.local
#   instead of integrate.api.nvidia.com. The key never enters the sandbox.
#
# Architecture:
#   The agent runs inside the sandbox's isolated network namespace via nsenter.
#   The OpenShell supervisor generates an ephemeral CA for TLS inspection.
#   A TCP proxy bridges port 8000 from root namespace to sandbox namespace.

set -euo pipefail

NAMESPACE="${1:-openshell}"
SANDBOX_POD="aiq-sandbox"

get_sandbox_pid() {
    # shellcheck disable=SC2016
    oc exec "${SANDBOX_POD}" -n "${NAMESPACE}" -c agent -- \
        bash -c 'ps -eo pid,comm --no-headers | grep "sleep" | head -1 | awk "{print \$1}"' 2>/dev/null | tr -d '[:space:]'
}

echo "=== 1/6 Copying environment and config files to sandbox ==="
if [ -f .openshell.env ]; then
    oc cp .openshell.env "${NAMESPACE}/${SANDBOX_POD}:/sandbox/.env" -c agent
else
    oc get secret aiq-sandbox-env -n "${NAMESPACE}" -o jsonpath='{.data.\.env}' \
        | base64 -d \
        | oc exec -i "${SANDBOX_POD}" -n "${NAMESPACE}" -c agent -- tee /sandbox/.env > /dev/null
fi
oc exec "${SANDBOX_POD}" -n "${NAMESPACE}" -c agent -- chown sandbox:sandbox /sandbox/.env

# Copy the credential-isolation config (uses inference.local for LLM endpoints)
oc cp config/config_openshell.yml "${NAMESPACE}/${SANDBOX_POD}:/sandbox/config_openshell.yml" -c agent
oc exec "${SANDBOX_POD}" -n "${NAMESPACE}" -c agent -- chown sandbox:sandbox /sandbox/config_openshell.yml
echo "Environment and config files ready."

echo ""
echo "=== 2/6 Creating combined CA bundle (system CAs + OpenShell ephemeral CA) ==="
oc exec "${SANDBOX_POD}" -n "${NAMESPACE}" -c agent -- bash -c '
cat /etc/ssl/certs/ca-certificates.crt /etc/openshell-tls/openshell-ca.pem > /sandbox/combined-ca-bundle.pem
chown sandbox:sandbox /sandbox/combined-ca-bundle.pem
'
oc exec "${SANDBOX_POD}" -n "${NAMESPACE}" -c agent -- bash -c '
if ! grep -q SSL_CERT_FILE /sandbox/.env 2>/dev/null; then
    echo "" >> /sandbox/.env
    echo "# Trust OpenShell egress proxy ephemeral CA" >> /sandbox/.env
    echo "SSL_CERT_FILE=/sandbox/combined-ca-bundle.pem" >> /sandbox/.env
    echo "REQUESTS_CA_BUNDLE=/sandbox/combined-ca-bundle.pem" >> /sandbox/.env
    echo "CURL_CA_BUNDLE=/sandbox/combined-ca-bundle.pem" >> /sandbox/.env
fi
'
echo "CA bundle created and SSL env vars set."

echo ""
echo "=== 3/6 Configuring NVIDIA inference provider (credential isolation) ==="
openshell provider create --name nvidia --type nvidia \
    --credential "NVIDIA_API_KEY" 2>/dev/null \
    && echo "NVIDIA provider created." \
    || echo "NVIDIA provider already exists."
openshell inference set --provider nvidia \
    --model "nvidia/nemotron-3-nano-30b-a3b" --no-verify 2>/dev/null || true
echo "Inference routing configured: inference.local -> NVIDIA NIM"

echo ""
echo "=== 4/6 Labeling sandbox pod for backend Service ==="
oc label pod "${SANDBOX_POD}" -n "${NAMESPACE}" app=aiq-backend --overwrite

echo ""
echo "=== 5/6 Deploying TCP proxy (root namespace -> sandbox namespace) ==="
oc cp scripts/tcp-proxy.py "${NAMESPACE}/${SANDBOX_POD}:/tmp/tcp-proxy.py" -c agent
oc exec "${SANDBOX_POD}" -n "${NAMESPACE}" -c agent -- \
    bash -c 'nohup python3 /tmp/tcp-proxy.py 8000 10.200.0.2 8000 > /tmp/proxy.log 2>&1 &'
sleep 2
echo "TCP proxy deployed."

echo ""
echo "=== 6/6 Starting AIQ agent inside sandbox network namespace ==="
SLEEP_PID=$(get_sandbox_pid)
if [ -z "$SLEEP_PID" ]; then
    echo "ERROR: Could not find sandbox sleep process. Is the sandbox running?"
    exit 1
fi
echo "Sandbox sleep PID: ${SLEEP_PID}"
echo "NVIDIA API key: isolated at gateway (not in sandbox)"
echo "Starting agent via nsenter into sandbox network namespace..."
echo ""

# shellcheck disable=SC2016
oc exec "${SANDBOX_POD}" -n "${NAMESPACE}" -c agent -- \
    nsenter --net="/proc/${SLEEP_PID}/ns/net" -- \
    bash -c 'set -a; source /sandbox/.env; set +a; export PATH="/app/.venv/bin:$PATH"; python /app/deploy/entrypoint.py'
