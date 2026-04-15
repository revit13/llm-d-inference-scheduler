# Multimedia Downloader Proxy

An advanced, pluggable caching proxy built to accelerate the retrieval and delivery of high-bandwidth assets, such as videos, images, and machine learning models. 

## Supported Implementations

The proxy is designed to support different caching backends, which are maintained in the `implementations/` directory. Each backend manages its own specific configuration and resource footprints.

* **[Squid](https://github.com/squid-cache/squid) (Default):** A robust, high-performance HTTP/HTTPS caching proxy with two variants:
  * **[basic](implementations/squid/http/)** — HTTP caching proxy (port 8080).
  * **[https-ssl-bump](implementations/squid/https-ssl-bump/)** — HTTPS MITM caching proxy (port 3128). Requires a custom CA certificate.

  For setup instructions see the [Squid Implementation Guide](implementations/squid/README.md).

## Quick Start

### 1. Deploy the Proxy
You can deploy the default implementation to your Kubernetes cluster using Kustomize:

```bash
kubectl apply -k deploy/components/multimedia-downloader
```

### 2. Configure Your Application

Set the proxy environment variables to route downloads through the cache:

```bash
export HTTP_PROXY=http://multimedia-downloader:80
export HTTPS_PROXY=http://multimedia-downloader:80
export NO_PROXY=localhost,127.0.0.1,.svc,.cluster.local
```

- `HTTP_PROXY` — Routes unencrypted web traffic
- `HTTPS_PROXY` — Routes secure, encrypted web traffic
- `NO_PROXY` — Bypasses the proxy for specific internal hosts or domains

For Python applications:
```python
import os
os.environ['HTTP_PROXY'] = 'http://multimedia-downloader:80'
os.environ['HTTPS_PROXY'] = 'http://multimedia-downloader:80'
os.environ['NO_PROXY'] = 'localhost,127.0.0.1,.svc,.cluster.local'
```

## Configuration

### Base Configuration

The base directory contains:
- `service.yaml` - Base service definition (port 80, `targetPort: http-proxy`)
- `kustomization.yaml` - References the service and selected implementation

### Implementation-Specific Configuration

Each implementation lives under `implementations/<name>/` and may contain one or more variant subdirectories (e.g., `basic/`, `https-ssl-bump/`). Each variant has its own:
- `deployment.yaml` - Kubernetes deployment; must expose a container port named `http-proxy`
- `kustomization.yaml` - Kustomize configuration
- Configuration files (e.g., `squid-config.yaml`)

The base service uses the named port `http-proxy` as its `targetPort`. Variants resolve this automatically by naming their container port `http-proxy` — no service patch is required.

## Adding New Implementations

To add a new cache implementation:

1. Create a variant directory under `implementations/` (e.g., `implementations/nginx/basic/`)

2. Add variant-specific files:
   - `deployment.yaml` - Your proxy deployment; name the container port `http-proxy` (the base service resolves `targetPort: http-proxy` automatically)
   - `kustomization.yaml` - List resources and labels
   - Configuration files (e.g., `nginx-config.yaml`)

3. Update the base `kustomization.yaml`:
   - Change the implementation reference: `- implementations/nginx/basic`
