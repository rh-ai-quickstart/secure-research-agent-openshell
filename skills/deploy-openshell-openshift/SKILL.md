---
name: deploy-openshell-openshift
description: >-
  Deploy the NVIDIA OpenShell gateway on OpenShift using Helm. Handles cluster
  auth verification, namespace selection, JWT key generation, privileged SCC,
  Helm install with OpenShift overrides, and optional PostgreSQL persistence.
  Use when the user asks to deploy, reinstall, or upgrade OpenShell on OpenShift.
---

# Deploy OpenShell on OpenShift

Use `deploy/helm/openshell/README.md` in the upstream OpenShell repo as the
source of truth for Helm values, then apply this workflow.

## Inputs

```bash
NAMESPACE="${NAMESPACE:-openshell}"
RELEASE_NAME="${RELEASE_NAME:-openshell}"
CHART_REF="${CHART_REF:-oci://ghcr.io/nvidia/openshell/helm-chart}"
CHART_VERSION="${CHART_VERSION:-}"
GATEWAY_TAG="${GATEWAY_TAG:-}"
CLEAN_INSTALL="${CLEAN_INSTALL:-false}"
POSTGRES_ENABLED="${POSTGRES_ENABLED:-false}"
POSTGRES_MODE="${POSTGRES_MODE:-internal}"        # internal | external
POSTGRES_DB="${POSTGRES_DB:-openshell}"
POSTGRES_USER="${POSTGRES_USER:-openshell}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"
POSTGRES_HOST="${POSTGRES_HOST:-}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
```

## Step 1 — Verify cluster login

```bash
if ! oc whoami &>/dev/null; then
  echo "Not logged in. Run: oc login <api-server>"
  exit 1
fi
echo "Logged in as $(oc whoami) on $(oc whoami --show-server)"
```

Stop and ask the user to log in if this fails.

## Step 2 — Choose namespace

### Discover existing deployments

```bash
helm list --all-namespaces --filter "^${RELEASE_NAME}$" -o json 2>/dev/null
```

### Namespace selection rules

1. If user provides a namespace, use it.
2. Otherwise discover existing OpenShell releases and prompt for selection.
3. Always offer the option to deploy into a new namespace.
4. Default recommendation: `openshell`.

### Detect existing release

```bash
EXISTING=false
if helm status "${RELEASE_NAME}" -n "${NAMESPACE}" &>/dev/null; then
  EXISTING=true
elif kubectl get statefulset "${RELEASE_NAME}" -n "${NAMESPACE}" &>/dev/null; then
  EXISTING=true
fi
```

### Clean install — remove stale PVCs

Only when `CLEAN_INSTALL=true` and `EXISTING=false`. The Bitnami PostgreSQL
subchart bakes the password hash into its PVC — a leftover PVC with a different
password causes `FATAL: password authentication failed`.

```bash
if [ "${EXISTING}" = "false" ] && [ "${CLEAN_INSTALL}" = "true" ]; then
  kubectl delete pvc "data-${RELEASE_NAME}-postgres-0" -n "${NAMESPACE}" --ignore-not-found
  kubectl delete pvc "openshell-data-${RELEASE_NAME}-0" -n "${NAMESPACE}" --ignore-not-found
fi
```

## Step 3 — Select gateway version

Two values to resolve: `GATEWAY_TAG` (container image tag) and `CHART_VERSION`
(Helm chart version, only needed for OCI registry).

| Chart version | Image tag | Notes |
|---|---|---|
| `<semver>` (e.g. `0.6.0`) | `<semver>` | Tagged release |
| `0.0.0-dev` | `dev` | Latest commit on `main` |
| `0.0.0-<sha>` | `<sha>` | Per-commit pin |

### Derive chart version from gateway tag

```bash
if [[ -z "${CHART_VERSION}" && -n "${GATEWAY_TAG}" ]]; then
  if [[ "${GATEWAY_TAG}" == "dev" || "${GATEWAY_TAG}" =~ ^[0-9a-f]{40}$ ]]; then
    CHART_VERSION="0.0.0-${GATEWAY_TAG}"
  else
    CHART_VERSION="${GATEWAY_TAG}"
  fi
fi
```

### Derive gateway tag from chart version

```bash
if [[ -z "${GATEWAY_TAG}" && -n "${CHART_VERSION}" ]]; then
  case "${CHART_VERSION}" in
    0.0.0-*) GATEWAY_TAG="${CHART_VERSION#0.0.0-}" ;;
    *)       GATEWAY_TAG="${CHART_VERSION}" ;;
  esac
fi
```

If neither is provided, ask the user. Default: `GATEWAY_TAG=dev`,
`CHART_VERSION=0.0.0-dev`.

## Step 4 — Install shared prerequisites

```bash
kubectl apply -f https://github.com/kubernetes-sigs/agent-sandbox/releases/latest/download/manifest.yaml
oc new-project "${NAMESPACE}" 2>/dev/null || oc project "${NAMESPACE}"
```

## Step 5 — OpenShift prerequisites

**CRITICAL**: The JWT signing keys secret MUST exist BEFORE `helm install`.
If it does not, the gateway pod will stay in `ContainerCreating` with
`secret "openshell-jwt-keys" not found`.

```bash
JWT_SECRET="${RELEASE_NAME}-jwt-keys"
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
  echo "Created JWT signing secret ${JWT_SECRET}"
else
  echo "JWT signing secret ${JWT_SECRET} already exists"
fi

oc adm policy add-scc-to-user privileged -z openshell-sandbox -n "${NAMESPACE}"
```

## Step 6 — Deploy Helm release

```bash
HELM_ARGS=(
  upgrade --install "${RELEASE_NAME}" "${CHART_REF}"
  --namespace "${NAMESPACE}"
  --set "image.tag=${GATEWAY_TAG}"
  --set "supervisor.image.tag=${GATEWAY_TAG}"
  --set "postgres.enabled=${POSTGRES_ENABLED}"
  --set pkiInitJob.enabled=false
  --set server.disableTls=true
  --set server.auth.allowUnauthenticatedUsers=true
  --set podSecurityContext.fsGroup=null
  --set securityContext.runAsUser=null
  --wait --timeout 120s
)

if [[ "${CHART_REF}" == oci://* && -n "${CHART_VERSION}" ]]; then
  HELM_ARGS+=(--version "${CHART_VERSION}")
fi

if [[ -d "${CHART_REF}" ]]; then
  helm dependency build "${CHART_REF}"
fi

if [ "${POSTGRES_ENABLED}" = "true" ]; then
  HELM_ARGS+=(--set "postgres.mode=${POSTGRES_MODE}")
  if [ "${POSTGRES_MODE}" = "external" ]; then
    HELM_ARGS+=(
      --set "postgres.external.host=${POSTGRES_HOST}"
      --set "postgres.external.port=${POSTGRES_PORT}"
      --set "postgres.external.username=${POSTGRES_USER}"
      --set "postgres.external.password=${POSTGRES_PASSWORD}"
      --set "postgres.external.database=${POSTGRES_DB}"
    )
  else
    HELM_ARGS+=(
      --set "postgres.auth.username=${POSTGRES_USER}"
      --set "postgres.auth.password=${POSTGRES_PASSWORD}"
      --set "postgres.auth.database=${POSTGRES_DB}"
    )
  fi
fi

helm "${HELM_ARGS[@]}"
```

### OpenShift-specific overrides explained

| Override | Why |
|----------|-----|
| `pkiInitJob.enabled=false` | PKI init job fails under OpenShift SCCs; JWT keys created manually in Step 5 |
| `server.disableTls=true` | Simplifies dev/quickstart setups; gateway runs plaintext behind cluster network |
| `podSecurityContext.fsGroup=null` | OpenShift assigns fsGroup via SCC; explicit value conflicts |
| `securityContext.runAsUser=null` | OpenShift assigns UID via SCC; explicit value conflicts |
| `server.auth.allowUnauthenticatedUsers=true` | Dev/quickstart convenience; disable for production |

## Step 7 — Verify deployment

```bash
kubectl rollout status statefulset/"${RELEASE_NAME}" -n "${NAMESPACE}" --timeout=120s
kubectl get pods -n "${NAMESPACE}"
helm get values "${RELEASE_NAME}" -n "${NAMESPACE}"
```

Expected: `openshell-0` pod in `Running` state.

## Step 8 — Cleanup

```bash
helm uninstall "${RELEASE_NAME}" -n "${NAMESPACE}"
oc adm policy remove-scc-from-user privileged -z openshell-sandbox -n "${NAMESPACE}" 2>/dev/null
kubectl delete -f https://github.com/kubernetes-sigs/agent-sandbox/releases/latest/download/manifest.yaml 2>/dev/null
oc delete project "${NAMESPACE}"
```

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Gateway pod `ContainerCreating` | JWT secret missing | Run Step 5 before `helm install` |
| `forbidden: unable to validate against any security context constraint` | SCC not granted | `oc adm policy add-scc-to-user privileged -z openshell-sandbox -n $NAMESPACE` |
| `FATAL: password authentication failed` (PostgreSQL) | Stale PVC from prior install | Delete PVC: `kubectl delete pvc data-${RELEASE_NAME}-postgres-0 -n $NAMESPACE` |
| Image pull timeout | Registry temporarily unavailable | Wait and retry; pod retries with exponential backoff |

## Alternative: Makefile

The quickstart also provides a Makefile-based deployment:

```bash
make install NAMESPACE=openshell
```

See the project README for details.
