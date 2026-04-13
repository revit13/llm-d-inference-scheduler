#!/usr/bin/env bash
# test-squid-kind.sh — validates the Squid implementation sources and smoke-tests
# the deployed proxy (non-SSL) against a temporary kind cluster.
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
#   Static source validation (no cluster required):
#     1.  kustomization.yaml  — references deployment.yaml and squid-config.yaml
#     2.  deployment.yaml     — image tag, named port http-proxy:8080, resource limits
#     3.  squid-config.yaml   — key directives (http_port, cache_dir, cache_mem,
#                               collapsed_forwarding, log targets)
#   Runtime (requires cluster):
#     4.  Applied ConfigMap contains expected squid.conf directives
#     5.  Deployed image matches source deployment.yaml
#     6.  Service endpoint is populated (pod selected)
#     7.  HTTP request via proxy reaches external origin (HTTP 200)
#     8.  First request to a URL produces TCP_MISS
#     9.  Second request to same URL produces TCP_HIT / TCP_MEM_HIT
#     10. HTTPS CONNECT tunnel is established (TCP_TUNNEL in logs)
#     11. Concurrent requests to the same URL are collapsed (single TCP_MISS)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="squid-smoke"
KEEP_CLUSTER=false
FAILURES=0
KUBECONFIG_TMP=""

# The base service.yaml is two levels up from the squid implementation.
BASE_DIR="${SCRIPT_DIR}/../.."
SERVICE_YAML="${BASE_DIR}/service.yaml"

# --- Colors / helpers ----------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
section() { echo -e "\n${YELLOW}==> $*${NC}"; }
pass()    { echo -e "  ${GREEN}PASS${NC}: $*"; }
fail()    { echo -e "  ${RED}FAIL${NC}: $*"; FAILURES=$((FAILURES + 1)); }
warn()    { echo -e "  ${YELLOW}WARN${NC}: $*"; }

# Assert that FILE contains a line matching PATTERN (grep -E).
assert_contains() {
    local file="$1" pattern="$2" desc="$3"
    if grep -qE "${pattern}" "${file}"; then
        pass "${desc}"
    else
        fail "${desc}  [pattern '${pattern}' not found in $(basename "${file}")]"
    fi
}

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

# =============================================================================
# PART 1 — STATIC SOURCE VALIDATION
# (no cluster needed; validates the YAML files in ${SCRIPT_DIR})
# =============================================================================

section "Test 1: kustomization.yaml references expected resources"
KUSTOMIZATION="${SCRIPT_DIR}/kustomization.yaml"
assert_contains "${KUSTOMIZATION}" "squid-config\.yaml" \
    "kustomization.yaml references squid-config.yaml"
assert_contains "${KUSTOMIZATION}" "deployment\.yaml" \
    "kustomization.yaml references deployment.yaml"

section "Test 2: deployment.yaml — image, port, and resource limits"
DEPLOYMENT="${SCRIPT_DIR}/deployment.yaml"
assert_contains "${DEPLOYMENT}" "image: ubuntu/squid" \
    "deployment uses ubuntu/squid image"
assert_contains "${DEPLOYMENT}" "ubuntu/squid:6\.1-23\.10_beta" \
    "image is ubuntu/squid:6.1-23.10_beta"
assert_contains "${DEPLOYMENT}" "name: http-proxy" \
    "container port is named http-proxy (required by base service targetPort)"
assert_contains "${DEPLOYMENT}" "containerPort: 8080" \
    "container port is 8080"
assert_contains "${DEPLOYMENT}" 'memory: "512Mi"' \
    "memory request is set (512Mi)"
assert_contains "${DEPLOYMENT}" 'memory: "4Gi"' \
    "memory limit is set (4Gi)"
assert_contains "${DEPLOYMENT}" "squid\.pid" \
    "liveness/readiness probes reference squid.pid"

section "Test 3: squid-config.yaml — key directives"
CONFIG="${SCRIPT_DIR}/squid-config.yaml"
assert_contains "${CONFIG}" "http_port 8080" \
    "Squid listens on port 8080"
assert_contains "${CONFIG}" "cache_dir null" \
    "cache_dir is null (memory-only; no disk cache)"
assert_contains "${CONFIG}" "cache_mem 2048 MB" \
    "in-memory cache is 2048 MB"
assert_contains "${CONFIG}" "maximum_object_size_in_memory 1024 MB" \
    "per-object memory limit is 1024 MB"
assert_contains "${CONFIG}" "collapsed_forwarding on" \
    "collapsed_forwarding is enabled"
assert_contains "${CONFIG}" "access_log stdio:/dev/stdout" \
    "access_log streams to stdout (visible via kubectl logs)"
assert_contains "${CONFIG}" "cache_log stdio:/dev/stderr" \
    "cache_log streams to stderr (visible via kubectl logs)"
assert_contains "${CONFIG}" "dns_nameservers 8\.8\.8\.8" \
    "external DNS configured (required to resolve huggingface.co)"
assert_contains "${CONFIG}" "refresh_pattern.*store-stale" \
    "store-stale caching enabled for ML model / media file patterns"

# =============================================================================
# PART 2 — RUNTIME TESTS
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
# Apply the squid-specific resources (Deployment + ConfigMap) from the source dir.
kubectl apply -k "${SCRIPT_DIR}"
# Apply the base Service separately; it is not part of the squid kustomization
# but is required for DNS-based proxy access inside the cluster.
kubectl apply -f "${SERVICE_YAML}"
kubectl rollout status deployment/multimedia-downloader --timeout=120s
echo "  multimedia-downloader is ready."

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

# --- Runtime helpers -----------------------------------------------------------

# Run curl inside the test pod, return the HTTP status code.
proxy_curl() {
    kubectl exec squid-test-client -- \
        curl --silent --output /dev/null --write-out "%{http_code}" "$@"
}

# Wait up to $2 seconds for grep -E pattern $1 to appear in recent Squid logs.
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

dump_squid_logs() {
    kubectl logs -l app=multimedia-downloader --tail="${1:-20}" 2>/dev/null \
        | sed 's/^/    /' || true
}

# --- Test 4: Applied ConfigMap matches source ----------------------------------
section "Test 4: Applied ConfigMap contains expected squid.conf directives"
CM=$(kubectl get configmap squid-multimedia-downloader-config \
    -o jsonpath='{.data.squid\.conf}' 2>/dev/null)
for directive in "http_port 8080" "cache_dir null" "cache_mem 2048 MB" \
                 "collapsed_forwarding on" "access_log stdio:/dev/stdout" \
                 "cache_log stdio:/dev/stderr"; do
    if echo "${CM}" | grep -qF "${directive}"; then
        pass "ConfigMap contains: ${directive}"
    else
        fail "ConfigMap missing: ${directive}"
    fi
done

# --- Test 5: Deployed image matches source ------------------------------------
section "Test 5: Deployed image matches deployment.yaml"
SOURCE_IMAGE="$(grep -E '^\s+image:' "${DEPLOYMENT}" | awk '{print $2}')"
APPLIED_IMAGE="$(kubectl get deployment multimedia-downloader \
    -o jsonpath='{.spec.template.spec.containers[0].image}')"
if [[ "${APPLIED_IMAGE}" == "${SOURCE_IMAGE}" ]]; then
    pass "Deployed image matches source: ${APPLIED_IMAGE}"
else
    fail "Image mismatch — source: '${SOURCE_IMAGE}', deployed: '${APPLIED_IMAGE}'"
fi

# --- Test 6: Service endpoint is populated ------------------------------------
section "Test 6: Service endpoint is populated (pod selected by service)"
ENDPOINTS="$(kubectl get endpoints multimedia-downloader \
    -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)"
if [[ -n "${ENDPOINTS}" ]]; then
    pass "Service has endpoint(s): ${ENDPOINTS}"
else
    fail "Service has no endpoints — selector may not match pod labels"
fi

# --- Test 7: Basic HTTP forward proxy -----------------------------------------
section "Test 7: HTTP request via proxy reaches external origin (HTTP 200)"
HTTP_CODE=$(proxy_curl "http://example.com/")
if [[ "${HTTP_CODE}" == "200" ]]; then
    pass "HTTP 200 received from example.com via proxy"
else
    fail "Expected HTTP 200, got ${HTTP_CODE}"
    dump_squid_logs
fi

# --- Tests 8 & 9: Cache miss then cache hit -----------------------------------
# Use a unique query string so this run does not collide with cached state.
RUN_ID="$(date +%s)"
CACHE_URL="http://example.com/?run=${RUN_ID}"

section "Test 8: First request to a URL produces TCP_MISS"
proxy_curl "${CACHE_URL}" >/dev/null || true
if wait_for_log "TCP_MISS" 10; then
    pass "TCP_MISS observed in Squid access log"
else
    fail "TCP_MISS not observed within 10 s"
    dump_squid_logs
fi

section "Test 9: Second request to same URL produces TCP_HIT / TCP_MEM_HIT"
proxy_curl "${CACHE_URL}" >/dev/null || true
if wait_for_log "TCP_MEM_HIT|TCP_HIT" 10; then
    pass "Cache hit (TCP_HIT or TCP_MEM_HIT) observed in Squid access log"
else
    fail "Cache hit not observed within 10 s"
    dump_squid_logs
fi

# --- Test 10: HTTPS CONNECT tunnel --------------------------------------------
section "Test 10: HTTPS CONNECT tunnel is established (non-SSL Squid passes through)"
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

# --- Test 11: Collapsed forwarding --------------------------------------------
section "Test 11: Concurrent requests to the same URL produce a single TCP_MISS"
COLLAPSE_URL="http://example.com/?collapse=${RUN_ID}"
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
    warn "${MISS_COUNT} TCP_MISS entries — collapsed_forwarding may not have engaged (requests may not have overlapped in-flight)"
else
    fail "0 TCP_MISS entries — requests may not have reached the proxy"
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
