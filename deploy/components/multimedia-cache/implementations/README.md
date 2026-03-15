# Multimedia Cache Implementations

This directory contains different cache implementation options for the multimedia cache service. Each implementation provides the same API interface but uses different caching technologies.

## Current Implementation

### [NGINX](https://nginx.org/) (Default)
- **Directory**: `nginx/`
- **Image**: `nginx:1.25-alpine`
- **Official Website**: https://nginx.org/
- **Documentation**: https://nginx.org/en/docs/
- **GitHub**: https://github.com/nginx/nginx
- **Best for**: General-purpose caching, video streaming, production use
- **Features**:
  - HTTP range request support for video seeking
  - Sliced caching (1MB chunks) for large files
  - Mature and battle-tested
  - Low resource usage
  - Extensive documentation

## Switching to a Different Cache Implementation

The structure is designed to make it easy to switch between different cache implementations. To add a new implementation:

1. Create a new directory: `implementations/<name>/`
2. Add the following files:
   - `deployment.yaml`: Kubernetes Deployment with your cache container
   - `<name>-config.yaml`: ConfigMap with cache configuration
   - `kustomization.yaml`: Kustomize configuration
3. Update the main `kustomization.yaml` to reference your implementation:
   ```yaml
   resources:
   - implementations/<name>
   - service.yaml
   ```

## API Compatibility

All implementations must expose the same HTTP API:

- **GET /fetch?url=<encoded_url>**: Fetch and cache media from the specified URL
- **GET /health**: Health check endpoint
- **Header X-Cache-Status**: Returns cache status (HIT, MISS, EXPIRED, etc.)

The Go client library (`pkg/multimedia/cache_client.go`) works with any implementation without modification.

## Requirements for All Implementations

Each implementation must:

1. **Listen on port 80** (HTTP)
2. **Implement endpoints**:
   - `GET /fetch?url=<encoded_url>` - Fetch and cache media
   - `GET /health` - Return 200 OK for health checks
3. **Return headers**:
   - `X-Cache-Status` - Cache status (HIT, MISS, EXPIRED, STALE, etc.)
   - `Content-Type` - Original media content type
   - `Accept-Ranges: bytes` - For video streaming support
4. **Support HTTP range requests** for video seeking
5. **Use the same labels**:
   - `app: multimedia-cache`
   - `cache-implementation: <name>`

## Example Alternative Implementations

You could add implementations for:
- **Varnish**: High-performance HTTP accelerator with VCL
- **Squid**: Full-featured web proxy cache
- **Apache Traffic Server**: Scalable HTTP/HTTPS cache
- **Redis**: In-memory data structure store with caching capabilities

## Testing Your Implementation

After adding a new implementation:

```bash
# Deploy the service
kubectl apply -k deploy/components/multimedia-cache/

# Verify deployment
kubectl get pods -l app=multimedia-cache
kubectl get svc multimedia-cache

# Port forward for testing
kubectl port-forward svc/multimedia-cache 8080:80

# Test fetch (should be MISS first time)
curl -I "http://localhost:8080/fetch?url=https://httpbin.org/image/jpeg"

# Test again (should be HIT second time)
curl -I "http://localhost:8080/fetch?url=https://httpbin.org/image/jpeg"

# Check health
curl http://localhost:8080/health
```

