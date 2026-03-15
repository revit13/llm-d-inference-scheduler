# Multimedia Downloader Service

The multimedia downloader service provides an optional caching proxy for multimedia content (images, videos, audio, etc.). It helps reduce bandwidth usage and improve response times by caching frequently accessed media files.

**Optimized for video streaming** with support for HTTP range requests, sliced caching for large files, and extended timeouts.

## Architecture

The service consists of:
- **Cache proxy**: Pluggable cache implementation (NGINX by default, Varnish available)
- **Go client library**: Provides easy integration with Go applications
- **Kubernetes deployment**: Scalable deployment with health checks and resource limits

```
┌─────────────┐     ┌──────────────────┐     ┌─────────────────────┐
│   Client    │────▶│  NGINX Cache     │────▶│  External Media     │
│ (Go Service)│     │  Proxy Service   │     │  Server             │
└─────────────┘     └──────────────────┘     └─────────────────────┘
                            │
                            ▼
                    ┌──────────────┐
                    │ Cache Storage│
                    │   (10GB)     │
                    └──────────────┘
```

## Features

- ✅ **Optional**: Can be enabled/disabled via configuration
- ✅ **Caching**: 24-hour cache time, 10GB max size
- ✅ **Video Streaming**: HTTP range requests support for seeking/skipping
- ✅ **Sliced Caching**: Efficient caching of large video files (1MB slices)
- ✅ **Revalidation**: Checks if content changed on origin server
- ✅ **Cache Status**: Returns X-Cache-Status header (HIT/MISS/EXPIRED/etc.)
- ✅ **Health Checks**: Built-in `/health` endpoint
- ✅ **Scalable**: Supports multiple replicas
- ✅ **Resource Limits**: Optimized for video handling (1GB memory, 1 CPU)
- ✅ **Fallback**: Direct fetch when caching is disabled
- ✅ **Large File Support**: Extended timeouts (5 minutes) and buffers

## Cache Implementations

The multimedia cache service is designed with a pluggable architecture that allows you to easily switch between different cache implementations. Currently, [NGINX](https://nginx.org/) is the default and only included implementation, but the structure supports adding alternative implementations in the future.

### Current Implementation

- **[NGINX](https://nginx.org/)** (default): General-purpose caching, excellent for video streaming, production-ready
  - Official website: https://nginx.org/
  - Documentation: https://nginx.org/en/docs/
  - GitHub: https://github.com/nginx/nginx

### Adding Alternative Implementations

The service is structured to support multiple cache implementations. To add a new implementation (e.g., Varnish, Squid, Apache Traffic Server):

1. Create a new directory: `deploy/components/multimedia-downloader/implementations/<name>/`
2. Add deployment and configuration files
3. Update `deploy/components/multimedia-downloader/kustomization.yaml` to reference your implementation
4. Redeploy: `kubectl apply -k deploy/components/multimedia-downloader/`

See `deploy/components/multimedia-downloader/implementations/README.md` for detailed requirements and instructions.

**Important**: The Go client library and API remain the same regardless of which cache implementation you choose. All implementations must expose the same HTTP API (`/fetch?url=`, `/health`, `X-Cache-Status` header).

## Configuration

### NGINX Cache Settings (Default Implementation)

The default NGINX configuration uses:

```nginx
proxy_cache_path /var/cache/nginx 
                 levels=1:2 
                 keys_zone=mm_cache:10m 
                 max_size=10g 
                 inactive=24h 
                 use_temp_path=off;
```

- **levels=1:2**: Two-level directory hierarchy for cache files
- **keys_zone=mm_cache:10m**: 10MB shared memory zone for cache keys
- **max_size=10g**: Maximum cache size of 10GB
- **inactive=24h**: Remove cached items not accessed for 24 hours
- **use_temp_path=off**: Write directly to cache directory

### Video-Specific Optimizations

- **Sliced Caching**: Files are cached in 1MB slices for efficient handling of large videos
- **Range Request Support**: Enables video seeking/skipping without re-downloading
- **Extended Timeouts**: 5-minute read timeout for large file transfers
- **Larger Buffers**: 32 x 8KB buffers (256KB total) for smooth streaming
- **HTTP/1.1**: Persistent connections for better performance

### Cache Behavior

- **200/206/304 responses**: Cached for 24 hours (optimized for videos)
- **404 responses**: Cached for 1 minute
- **Revalidation**: Enabled to check for content updates
- **Stale content**: Served during upstream errors
- **Cache lock**: Prevents cache stampede (10s timeout)

## Deployment

### Prerequisites

- Kubernetes cluster
- kubectl configured
- kustomize (optional, but recommended)

### Deploy the Service

```bash
# Deploy using kustomize
kubectl apply -k deploy/components/multimedia-downloader/

# Or deploy individual files
kubectl apply -f deploy/components/multimedia-downloader/nginx-config.yaml
kubectl apply -f deploy/components/multimedia-downloader/deployment.yaml
kubectl apply -f deploy/components/multimedia-downloader/service.yaml
```

### Verify Deployment

```bash
# Check pods
kubectl get pods -l app=multimedia-downloader

# Check service
kubectl get svc multimedia-downloader

# Check logs
kubectl logs -l app=multimedia-downloader
```

## Usage

### Go Client Library

```go
import "github.com/llm-d/llm-d-inference-scheduler/pkg/multimedia"

// Initialize the cache client
client := multimedia.NewCacheClient(multimedia.Config{
    ServiceURL: "http://multimedia-downloader.default.svc.cluster.local",
    Enabled:    true, // Set to false to disable caching
})

// Fetch media
ctx := context.Background()
body, resp, err := client.FetchMedia(ctx, "https://example.com/image.jpg")
if err != nil {
    log.Fatal(err)
}
defer body.Close()

// Check cache status
cacheStatus := multimedia.GetCacheStatus(resp)
fmt.Printf("Cache status: %s\n", cacheStatus)
// Output: Cache status: HIT (or MISS, EXPIRED, etc.)

// Use the media content
data, err := io.ReadAll(body)
```

### Direct HTTP API

```bash
# Fetch media through cache
curl "http://multimedia-downloader/fetch?url=https://example.com/image.jpg"

# Check cache status
curl -I "http://multimedia-downloader/fetch?url=https://example.com/image.jpg"
# Look for: X-Cache-Status: HIT

# Health check
curl http://multimedia-downloader/health
```

### Cache Status Values

- **HIT**: Content served from cache
- **MISS**: Content not in cache, fetched from origin
- **EXPIRED**: Cached content expired, revalidated
- **STALE**: Serving stale content (origin unavailable)
- **UPDATING**: Cache is being updated
- **REVALIDATED**: Content revalidated and still valid

## Video Handling

### Video Response Behavior

When you request a video through the cache service:

```bash
curl "http://multimedia-downloader/fetch?url=https://example.com/video.mp4"
```

The NGINX proxy will return:

1. **HTTP Status Code**: 
   - `200 OK` for full content
   - `206 Partial Content` for range requests (video seeking)
2. **Content-Type Header**: The original video MIME type from the source server
   - `video/mp4` for MP4 files
   - `video/webm` for WebM files
   - `video/quicktime` for MOV files
   - `video/x-matroska` for MKV files
3. **Content-Length Header**: Size of the video file (or range)
4. **X-Cache-Status Header**: Cache status (`HIT`, `MISS`, `EXPIRED`, etc.)
5. **Accept-Ranges Header**: `bytes` (enables seeking)
6. **Content-Range Header**: Byte range for partial content (206 responses)
7. **Body**: The raw video file bytes (binary stream)

### Example Response Headers

Full video response:
```http
HTTP/1.1 200 OK
Server: nginx/1.25.0
Date: Sat, 14 Mar 2026 17:15:00 GMT
Content-Type: video/mp4
Content-Length: 52428800
X-Cache-Status: HIT
Accept-Ranges: bytes
```

Range request response (video seeking):
```http
HTTP/1.1 206 Partial Content
Server: nginx/1.25.0
Date: Sat, 14 Mar 2026 17:15:00 GMT
Content-Type: video/mp4
Content-Length: 1048576
Content-Range: bytes 10485760-11534335/52428800
X-Cache-Status: HIT
Accept-Ranges: bytes
```

### Key Points for Videos

1. **Streaming Support**: Full HTTP range request support enables:
   - Video seeking/skipping without re-downloading
   - Bandwidth-efficient playback (only requested ranges are transferred)
   - Sliced caching (1MB chunks) for efficient storage
2. **Large Files**: Videos are optimized with:
   - Extended timeouts (5 minutes for read operations)
   - Larger buffers (256KB total) for smooth streaming
   - 24-hour cache time (vs 1 hour for images)
   - Sliced caching reduces memory pressure
3. **Binary Data**: The response body is the raw binary video data, identical to fetching directly from the source
4. **Cache Efficiency**: Each 1MB slice is cached independently, so:
   - Partial downloads still benefit from caching
   - Seeking to different parts of a video uses cached slices
   - Memory usage is optimized for large files

### Go Client Usage for Videos

```go
// Fetch video
body, resp, err := client.FetchMedia(ctx, "https://example.com/video.mp4")
if err != nil {
    log.Fatal(err)
}
defer body.Close()

// Check content type
contentType := resp.Header.Get("Content-Type")
fmt.Printf("Content-Type: %s\n", contentType) // video/mp4

// Check if range requests are supported
acceptRanges := resp.Header.Get("Accept-Ranges")
fmt.Printf("Accept-Ranges: %s\n", acceptRanges) // bytes

// Check cache status
cacheStatus := multimedia.GetCacheStatus(resp)
fmt.Printf("Cache status: %s\n", cacheStatus) // HIT or MISS

// Save to file or stream
file, _ := os.Create("output.mp4")
io.Copy(file, body)
```

- **BYPASS**: Cache bypassed

## Integration with Sidecar

To integrate with the pd-sidecar, add these flags:

```go
enableMultimediaCache := pflag.Bool("enable-multimedia-downloader", false,
    "enable multimedia downloader service")
multimediaCacheURL := pflag.String("multimedia-downloader-url",
    "http://multimedia-downloader.default.svc.cluster.local",
    "URL of the multimedia downloader service")
```

Then initialize the client:

```go
var mmClient *multimedia.CacheClient
if *enableMultimediaCache {
    mmClient = multimedia.NewCacheClient(multimedia.Config{
        ServiceURL: *multimediaCacheURL,
        Enabled:    true,
    })
}
```

## Testing

### Port Forward for Local Testing

```bash
# Forward service port to localhost
kubectl port-forward svc/multimedia-downloader 8080:80

# Test fetch
curl "http://localhost:8080/fetch?url=https://httpbin.org/image/jpeg" -o test.jpg

# Check cache status (should be MISS first time)
curl -I "http://localhost:8080/fetch?url=https://httpbin.org/image/jpeg"

# Fetch again (should be HIT second time)
curl -I "http://localhost:8080/fetch?url=https://httpbin.org/image/jpeg"
```

### Load Testing

```bash
# Install hey (HTTP load testing tool)
go install github.com/rakyll/hey@latest

# Run load test
hey -n 1000 -c 10 "http://localhost:8080/fetch?url=https://httpbin.org/image/jpeg"
```

## Monitoring

### Metrics

NGINX access logs include cache status:

```
10.0.0.1 - - [14/Mar/2026:17:00:00 +0000] "GET /fetch?url=... HTTP/1.1" 200 12345 "-" "Go-http-client/1.1" "-" cache:HIT
```

### Health Check

```bash
# Check service health
kubectl exec -it deployment/multimedia-downloader -- curl localhost/health
```

## Troubleshooting

### Cache Not Working

1. Check NGINX logs:
   ```bash
   kubectl logs -l app=multimedia-downloader
   ```

2. Verify DNS resolution:
   ```bash
   kubectl exec -it deployment/multimedia-downloader -- nslookup example.com
   ```

3. Check cache directory:
   ```bash
   kubectl exec -it deployment/multimedia-downloader -- ls -lh /var/cache/nginx
   ```

### High Memory Usage

- Reduce `max_size` in nginx-config.yaml
- Decrease `inactive` time to expire content sooner
- Scale down replicas if not needed

### Slow Response Times

- Check upstream server performance
- Verify network connectivity
- Increase timeout values if needed
- Add more replicas for load distribution

## Configuration Options

### Scaling

Adjust replicas in deployment.yaml:

```yaml
spec:
  replicas: 2  # Increase for higher load
```

### Cache Size

Modify in nginx-config.yaml:

```nginx
proxy_cache_path /var/cache/nginx 
                 max_size=20g  # Increase cache size
                 inactive=48h  # Keep content longer
```

### Resource Limits

Adjust in deployment.yaml:

```yaml
resources:
  requests:
    memory: "256Mi"  # Increase for larger cache
    cpu: "200m"
  limits:
    memory: "1Gi"
    cpu: "1000m"
```

## Security Considerations

- The service only allows GET requests
- DNS resolver uses public DNS (8.8.8.8, 1.1.1.1)
- No authentication required (internal service)
- Cache purge endpoint restricted to internal IPs
- Consider adding network policies for additional security

## Performance Tips

1. **Use appropriate cache times**: Balance freshness vs. cache hit rate
2. **Monitor cache hit ratio**: Aim for >80% hit rate
3. **Scale horizontally**: Add replicas for high traffic
4. **Use persistent volumes**: For cache persistence across pod restarts
5. **Tune buffer sizes**: Adjust based on typical media file sizes

## Adding Custom Cache Implementations

You can add your own cache implementation (e.g., Squid, Apache Traffic Server, Redis) by following these steps:

1. Create a new directory: `deploy/components/multimedia-downloader/implementations/<name>/`
2. Add required files:
   - `deployment.yaml` - Kubernetes Deployment with your cache container
   - `<name>-config.yaml` - ConfigMap with cache configuration
   - `kustomization.yaml` - Kustomize configuration
3. Ensure your implementation:
   - Listens on port 80
   - Implements `GET /fetch?url=<encoded_url>` endpoint
   - Implements `GET /health` endpoint
   - Returns `X-Cache-Status` header (HIT, MISS, etc.)
   - Supports HTTP range requests for video streaming
4. Update `deploy/components/multimedia-downloader/kustomization.yaml` to reference your implementation
5. Test with the Go client library (no code changes needed)

See `deploy/components/multimedia-downloader/implementations/README.md` for detailed requirements.

## Future Enhancements

- [ ] Persistent volume support for cache
- [ ] Prometheus metrics export
- [ ] Authentication/authorization
- [ ] Cache warming strategies
- [ ] CDN integration
- [ ] Advanced cache key customization
- [ ] Additional cache implementations (Squid, Apache Traffic Server, etc.)