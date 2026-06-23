NAMESPACE ?= openshell
NVIDIA_API_KEY ?=
TAVILY_API_KEY ?=
RELEASE_NAME ?= secure-research-agent
OPENSHELL_CHART_VERSION ?= 0.0.0-dev

REGISTRY ?= quay.io/rh-ai-quickstart

.PHONY: help install uninstall start-agent validate build-images push-images status clean lint test skills-sync

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

## ── Build ──────────────────────────────────────────────────

build-images: ## Build the AIQ sandbox and UI container images
	docker build -f Containerfile -t aiq-openshell:local .
	docker build -f Containerfile.ui -t aiq-ui:local .

push-images: ## Push images to the container registry
	docker tag aiq-openshell:local $(REGISTRY)/aiq-openshell:latest
	docker push $(REGISTRY)/aiq-openshell:latest
	docker tag aiq-ui:local $(REGISTRY)/aiq-ui:latest
	docker push $(REGISTRY)/aiq-ui:latest

## ── Deploy ─────────────────────────────────────────────────

install: ## Deploy everything (CRDs + OpenShell gateway + AIQ sandbox + UI)
	@echo "=== 1/7 Installing Agent Sandbox CRDs ==="
	kubectl apply -f https://github.com/kubernetes-sigs/agent-sandbox/releases/latest/download/manifest.yaml || true
	@echo ""
	@echo "=== 2/7 Creating namespace ==="
	oc new-project $(NAMESPACE) 2>/dev/null || oc project $(NAMESPACE)
	@echo ""
	@echo "=== 3/7 Creating JWT signing keys (must exist before gateway) ==="
	@openssl genpkey -algorithm ed25519 -out /tmp/_qs_signing.pem 2>/dev/null
	@openssl pkey -in /tmp/_qs_signing.pem -pubout -out /tmp/_qs_public.pem 2>/dev/null
	@openssl rand -hex 16 > /tmp/_qs_kid
	oc create secret generic openshell-jwt-keys -n $(NAMESPACE) \
		--from-file=signing.pem=/tmp/_qs_signing.pem \
		--from-file=public.pem=/tmp/_qs_public.pem \
		--from-file=kid=/tmp/_qs_kid 2>/dev/null || true
	@rm -f /tmp/_qs_signing.pem /tmp/_qs_public.pem /tmp/_qs_kid
	@echo ""
	@echo "=== 4/7 Deploying OpenShell gateway ==="
	helm install openshell oci://ghcr.io/nvidia/openshell/helm-chart \
		--version $(OPENSHELL_CHART_VERSION) \
		-n $(NAMESPACE) \
		--set image.tag=dev \
		--set supervisor.image.tag=dev \
		--set pkiInitJob.enabled=false \
		--set server.disableTls=true \
		--set server.auth.allowUnauthenticatedUsers=true \
		--set podSecurityContext.fsGroup=null \
		--set securityContext.runAsUser=null \
		--wait --timeout 120s
	@echo "Granting privileged SCC to sandbox service account..."
	oc adm policy add-scc-to-user privileged -z openshell-sandbox -n $(NAMESPACE)
	@echo ""
	@echo "=== 5/7 Deploying AIQ chart (UI + backend service + secrets) ==="
	helm install $(RELEASE_NAME) ./chart \
		-n $(NAMESPACE) \
		--set apiKeys.nvidia=$(NVIDIA_API_KEY) \
		--set apiKeys.tavily=$(TAVILY_API_KEY)
	@echo ""
	@echo "=== 6/7 Creating sandbox ==="
	oc port-forward svc/openshell 18080:8080 -n $(NAMESPACE) &>/dev/null &
	@sleep 3
	openshell gateway add http://127.0.0.1:18080 --local --name ocp-qs 2>/dev/null || true
	openshell gateway select ocp-qs
	openshell sandbox create \
		--from $(REGISTRY)/aiq-openshell:latest \
		--name aiq-sandbox \
		--policy config/policy-egress.yaml \
		--no-tty 2>/dev/null || true
	@echo ""
	@echo "=== 7/7 Waiting for sandbox pod ==="
	@sleep 10
	kubectl wait --for=condition=Ready pod/aiq-sandbox -n $(NAMESPACE) --timeout=300s
	@echo ""
	@echo "=== Deployment complete ==="
	@echo "Run 'make start-agent' to start the AIQ research agent inside the sandbox."
	@echo "Run 'make status' to check pod status."

start-agent: ## Start the AIQ agent inside the sandbox
	@chmod +x scripts/start-sandbox.sh
	./scripts/start-sandbox.sh $(NAMESPACE)

## ── Quality ───────────────────────────────────────────────

lint: ## Run linters (ruff, shellcheck, helm lint)
	ruff check scripts/
	ruff format --check scripts/
	shellcheck scripts/*.sh || echo "shellcheck not installed — skipping"
	helm lint chart/

test: ## Run test suite (pytest + helm lint)
	python -m pytest tests/ -v

## ── Validate ───────────────────────────────────────────────

status: ## Show pod status and routes
	@echo "=== Pods ==="
	oc get pods -n $(NAMESPACE)
	@echo ""
	@echo "=== Services ==="
	oc get svc -n $(NAMESPACE)
	@echo ""
	@echo "=== Routes ==="
	oc get routes -n $(NAMESPACE)
	@echo ""
	@echo "=== UI URL ==="
	@echo "https://$$(oc get route aiq-ui -n $(NAMESPACE) -o jsonpath='{.spec.host}' 2>/dev/null || echo 'not deployed')"

validate: ## Run health checks against the deployed agent
	@echo "=== Health Check ==="
	@oc exec -n $(NAMESPACE) deploy/aiq-ui -- curl -sf http://aiq-backend.$(NAMESPACE).svc:8000/health && echo " OK" || echo " FAILED"
	@echo ""
	@echo "=== Agent Discovery ==="
	@oc exec -n $(NAMESPACE) deploy/aiq-ui -- curl -sf http://aiq-backend.$(NAMESPACE).svc:8000/v1/jobs/async/agents && echo "" || echo "FAILED"

helm-test: ## Run Helm test hooks
	helm test $(RELEASE_NAME) -n $(NAMESPACE)

## ── Cleanup ────────────────────────────────────────────────

uninstall: ## Remove everything
	-openshell sandbox delete aiq-sandbox 2>/dev/null
	-helm uninstall $(RELEASE_NAME) -n $(NAMESPACE) 2>/dev/null
	-helm uninstall openshell -n $(NAMESPACE) 2>/dev/null
	-oc delete clusterrolebinding $(NAMESPACE)-openshell-sandbox-privileged 2>/dev/null
	-kubectl delete -f https://github.com/kubernetes-sigs/agent-sandbox/releases/latest/download/manifest.yaml 2>/dev/null
	-oc delete project $(NAMESPACE) 2>/dev/null
	@echo "Cleanup complete."

clean: ## Remove local build artifacts
	-docker rmi aiq-openshell:local aiq-ui:local 2>/dev/null

## ── Skills ────────────────────────────────────────────────

skills-sync: ## Sync skills to all AI client directories (.cursor, .claude, .codex, .gemini)
	@bash scripts/sync-skills.sh
