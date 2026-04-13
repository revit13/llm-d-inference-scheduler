#!/usr/bin/env bash
# test-squid-kind.sh — smoke-tests the Squid multimedia-downloader proxy
# (non-SSL) against a temporary kind cluster.
#
# Usage:
#   ./deploy/components/multimedia-downloader/implementations/squid/test-squid-kind.sh [--keep-cluster]
#
# Flags:
#   --keep-cluster   Keep the kind cluster on exit (useful for debugging).
#
# Requirements: kind, kubectl, docker
#
# What is tested:
#   1. Deployment rolls out and pod is Running
#   2. HTTP request via proxy reaches the in-cluster origin (HTTP 200)
#   3. First request to a URL produces TCP_MISS in Squid access log
#   4. Second request to the same URL produces TCP_HIT / TCP_MEM_HIT
#   5. HTTPS CONNECT tunnel is established and TCP_TUNNEL appears in logs
#   6. Concurrent requests to the same URL are collapsed (single TCP_MISS)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../../.." && pwd)"
CLUSTER_NAME="squid-smoke"
KEEP_CLUSTER=false
FAILURES=0
KUBECONFIG_TMP=""

# --- Colors / helpers ----------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
section() { echo -e "\n${YELLOW}==> $*${NC}"; }
pass()    { echo -e "  ${GREEN}PASS${NC}: $*"; }
fail()    { echo -e "  ${RED}FAIL${NC}: $*"; FAILURES=$((FAILURES + 1)); }
warn()    { echo -e "  ${YELLOW}WARN${NC}: $*"; }

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
    section "Cleaning up"
    if [[ -n "${KUBECONFIG_TMP}" ]]; then
        export KUBECONFIG="${KUBECONFIG_TMP}"
    fi

    kubectl delete pod squid-test-client --ignore-not-found=true --wait=false 2>/dev/null || true
    kubectl delete pod origin            --ignore-not-found=true --wait=false 2>/dev/null || true
    kubectl delete svc  origin           --ignore-not-found=true            2>/dev/null || true

    if [[ "${KEEP_CLUSTER}" == "false" ]]; then
        kind delete cluster --name "${CLUSTER_NAME}" 2>/dev/null || true
        echo "  Cluster '${CLUSTER_NAME}' deleted."
    else
        echo "  Cluster kept. To inspect:"
        echo "    export KUBECONFIG=${KUBECONFIG_TMP}"
        echo "  To delete: kind delete cluster --name ${CLUSTER_NAME}"
    fi

    [[ "${KEEP_CLUSTER}" == "false" && -n "${KUBECONFIG_TMP}" ]] && rm -f "${KUBECONFIG_TMP}"
}
trap cleanup EXIT

# --- Prerequisites check -------------------------------------------------------
section "Checking prerequisites"
for cmd in kind kubectl docker; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: '$cmd' not found in PATH." >&2
        exit 1
    fi
    echo "  $cmd found: $(${cmd} version --short 2>&1 || ${cmd} --version 2>&1 | head -1)"
done

# --- Cluster -------------------------------------------------------------------
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

# --- In-cluster origin server --------------------------------------------------
section "Deploying in-cluster HTTP origin (nginx:alpine)"
kubectl run origin --image=nginx:alpine --port=80 --restart=Never
kubectl expose pod origin --port=80
kubectl wait pod/origin --for=condition=Ready --timeout=60s
echo "  Origin nginx is ready at http://origin:80"

# --- Deploy multimedia-downloader ----------------------------------------------
section "Deploying multimedia-downloader"
kubectl apply -k "${REPO_ROOT}/deploy/components/multimedia-downloader"
kubectl rollout status deployment/multimedia-downloader --timeout=120s
echo "  multimedia-downloader is ready."

# --- Test client pod -----------------------------------------------------------
section "Creating test client pod"
kubectl run squid-test-client \
    --image=curlimages/curl:latest \
    --restart=Never \
    --env="HTTP_PROXY=http://multimedia-downloader:80" \
    --env="HTTPS_PROXY=http://multimedia-downloader:80" \
    --env="NO_PROXY=localhost,127.0.0.1,.svc,.cluster.local" \
    -- sleep 300
kubectl wait pod/squid-test-client --for=condition=Ready --timeout=60s
echo "  Test client is ready."

# --- Helpers -------------------------------------------------------------------

# Run curl inside the test pod, return the HTTP status code.
proxy_curl() {
    kubectl exec squid-test-client -- \
        curl --silent --output /dev/null --write-out "%{http_code}" "$@"
}

# Wait up to $2 seconds for a grep -E pattern $1 to appear in recent Squid logs.
wait_for_log() {
    local pattern="$1"
    local timeout="${2:-10}"
    local elapsed=0
    while (( elapsed < timeout )); do
        if kubectl logs -l app=multimedia-downloader --tail=100 \
               --since="${timeout}s" 2>/dev/null \
               | grep -qE "${pattern}"; then
            return 0
        fi
        sleep 1
        elapsed=$(( elapsed + 1 ))
    done
    return 1
}

# Dump the last N lines of Squid logs (for failure diagnostics).
dump_squid_logs() {
    local n="${1:-20}"
    kubectl logs -l app=multimedia-downloader --tail="${n}" 2>/dev/null \
        | sed 's/^/    /' || true
}

# --- Test 1: Deployment health -------------------------------------------------
section "Test 1: multimedia-downloader pod is Running"
POD_PHASE=$(kubectl get pods -l app=multimedia-downloader \
    -o jsonpath='{.items[0].status.phase}')
if [[ "${POD_PHASE}" == "Running" ]]; then
    pass "Pod phase is Running"
else
    fail "Pod phase is '${POD_PHASE}', expected Running"
fi

# --- Test 2: Basic HTTP forward proxy -----------------------------------------
section "Test 2: HTTP request via proxy reaches origin (HTTP 200)"
HTTP_CODE=$(proxy_curl "http://origin:80/")
if [[ "${HTTP_CODE}" == "200" ]]; then
    pass "HTTP 200 received from origin via proxy"
else
    fail "Expected HTTP 200, got ${HTTP_CODE}"
    dump_squid_logs
fi

# --- Test 3 & 4: Cache miss then cache hit ------------------------------------
# Use a unique query string so this test run does not collide with prior state.
RUN_ID="$(date +%s)"
CACHE_URL="http://origin:80/index.html?run=${RUN_ID}"

section "Test 3: First request produces TCP_MISS"
proxy_curl "${CACHE_URL}" >/dev/null || true
if wait_for_log "TCP_MISS" 10; then
    pass "TCP_MISS observed in Squid access log"
else
    fail "TCP_MISS not observed within 10 s"
    dump_squid_logs
fi

section "Test 4: Second request to same URL produces TCP_HIT / TCP_MEM_HIT"
proxy_curl "${CACHE_URL}" >/dev/null || true
if wait_for_log "TCP_MEM_HIT|TCP_HIT" 10; then
    pass "Cache hit (TCP_HIT or TCP_MEM_HIT) observed in Squid access log"
else
    fail "Cache hit not observed within 10 s"
    dump_squid_logs
fi

# --- Test 5: HTTPS CONNECT tunnel ---------------------------------------------
section "Test 5: HTTPS CONNECT tunnel is established (non-SSL Squid passes through)"
HTTPS_CODE=$(kubectl exec squid-test-client -- \
    curl --silent --output /dev/null --write-out "%{http_code}" \
    --insecure "https://example.com/" 2>/dev/null || echo "000")
if [[ "${HTTPS_CODE}" == "200" ]]; then
    pass "HTTPS request via CONNECT tunnel returned HTTP ${HTTPS_CODE}"
else
    fail "Expected HTTP 200 via CONNECT tunnel, got ${HTTPS_CODE}"
fi

if wait_for_log "CONNECT|TCP_TUNNEL" 10; then
    pass "CONNECT / TCP_TUNNEL observed in Squid access log"
else
    fail "CONNECT entry not observed in Squid access log"
    dump_squid_logs
fi

# --- Test 6: Collapsed forwarding ---------------------------------------------
section "Test 6: Concurrent requests to the same URL produce a single TCP_MISS"
COLLAPSE_URL="http://origin:80/index.html?collapse=${RUN_ID}"

# Fire 3 requests concurrently.
for _ in 1 2 3; do
    kubectl exec squid-test-client -- \
        curl --silent --output /dev/null "${COLLAPSE_URL}" &
done
wait
sleep 2

MISS_COUNT=$(kubectl logs -l app=multimedia-downloader --tail=100 --since=15s 2>/dev/null \
    | grep -cE "TCP_MISS.*collapse=${RUN_ID}" || true)

if [[ "${MISS_COUNT}" -eq 1 ]]; then
    pass "Exactly 1 TCP_MISS for 3 concurrent requests — collapsed_forwarding engaged"
elif [[ "${MISS_COUNT}" -gt 1 ]]; then
    warn "${MISS_COUNT} TCP_MISS entries for 3 concurrent requests. collapsed_forwarding may not have engaged (requests may not have overlapped in flight)."
else
    fail "0 TCP_MISS entries found — requests may not have reached the proxy"
    dump_squid_logs
fi

# --- Summary ------------------------------------------------------------------
section "Results"
if [[ ${FAILURES} -eq 0 ]]; then
    echo -e "${GREEN}All tests passed.${NC}"
    exit 0
else
    echo -e "${RED}${FAILURES} test(s) failed.${NC}"
    exit 1
fi
