# Squid Proxy Implementation

This implementation utilizes a Squid proxy to cache multimedia content like images, optimizing for efficient data retrieval rather than manipulation or resizing.

> **Note:** You must tailor the provided baseline configuration to your specific environment. This includes modifying cache sizes, Access Control Lists (ACLs), and SSL parameters. Please review the Squid Configuration Reference for all available settings.

## Deployment

You can deploy the proxy using Kustomize from the implementation directory:
```bash
kubectl apply -k deploy/components/multimedia-downloader/implementations/squid
```

Or from the base directory:

```bash
kubectl apply -k deploy/components/multimedia-downloader
```

## Monitoring

Check Squid logs for cache hits/misses:

```bash
# View access logs
kubectl logs -l app=multimedia-downloader
```

Key log statuses to look for:

- `TCP_HIT`: The content was successfully served directly from the proxy cache.

- `TCP_MISS`: The content was not in the cache and had to be fetched from the origin server.

- `TCP_MEM_HIT`: The content was served extremely quickly from the memory cache.

## SSL Bump Implementation Guide

[SSL Bump](https://wiki.squid-cache.org/Features/SslBump) empowers Squid to act as a man-in-the-middle (MITM) proxy, allowing it to intercept and cache encrypted HTTPS traffic. Because this process inherently breaks end-to-end encryption trust, it introduces significant privacy and legal risks. It is highly recommended to utilize smart inspection techniques like [Peek & Splice](https://wiki.squid-cache.org/Features/SslPeekAndSplice) where appropriate.

> **Warning:**  SSL Bump breaks end-to-end trust. Always ensure you have legal and compliance approval before intercepting HTTPS traffic.


## Overview

**What is SSL Bump?**

SSL Bump enables Squid to:
- Decrypt HTTPS connections
- Cache encrypted content 
- Re-encrypt traffic to the client
- Inspect and filter HTTPS traffic

**Architecture:**
```
Client Pod → HTTPS Request → Squid (SSL Bump) → Decrypt → Cache → Re-encrypt → Origin Server
                                      ↓
                              Generate dynamic cert
                              signed by Squid CA
```

## Step-by-Step Configuration

### Prerequisites

- OpenSSL installed on your system for generating certificates.
- kubectl configured with access to your Kubernetes cluster.
- A clear understanding of the MITM nature of SSL Bump and the required compliance approvals.
- **Squid image with SSL Bump support.** The default `ubuntu/squid` hub image includes SSL Bump. Alternatively, build the provided [`ssl-bump/Dockerfile.squid-ssl-bump`](ssl-bump/Dockerfile.squid-ssl-bump) for a self-contained image that pre-bakes the SSL DB and handles re-initialization automatically via its entrypoint (see Step 4).

### Steps 1 & 2: Generate Certificates and Create Kubernetes Secrets

Use the provided script to generate the CA certificate/key pair, verify them, and create the required Kubernetes secrets in one step:

```bash
./ssl-bump/generate-ssl-certs.sh [--namespace <ns>] [--out-dir <dir>] [--org <org>]
```

| Flag | Default | Description |
|------|---------|-------------|
| `--namespace` | `default` | Kubernetes namespace for the secrets |
| `--out-dir` | `squid-ssl-certs` | Directory where PEM files are written |
| `--org` | `YourOrganization` | Organization name embedded in the CA certificate |

The script:
1. Generates a 4096-bit CA private key and a 10-year CA certificate
2. Verifies the certificate/key pair match
3. Creates secret `squid-ssl-certs` (cert + key) for the Squid pod
4. Creates secret `squid-ca-public-cert` (cert only) for client pods

⚠️ **CRITICAL**: Keep `squid-ca-key.pem` secure! Anyone with this key can impersonate any website.

### Step 3: Update Squid Configuration

Apply the SSL Bump delta from [`ssl-bump/squid.conf`](ssl-bump/squid.conf) to `squid-config.yaml`'s `squid.conf` key:

1. Replace the plain `http_port 8080` line with the SSL Bump port block from the delta file.
2. Insert the `sslcrtd_program`, `sslcrtd_children`, and `ssl_bump` directives immediately after the port block.

### Step 4: Update Squid Deployment

**Option A — hub image (default):** Add an init container to initialize the SSL DB and mount the SSL volumes in `deployment.yaml`:

```yaml
spec:
  template:
    spec:
      initContainers:
      # Initialize SSL certificate database
      - name: init-ssl-db
        image: ubuntu/squid:6.1-23.10_beta
        command:
        - /bin/sh
        - -c
        - |
          mkdir -p /var/lib/squid/ssl_db
          /usr/lib/squid/security_file_certgen -c -s /var/lib/squid/ssl_db -M 16MB
          chown -R proxy:proxy /var/lib/squid/ssl_db
        volumeMounts:
        - name: ssl-db
          mountPath: /var/lib/squid/ssl_db
      
      containers:
      - name: squid
        volumeMounts:
        # Mount SSL certificates
        - name: squid-ssl-certs
          mountPath: /etc/squid/ssl_cert
          readOnly: true
        # Mount SSL database
        - name: ssl-db
          mountPath: /var/lib/squid/ssl_db
        # ... other mounts ...
      
      volumes:
      # SSL certificates secret
      - name: squid-ssl-certs
        secret:
          secretName: squid-ssl-certs
      # SSL database
      - name: ssl-db
        emptyDir: {}
      # ... other volumes ...
```

**Option B — custom image:** Build [`ssl-bump/Dockerfile.squid-ssl-bump`](ssl-bump/Dockerfile.squid-ssl-bump) and use the resulting image in `deployment.yaml`. The image pre-bakes the SSL DB and its entrypoint re-initializes it if an emptyDir volume clears it, so the `init-ssl-db` init container is not needed. The SSL cert and ssl-db volume mounts are still required.

### Step 5: Configure Client Pods

Apply [`ssl-bump/patch-client-deployment.yaml`](ssl-bump/patch-client-deployment.yaml) as a Kustomize strategic merge patch on each client Deployment. The patch injects:
- an `install-ca-cert` init container that installs the Squid CA into the system trust store
- `HTTP_PROXY` / `HTTPS_PROXY` / `SSL_CERT_DIR` / `REQUESTS_CA_BUNDLE` / `CURL_CA_BUNDLE` env vars on the `app` container
- the `squid-ca-cert` (secret) and `shared-certs` (emptyDir) volumes

In the client workload's `kustomization.yaml`:

```yaml
patches:
  - path: path/to/ssl-bump/patch-client-deployment.yaml
    target:
      kind: Deployment
      name: <your-client-deployment-name>
```

Set `metadata.name` in the patch file and the `containers[].name` field to match your actual deployment and container names.

### Step 6: Verification

#### Verify SSL Bump is Working

```bash
# Check Squid logs for SSL bump activity
kubectl logs -l app=multimedia-downloader | grep -i "ssl\|bump\|certificate"

# Test from client pod
kubectl exec -it <client-pod> -- curl -v https://images.dog.ceo/breeds/poodle-standard/n02113799_2280.jpg

# Should show:
# * issuer: CN=Squid Proxy CA  <-- Confirms SSL bump is working
```