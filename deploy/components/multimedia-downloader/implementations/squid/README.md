# Squid Proxy: Multimedia Cache

This Squid proxy implementation caches multimedia content (like images and videos) to optimize data retrieval speeds.

> **Note:** Remember to tailor cache sizes, ACLs, and SSL parameters to your specific environment before production use.

## 🚀 Quick Start: Deploy & Test

### 1. Deploy the Proxy

Deploy using Kustomize. The `SQUID_IMAGE` variable is substituted via `envsubst`:

```bash
export SQUID_IMAGE="${SQUID_IMAGE:-ubuntu/squid:6.1-23.10_beta}"
kubectl kustomize deploy/components/multimedia-downloader/implementations/squid/http | envsubst | kubectl apply -f -
kubectl apply -f deploy/components/multimedia-downloader/service.yaml
```

### 2. Run Automated Tests

Use the provided [bash script](basic/test-squid-kind.sh) to spin up a temporary Kind cluster, run cache tests, and verify logs:

```bash
# Run automated test (creates temporary cluster, tests, and cleans up)
./deploy/components/multimedia-downloader/implementations/squid/http/test-squid-kind.sh

# Keep the cluster for debugging and manual testing
./deploy/components/multimedia-downloader/implementations/squid/http/test-squid-kind.sh --keep-cluster
```

### Understanding Log Results

- TCP_HIT: Served fast from disk cache.

- TCP_MEM_HIT: Served ultra-fast from memory cache.

- TCP_MISS: Downloaded from the origin server (not in cache).

For more detailed explanations of log statuses and monitoring cache hit rates, see the [Squid monitoring guide](https://oneuptime.com/blog/post/2026-03-20-squid-monitor-cache-hit-rates-ipv4/view).

## 🔒 HTTPS Caching

By default, proxies cannot see inside encrypted HTTPS traffic. Here is how Squid manages encrypted flows depending on your configuration:

* **Blind Tunneling (CONNECT):** Passes encrypted TCP traffic through an opaque tunnel. 
    * *Trade-off:* Zero visibility; no caching or granular filtering is possible.
* **Full Decryption ([SSL Bump](https://wiki.squid-cache.org/Features/SslBump) MITM):** Intercepts, decrypts, and re-encrypts traffic using a custom Root CA. 
    * *Trade-off:* Enables full inspection and caching, but requires complex certificate management and raises privacy/legal risks.
* **Smart Inspection ([Peek & Splice](https://wiki.squid-cache.org/Features/SslPeekAndSplice)):** Inspects the unencrypted SNI (Server Name Indication) during the TLS handshake. 
    * *Trade-off:* Allows domain-based filtering without requiring full decryption.

**Modern Constraints: TLS 1.3 & ECH**
While Squid supports TLS 1.3, new privacy standards like ECH (Encrypted Client Hello) and ESNI encrypt the destination domain itself. Since the proxy cannot see the target to apply policy, these connections must be spliced (passed through blindly) to prevent connection failure.

> **Warning:**  SSL Bump breaks end-to-end tsrust. Always ensure you have legal and compliance approval before intercepting HTTPS traffic.


## Test SSL Bump

The SSL Bump variant requires a custom Squid image using the `squid-openssl` Ubuntu package, which includes OpenSSL support for HTTPS interception. Build it from [Dockerfile.squid-ssl-bump](https-ssl-bump/Dockerfile.squid-ssl-bump):

```bash
docker build -t squid-ssl-bump:local \
  -f deploy/components/multimedia-downloader/implementations/squid/https-ssl-bump/Dockerfile.squid-ssl-bump \
  deploy/components/multimedia-downloader/implementations/squid/https-ssl-bump/
```

The [test script](https-ssl-bump/test-squid-ssl-bump-kind.sh) builds and loads this image into the kind cluster automatically. It also generates a CA, deploys the proxy and a test client, and verifies the HTTPS cache end-to-end:

```bash
# Run automated test (creates temporary cluster, tests, and cleans up)
./deploy/components/multimedia-downloader/implementations/squid/https-ssl-bump/test-squid-ssl-bump-kind.sh

# Keep the cluster for manual inspection and debugging
./deploy/components/multimedia-downloader/implementations/squid/https-ssl-bump/test-squid-ssl-bump-kind.sh --keep-cluster
```
### Configuring Client Pods for Production

To route a real workload's HTTPS traffic through the proxy, patch your client deployment in Kustomize:

```yaml
patches:
  - path: path/to/https-ssl-bump/patch-client-deployment.yaml
    target:
      kind: Deployment
      name: <your-client-deployment-name>
```

This patch injects an init container to install the Squid CA into the system trust store, sets necessary proxy environment variables, and mounts the required certificates. Remember to update the target names in the patch file to match your deployment.