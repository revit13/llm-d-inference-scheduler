#!/usr/bin/env bash
# test-squid-kind.sh — deploys the Squid implementation to a temporary kind cluster.
#
# Usage:
#   ./deploy/components/multimedia-downloader/implementations/squid/test-squid-kind.sh [--keep-cluster]
#
# Flags:
#   --keep-cluster   Keep the kind cluster on exit (useful for debugging).
#
# Requirements: kind, kubectl, docker

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="squid-smoke"
KEEP_CLUSTER=false
log() { echo -e "${YELLOW}==> $*${NC}"; }

# The base service.yaml is two levels up from the squid implementation.
BASE_DIR="${SCRIPT_DIR}/../.."
SERVICE_YAML="${BASE_DIR}/service.yaml"

# --- Colors / helpers ----------------------------------------------------------
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
section() { echo -e "\n${YELLOW}==> $*${NC}"; }

# --- Argument parsing ----------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep-cluster) KEEP_CLUSTER=true; shift ;;
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
    if [[ "${KEEP_CLUSTER}" == "false" ]]; then
        kind delete cluster --name "${CLUSTER_NAME}" 2>/dev/null
        echo "  Cluster '${CLUSTER_NAME}' deleted."
    else
        echo "  Cluster kept. Resources left in place for inspection."
        echo "  To delete: kind delete cluster --name ${CLUSTER_NAME}"
    fi
}
trap cleanup EXIT

section "Setting up kind cluster '${CLUSTER_NAME}'"
if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
    echo "  Reusing existing cluster."
else
    kind create cluster --name "${CLUSTER_NAME}" --wait 90s
    echo "  Cluster created."
fi
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

# --- Verification ---
TEST_URL="http://images.cocodataset.org/val2017/000000039769.jpg"
PROXY="http://multimedia-downloader:80"

# Clear the access log before testing
kubectl exec -it deployment/multimedia-downloader -c squid -- truncate -s 0 /var/cache/squid/access.log

log "Creating long-lived test pod for curl commands"
kubectl run curl-test-pod --image=curlimages/curl --restart=Never -- sleep 3600

# Wait for pod to be ready
kubectl wait --for=condition=Ready pod/curl-test-pod --timeout=60s
echo "  Test pod ready."

log "Testing Cache (2 requests to verify TCP_MISS then TCP_HIT)"
for i in {1..2}; do
    echo "Request $i to $TEST_URL via $PROXY..."
    kubectl exec curl-test-pod -- curl -s -x "$PROXY" "$TEST_URL" -o /dev/null
    sleep 1  # Small delay between requests for clearer log separation
done

log "Results (Checking TCP_MISS/TCP_HIT)"
kubectl logs -l app=multimedia-downloader -c log-tailer --tail=20 | grep -E "TCP_.*_HIT|TCP_MISS" || echo "No logs found."

log "Cleaning up test pod"
kubectl delete pod curl-test-pod --wait=false

exit 0
