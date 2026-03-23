# Multimedia Downloader Implementations

This directory contains different cache implementation options for the multimedia downloader service. Each implementation provides the same API interface but uses different caching technologies.

## Available Implementations

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

### [Apache Traffic Server](https://trafficserver.apache.org/)
- **Directory**: `trafficserver/`
- **Image**: `apache/trafficserver:10.0.6`
- **Official Website**: https://trafficserver.apache.org/
- **Documentation**: https://docs.trafficserver.apache.org/en/latest/
- **GitHub**: https://github.com/apache/trafficserver
- **Best for**: High-performance CDN workloads, large-scale deployments, HTTP/2 support
- **Features**:
  - Scalable to 10,000+ requests per second
  - Full HTTP/1.1 and HTTP/2 support
  - Advanced range request handling for video streaming
  - Read-while-writer for efficient large file streaming
  - 512MB RAM cache + 10GB disk cache
  - Sophisticated cache control and invalidation
  - Battle-tested at CDN scale (terabits/second)
  - Extensible plugin system
  - Configurable TTL per media type (7 days for video/audio/images, 1 day default)

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
   - `app: multimedia-downloader`
   - `cache-implementation: <name>`

## Switching Between Implementations

To switch from NGINX to Apache Traffic Server:

1. Edit `deploy/components/multimedia-downloader/kustomization.yaml`:
   ```yaml
   resources:
   # Cache implementation
   - implementations/trafficserver  # Change from nginx to trafficserver
   - service.yaml
   ```

2. Apply the changes:
   ```bash
   kubectl apply -k deploy/components/multimedia-downloader/
   ```

## Implementation Comparison

| Feature | NGINX | Apache Traffic Server |
|---------|-------|----------------------|
| **Performance** | Excellent | Excellent (10K+ req/s) |
| **HTTP/2 Support** | Yes | Yes (full compliance) |
| **Range Requests** | Yes (sliced) | Yes (optimized) |
| **RAM Cache** | No | Yes (512MB) |
| **Disk Cache** | Yes (10GB) | Yes (10GB) |
| **Resource Usage** | Low (256Mi-1Gi) | Medium (512Mi-2Gi) |
| **Configuration** | Simple | Advanced |
| **Maturity** | Very mature | Mature (CDN-proven) |
| **Best Use Case** | General purpose | High-scale CDN |

## Example Alternative Implementations

You could add implementations for:
- **Varnish**: High-performance HTTP accelerator with VCL
- **Squid**: Full-featured web proxy cache
- **Redis**: In-memory data structure store with caching capabilities

## Testing Your Implementation

After adding a new implementation:

```bash
# Deploy the service
kubectl apply -k deploy/components/multimedia-downloader/

# Verify deployment
kubectl get pods -l app=multimedia-downloader
kubectl get svc multimedia-downloader

# Port forward for testing
kubectl port-forward svc/multimedia-downloader 8080:80

# Test fetch (should be MISS first time)
curl -I "http://localhost:8080/fetch?url=https://httpbin.org/image/jpeg"

# Test again (should be HIT second time)
curl -I "http://localhost:8080/fetch?url=https://httpbin.org/image/jpeg"

# Check health
curl http://localhost:8080/health
```

