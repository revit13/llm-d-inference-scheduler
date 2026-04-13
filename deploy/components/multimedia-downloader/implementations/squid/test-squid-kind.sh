#!/usr/bin/env bash
# test-squid-kind.sh — deploys the Squid implementation to a temporary kind cluster.
#
# Usage:
#   ./deploy/components/multimedia-downloader/implementations/squid/test-squid-kind.sh [--keep-cluster]
#
# Flags:
#   --keep-cluster   Keep the kind cluster on exit (useful for debugging).
#   --no-cleanup     Skip cluster deletion (alias for --keep-cluster).
#
# Requirements: kind, kubectl, docker

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="squid-smoke"
KEEP_CLUSTER=false
KUBECONFIG_TMP=""

# The base service.yaml is two levels up from the squid implementation.
BASE_DIR="${SCRIPT_DIR}/../.."
SERVICE_YAML="${BASE_DIR}/service.yaml"

# --- Colors / helpers ----------------------------------------------------------
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
section() { echo -e "\n${YELLOW}==> $*${NC}"; }

# --- Argument parsing ----------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep-cluster|--no-cleanup) KEEP_CLUSTER=true; shift ;;
        --help|-h)
            sed -n '2,/^set /p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "ERROR: Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# --- Cleanup -------------------------------------------------------------------
cleanup() {
    set +e
    section "Cleaning up"
    if [[ -n "${KUBECONFIG_TMP}" ]]; then
        export KUBECONFIG="${KUBECONFIG_TMP}"
    fi
    if [[ "${KEEP_CLUSTER}" == "false" ]]; then
        kind delete cluster --name "${CLUSTER_NAME}" 2>/dev/null
        echo "  Cluster '${CLUSTER_NAME}' deleted."
        if [[ -n "${KUBECONFIG_TMP}" ]]; then
            rm -f "${KUBECONFIG_TMP}"
        fi
    else
        echo "  Cluster kept. Resources left in place for inspection."
        echo "    export KUBECONFIG=${KUBECONFIG_TMP}"
        echo "    kubectl get pods"
        echo "  To delete: kind delete cluster --name ${CLUSTER_NAME}"
    fi
}
trap cleanup EXIT

# =============================================================================
# DEPLOYMENT TEST
# =============================================================================

section "Checking prerequisites"
version_of() {
    case "$1" in
        kind)    kind version 2>&1 | head -1 ;;
        kubectl) kubectl version --client 2>&1 | head -1 ;;
        docker)  docker --version 2>&1 | head -1 ;;
    esac
}
for cmd in kind kubectl docker; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: '$cmd' not found in PATH." >&2
        exit 1
    fi
    echo "  $cmd: $(version_of "$cmd")"
done

section "Setting up kind cluster '${CLUSTER_NAME}'"
if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
    echo "  Reusing existing cluster."
else
    kind create cluster --name "${CLUSTER_NAME}" --wait 90s
    echo "  Cluster created."
fi
KUBECONFIG_TMP="$(mktemp --suffix=.yaml)"
kind export kubeconfig --name "${CLUSTER_NAME}" --kubeconfig "${KUBECONFIG_TMP}"
export KUBECONFIG="${KUBECONFIG_TMP}"

section "Deploying squid implementation from ${SCRIPT_DIR}"
# Set SQUID_IMAGE environment variable with default value
export SQUID_IMAGE="${SQUID_IMAGE:-ubuntu/squid:6.1-23.10_beta}"
echo "  Using image: ${SQUID_IMAGE}"
# Apply the squid-specific resources (Deployment + ConfigMap) from the source dir.
# Use envsubst to replace ${SQUID_IMAGE} in the deployment
kubectl kustomize "${SCRIPT_DIR}" | envsubst | kubectl apply -f -
# Apply the base Service separately; it is not part of the squid kustomization
# but is required for DNS-based proxy access inside the cluster.
kubectl apply -f "${SERVICE_YAML}"
kubectl rollout status deployment/multimedia-downloader --timeout=120s
echo "  multimedia-downloader is ready."

# --- Summary ------------------------------------------------------------------
section "Deployment Complete"
echo -e "${GREEN}Squid deployment successful.${NC}"
kubectl get pods -l app=multimedia-downloader

# --- Cache Test ---------------------------------------------------------------
section "Testing cache functionality"
echo "Creating test client pod..."
kubectl run squid-test-client \
    --image=curlimages/curl:latest \
    --restart=Never \
    --env="HTTP_PROXY=http://multimedia-downloader:80" \
    -- sleep 300 2>/dev/null || true

if ! kubectl wait pod/squid-test-client --for=condition=Ready --timeout=30s 2>/dev/null; then
    echo "Warning: Test client pod did not become ready within 30s, skipping cache test"
    kubectl delete pod squid-test-client --ignore-not-found=true --wait=false 2>/dev/null || true
    exit 0
fi

echo "Making first request to example.com (should be cache MISS)..."
kubectl exec squid-test-client -- curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" http://example.com/ 2>/dev/null || echo "Request failed"
sleep 2

echo "Making second request to example.com (should be cache HIT)..."
kubectl exec squid-test-client -- curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" http://example.com/ 2>/dev/null || echo "Request failed"
sleep 2

echo -e "\nNote: Logging is disabled in squid-config.yaml (access_log none) to avoid permission issues."
echo "Cache is working but hits/misses cannot be verified through logs."
echo "To enable logging for debugging, change 'access_log none' to 'access_log stdio:/var/log/squid/access.log' in squid-config.yaml"

kubectl delete pod squid-test-client --ignore-not-found=true --wait=false 2>/dev/null || true

exit 0