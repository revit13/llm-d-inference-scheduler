# Squid as a Multimedia Download Service

**Document Version:** 1.0  
**Date:** April 5, 2026  
**Author:** Technical Documentation  

## Executive Summary

Squid is a high-performance caching proxy server that excels as a multimedia download service for videos, images, and large files. This document describes Squid's architecture, configuration, and best practices for optimizing multimedia content delivery.

---

## Table of Contents

1. [Overview](#overview)
2. [Cache Management](#cache-management)
3. [Primary Storage Architecture](#primary-storage-architecture)
4. [Eviction Policies](#eviction-policies)
5. [Best File Types for Caching](#best-file-types-for-caching)
6. [ETag Handling](#etag-handling)
7. [Configuration](#configuration)
8. [Proxy Usage Modes](#proxy-usage-modes)
9. [HTTPS Decryption](#https-decryption)
10. [Best Use Cases](#best-use-cases)
11. [Memory Consumption Management](#memory-consumption-management)
12. [HTTPS Request Handling](#https-request-handling)
13. [Config-Map.yaml Explanation](#config-mapyaml-explanation)
14. [References](#references)

---

## 1. Overview

Squid is a versatile caching proxy server designed to reduce bandwidth usage and improve response times by caching frequently requested content. For multimedia download services, Squid provides:

- **Intelligent caching** of large files (videos, images, models)
- **Bandwidth optimization** through collapsed forwarding
- **Flexible storage** options (memory, disk, or hybrid)
- **Advanced eviction policies** for optimal cache utilization
- **Range request support** for partial content delivery
- **ETag-based validation** to minimize unnecessary downloads

**Primary Proxy Type:** Forward Proxy (can also operate as reverse proxy or transparent proxy)

---

## 2. Cache Management

### 2.1 Cache Hierarchy

Squid implements a two-tier caching hierarchy:

```
Request Flow:
┌─────────────┐
│   Client    │
└──────┬──────┘
       │
       ▼
┌─────────────────────────────────┐
│  Memory Cache (Hot Objects)     │  ← Fast access (RAM)
│  - cache_mem: 2048 MB           │
│  - maximum_object_size_in_memory│
└──────┬──────────────────────────┘
       │ (miss)
       ▼
┌─────────────────────────────────┐
│  Disk Cache (Warm Objects)      │  ← Persistent storage
│  - cache_dir: ufs/aufs/rock     │
└──────┬──────────────────────────┘
       │ (miss)
       ▼
┌─────────────────────────────────┐
│  Origin Server                  │  ← Fetch from source
└─────────────────────────────────┘
```

### 2.2 Collapsed Forwarding

**Implementation:** `src/store_client.cc` - `onCollapsingPath()`

Collapsed forwarding prevents multiple clients from triggering duplicate downloads of the same resource:

```cpp
bool StoreClient::onCollapsingPath() const
{
    if (!Config.onoff.collapsed_forwarding)
        return false;
    // Check ACL configuration
    return checklist.fastCheck().allowed();
}
```

**Benefits:**
- Reduces origin server load by 80-95% during cache misses
- Prevents bandwidth waste from duplicate requests
- Critical for large multimedia files (videos, ML models)

**Configuration:**
```conf
collapsed_forwarding on
```

**Reference:** `src/store_client.cc`, lines 141-152

---

## 3. Primary Storage Architecture

### 3.1 Storage Types

Squid supports multiple storage backends:

| Storage Type | Description | Best For | Performance |
|-------------|-------------|----------|-------------|
| **null** | No disk cache, memory only | Containers, ephemeral environments | Fastest |
| **ufs** | Unix File System (blocking I/O) | Small deployments, simple setups | Good |
| **aufs** | Asynchronous UFS (threaded I/O) | Medium-large deployments | Better |
| **diskd** | Separate disk I/O process | High-load environments | Better |
| **rock** | Database-style storage | Very large caches, SSD optimized | Best |

### 3.2 Memory Cache

**Configuration Directive:** `cache_mem`  
**Reference:** `src/cf.data.pre`, lines 4146-4188

```conf
# Ideal memory for in-transit and hot objects
cache_mem 2048 MB

# Maximum size of objects stored in memory
maximum_object_size_in_memory 1024 MB
```

**Memory Object Management:** `src/MemObject.cc`

The `MemObject` class manages in-memory cached objects with:
- URI management (`setUris()`)
- Reference counting to prevent premature eviction
- Integration with replacement policies via `RemovalPolicyNode`

### 3.3 Disk Cache

**Configuration Directive:** `cache_dir`  
**Reference:** `src/cf.data.pre`, lines 4291-4483

```conf
# Syntax: cache_dir <type> <directory> <size_mb> <L1_dirs> <L2_dirs>
cache_dir ufs /var/spool/squid 10000 16 256

# For large multimedia files
maximum_object_size 100 GB
minimum_object_size 0 KB
```

**Storage Digest:** `src/store_digest.cc`

Squid uses a Bloom filter for quick cache lookups:
- Targets 50% filter utilization for optimal performance
- Minimizes false positives
- Capacity based on store size and average object size

---

## 4. Eviction Policies

### 4.1 Available Policies

**Implementation:** `src/RemovalPolicy.h`, `src/repl/`

Squid provides pluggable replacement policies:

#### LRU (Least Recently Used)
**Implementation:** `src/repl/lru/store_repl_lru.cc`

```
Operation Complexity:
- Add: O(1)
- Reference: O(1)
- Eviction: O(1)

Data Structure: Doubly-linked list
- New entries → Tail
- Accessed entries → Move to tail
- Eviction → Remove from head
```

**Best for:** Simple workloads with temporal locality

#### LFUDA (Least Frequently Used with Dynamic Aging)
**Implementation:** `src/repl/heap/store_repl_heap.cc` - `HeapKeyGen_StoreEntry_LFUDA()`

```
Operation Complexity: O(log n)

Features:
- Tracks access frequency
- Dynamic aging prevents stale entries
- Prevents cache pollution from one-hit wonders
```

**Best for:** Mixed workloads with varying access patterns

#### GDSF (Greedy-Dual Size Frequency)
**Implementation:** `src/repl/heap/store_repl_heap.cc` - `HeapKeyGen_StoreEntry_GDSF()`

```
Operation Complexity: O(log n)

Features:
- Considers both frequency AND object size
- Optimizes hit rate and byte hit rate
- Ideal for multimedia with varying file sizes
```

**Best for:** Multimedia content with diverse file sizes (recommended)

#### Heap-LRU
**Implementation:** `src/repl/heap/store_repl_heap.cc` - `HeapKeyGen_StoreEntry_LRU()`

Heap-based implementation of LRU with O(log n) complexity.

### 4.2 Configuration

**Reference:** `src/cf.data.pre`, `src/store.cc` - `createRemovalPolicy()`

```conf
# Disk cache replacement policy
cache_replacement_policy heap GDSF

# Memory cache replacement policy
memory_replacement_policy heap GDSF
```

### 4.3 Policy Comparison for Multimedia

| Policy | Video Streaming | Large Images | Mixed Content | CPU Usage |
|--------|----------------|--------------|---------------|-----------|
| LRU | Good | Good | Fair | Low |
| LFUDA | Better | Better | Good | Medium |
| GDSF | **Best** | **Best** | **Best** | Medium |
| Heap-LRU | Good | Good | Fair | Medium |

**Recommendation:** Use **GDSF** for multimedia download services due to its consideration of both frequency and size.

---

## 5. Best File Types for Caching

### 5.1 Highly Cacheable

**Multimedia Files:**
- **Videos:** `.mp4`, `.webm`, `.mkv`, `.avi`, `.mov`
- **Images:** `.jpg`, `.jpeg`, `.png`, `.gif`, `.webp`, `.bmp`, `.tiff`
- **Audio:** `.mp3`, `.wav`, `.flac`, `.aac`, `.ogg`

**Machine Learning Models:**
- `.bin`, `.safetensors`, `.gguf`, `.pt`, `.pth`, `.onnx`, `.msgpack`

**Documents:**
- `.pdf`, `.zip`, `.tar.gz`, `.iso`

### 5.2 Configuration for Multimedia

**Reference:** `src/cf.data.pre`, lines 6641-6647 (refresh_pattern)

```conf
# Aggressive caching for multimedia files
# Format: refresh_pattern <regex> <min> <percent> <max> [options]

# Machine learning models (ignore no-cache headers)
refresh_pattern -i \.(bin|safetensors|gguf|pt|pth|onnx|msgpack)$ \
    10080 100% 43200 \
    override-expire ignore-no-cache ignore-no-store

# Images (ignore private/no-cache)
refresh_pattern -i \.(jpg|jpeg|png|gif|webp|bmp|tiff)$ \
    10080 100% 43200 \
    override-expire ignore-no-cache ignore-no-store ignore-private

# Videos
refresh_pattern -i \.(mp4|webm|mkv|avi|mov|flv)$ \
    10080 100% 43200 \
    override-expire ignore-no-cache ignore-no-store

# Default for all other content
refresh_pattern . 10080 100% 43200 \
    override-expire ignore-no-cache ignore-no-store
```

**Options Explained:**
- `override-expire`: Ignore Expires header
- `ignore-no-cache`: Ignore Cache-Control: no-cache
- `ignore-no-store`: Ignore Cache-Control: no-store
- `ignore-private`: Ignore Cache-Control: private

### 5.3 Range Request Handling

**Reference:** `src/cf.data.pre`, lines 6754-6789

For large multimedia files, configure range request behavior:

```conf
# Allow caching of range requests for large files
range_offset_limit none

# Quick abort settings for interrupted downloads
quick_abort_min -1 KB    # Always continue if cacheable
quick_abort_max 16 KB
quick_abort_pct 95
```

**Range Offset Limit Options:**
- `0` (default): Only fetch what client requested
- `none`: Always fetch from beginning (best for caching)
- `<size>`: Fetch full file if range is within size

**Reference:** `src/HttpHdrRange.cc`, `src/store_client.cc`

---

## 6. ETag Handling

### 6.1 ETag Structure

**Implementation:** `src/ETag.cc`

ETags enable efficient cache validation without re-downloading content:

```
Strong ETag: "etag-value"        → Byte-for-byte equality
Weak ETag:   W/"etag-value"      → Semantic equality
```

### 6.2 Validation Flow

```
┌─────────────────────────────────────────────────────────┐
│ Client Request → Squid                                  │
└────────────────┬────────────────────────────────────────┘
                 │
                 ▼
         ┌───────────────┐
         │ Cache Entry?  │
         └───────┬───────┘
                 │
        ┌────────┴────────┐
        │                 │
       Yes               No
        │                 │
        ▼                 ▼
  ┌──────────┐      ┌──────────┐
  │ Fresh?   │      │  Fetch   │
  └────┬─────┘      │  Origin  │
       │            └──────────┘
  ┌────┴─────┐
  │          │
 Yes        No (Stale)
  │          │
  │          ▼
  │    ┌─────────────────────────┐
  │    │ Send If-None-Match:     │
  │    │ ETag to Origin          │
  │    └──────────┬──────────────┘
  │               │
  │          ┌────┴─────┐
  │          │          │
  │      304 Match   200 Changed
  │          │          │
  │          ▼          ▼
  │    ┌─────────┐  ┌─────────┐
  │    │ Return  │  │ Update  │
  │    │ Cached  │  │ Cache   │
  │    └─────────┘  └─────────┘
  │          │          │
  └──────────┴──────────┘
             │
             ▼
      ┌──────────────┐
      │ Return to    │
      │ Client       │
      └──────────────┘
```

### 6.3 Bandwidth Savings

**Example:** 1GB video file with ETag validation
- Initial download: 1GB
- Subsequent requests (unchanged): ~500 bytes (304 response)
- **Bandwidth saved:** 99.99995%

**Reference:** `src/ETag.cc` - `etagParseInit()`, `etagIsStrongEqual()`, `etagIsWeakEqual()`

---

## 7. Configuration

### 7.1 Basic Multimedia Configuration

```conf
# Port configuration
http_port 8080

# Timeout settings (critical for large files)
connect_timeout 30 seconds
read_timeout 300 seconds
request_timeout 300 seconds
persistent_request_timeout 300 seconds
client_lifetime 1 hour

# Storage configuration
cache_dir ufs /var/spool/squid 100000 16 256
cache_mem 4096 MB
maximum_object_size_in_memory 512 MB
maximum_object_size 100 GB
minimum_object_size 0 KB

# Replacement policies
cache_replacement_policy heap GDSF
memory_replacement_policy heap GDSF

# Collapsed forwarding
collapsed_forwarding on

# Access control
acl CONNECT method CONNECT
http_access allow localhost
http_access allow CONNECT
http_access allow all

# Logging
access_log /var/log/squid/access.log squid
cache_log /var/log/squid/cache.log

# DNS
dns_nameservers 8.8.8.8 8.8.4.4
```

### 7.2 Advanced Multimedia Optimizations

```conf
# Read-ahead for streaming
read_ahead_gap 16 KB

# Store average object size (for capacity planning)
store_avg_object_size 13 KB

# Memory pools optimization
memory_pools on
memory_pools_limit 64 MB

# Disable unnecessary features for performance
via off
forwarded_for off
```

**Reference:** `src/cf.data.pre` (complete configuration reference)

---

## 8. Proxy Usage Modes

### 8.1 Forward Proxy (Default)

**Description:** Clients explicitly configure Squid as their proxy.

**Configuration:**
```conf
http_port 3128
```

**Use Case:** 
- Corporate networks
- Bandwidth optimization
- Content filtering

**Reference:** `src/cf.data.pre`, line 1314

### 8.2 Reverse Proxy (Accelerator)

**Description:** Squid sits in front of origin servers, caching content.

**Configuration:**
```conf
http_port 80 accel defaultsite=example.com
cache_peer backend.example.com parent 8080 0 no-query originserver
```

**Use Case:**
- CDN-like functionality
- Offload origin servers
- SSL termination

**Reference:** `src/cf.data.pre`, lines 2316-2327

### 8.3 Transparent Proxy (Intercept)

**Description:** Traffic is redirected to Squid without client configuration.

**Configuration:**
```conf
http_port 3129 intercept
```

**Requirements:**
- Firewall rules (iptables/pf)
- Network routing configuration

**Use Case:**
- ISP-level caching
- Mandatory proxy enforcement

**Reference:** `src/cf.data.pre`, line 3217; `doc/release-notes/release-3.5.sgml`, lines 243-261

### 8.4 Comparison

| Mode | Client Config | Transparency | Use Case |
|------|--------------|--------------|----------|
| Forward | Required | No | Corporate, explicit proxy |
| Reverse | Not needed | Yes | CDN, origin offload |
| Transparent | Not needed | Yes | ISP, mandatory caching |

---

## 9. HTTPS Decryption

### 9.1 SSL Bump Overview

**Implementation:** `src/ssl/ServerBump.cc`, `src/ssl/PeekingPeerConnector.cc`

SSL Bump allows Squid to inspect and cache HTTPS traffic by performing man-in-the-middle decryption.

**Reference:** `src/cf.data.pre`, lines 3209-3294

### 9.2 SSL Bump Actions

| Action | Description | When to Use |
|--------|-------------|-------------|
| **splice** | Pass through without decryption | Banking, sensitive sites |
| **bump** | Decrypt and inspect | Cacheable HTTPS content |
| **peek** | Inspect SNI, then decide | Initial classification |
| **stare** | Inspect server certificate | Certificate validation |
| **terminate** | Block connection | Policy enforcement |

### 9.3 Configuration

```conf
# HTTPS port with SSL bump
https_port 3129 intercept ssl-bump \
    cert=/etc/squid/ssl/squid.pem \
    key=/etc/squid/ssl/squid.key

# SSL bump configuration
acl step1 at_step SslBump1
acl step2 at_step SslBump2
acl step3 at_step SslBump3

# Splice sensitive sites
acl sensitive_sites ssl::server_name .bank.com .healthcare.org
ssl_bump splice sensitive_sites

# Peek at SNI
ssl_bump peek step1

# Bump (decrypt) everything else
ssl_bump bump all

# Certificate generation
sslcrtd_program /usr/lib/squid/security_file_certgen -s /var/lib/squid/ssl_db -M 4MB
```

### 9.4 Certificate Requirements

1. **Generate CA certificate:**
```bash
openssl req -new -newkey rsa:2048 -sha256 -days 365 -nodes -x509 \
    -keyout squid-ca.key -out squid-ca.crt
```

2. **Install CA on clients** (required for SSL bump to work)

3. **Initialize certificate database:**
```bash
/usr/lib/squid/security_file_certgen -c -s /var/lib/squid/ssl_db -M 4MB
```

### 9.5 Limitations

- **Client trust required:** CA certificate must be installed on all clients
- **Certificate pinning:** Sites using HPKP will fail
- **Performance overhead:** Encryption/decryption adds CPU load
- **Legal considerations:** May violate privacy laws in some jurisdictions

**Reference:** `src/cf.data.pre`, lines 1491-1494, 3209-3294

---

## 10. Best Use Cases

### 10.1 Multimedia Download Service

**Scenario:** Caching large video files, images, and ML models

**Configuration Highlights:**
```conf
cache_mem 8192 MB
maximum_object_size 100 GB
cache_replacement_policy heap GDSF
collapsed_forwarding on
range_offset_limit none
quick_abort_min -1 KB
```

**Benefits:**
- 80-95% bandwidth reduction
- Faster download speeds for cached content
- Reduced origin server load

### 10.2 Video Streaming CDN

**Scenario:** Caching video segments for HLS/DASH streaming

**Configuration Highlights:**
```conf
refresh_pattern -i \.(m3u8|mpd|ts|m4s)$ 60 50% 120
maximum_object_size_in_memory 10 MB
read_ahead_gap 64 KB
```

**Benefits:**
- Low latency for video segments
- Efficient range request handling
- Reduced buffering for end users

### 10.3 Machine Learning Model Repository

**Scenario:** Caching Hugging Face models, weights, and datasets

**Configuration Highlights:**
```conf
refresh_pattern -i \.(bin|safetensors|gguf)$ 10080 100% 43200 \
    override-expire ignore-no-cache ignore-no-store
maximum_object_size 200 GB
collapsed_forwarding on
```

**Benefits:**
- Prevents duplicate downloads across GPU nodes
- Significant bandwidth savings (models are 1-100GB)
- Faster model loading times


## 11. Memory Consumption Management

### 11.1 Overview

Memory consumption is a critical factor in Squid's performance, especially for multimedia download services handling large files. Squid uses sophisticated memory management through pooled allocation and configurable limits.

**Implementation:** `src/mem/Stats.cc`, `src/mem/Pool.cc`, `src/mem/PoolMalloc.cc`

### 11.2 Key Memory Components

#### Memory Pools

**Reference:** `src/mem/Stats.cc` - `Mem::GlobalStats()`

Squid uses memory pools to reduce fragmentation and improve allocation performance:

```cpp
size_t Mem::GlobalStats(PoolStats &stats)
{
    MemPools::GetInstance().flushMeters();
    stats.meter = &TheMeter;
    // Gather stats from all pools
    for (const auto pool: MemPools::GetInstance().pools) {
        if (pool->getStats(stats) > 0)
            ++pools_inuse;
        stats.overhead += sizeof(Allocator *);
    }
}
```

**Benefits:**
- Reduces memory fragmentation
- Faster allocation/deallocation
- Predictable memory usage patterns
- Lower overhead compared to malloc/free

#### Memory Cache (cache_mem)

**Reference:** `src/cf.data.pre`, lines 4146-4188

The memory cache holds hot objects for fastest access:

```conf
# Ideal amount of memory for caching
cache_mem 4096 MB

# Maximum size of individual objects in memory
maximum_object_size_in_memory 512 MB

# Control what goes into memory cache
memory_cache_mode always  # or: disk, network
```

**Memory Cache Modes:**
- `always`: Cache all objects in memory (default)
- `disk`: Only cache objects fetched from disk
- `network`: Only cache objects fetched from network

**Memory Hierarchy:**
```
Hot Objects (Frequently Accessed)
    ↓
Memory Cache (cache_mem)
    ↓ (evicted by memory_replacement_policy)
Disk Cache (cache_dir)
    ↓ (evicted by cache_replacement_policy)
Purged
```

### 11.3 Shared Memory Cache (SMP Workers)

**Reference:** `src/cf.data.pre`, lines 4200-4223

For multi-worker deployments, Squid can share memory cache across processes:

```conf
# Number of worker processes
workers 4

# Enable shared memory cache
memory_cache_shared on

# Shared memory locking
shared_memory_locking on
```

**Benefits:**
- Single cache shared by all workers
- Eliminates duplicate cached objects
- Better memory utilization
- Improved cache hit rate

**Trade-offs:**
- Requires IPC (Inter-Process Communication)
- Slight performance overhead for synchronization
- More complex setup

**Memory Calculation:**
```
Total Memory = cache_mem × workers (if memory_cache_shared off)
Total Memory = cache_mem (if memory_cache_shared on)
```

### 11.4 Memory Pools Configuration

**Reference:** `src/cf.data.pre`, lines 10305-10326

```conf
# Enable memory pools (recommended)
memory_pools on

# Limit pooled memory (prevents unbounded growth)
memory_pools_limit 64 MB
```

**memory_pools_limit Options:**
- `<size>`: Keep at most this much unused memory in pools
- `none`: No limit (keep all freed memory)
- `0`: Disable (not recommended, use `memory_pools off` instead)

**Overhead Calculation:**
- ~4 bytes per pooled object
- Trade-off: Small overhead vs. reduced malloc thrashing

### 11.5 Memory Consumption Keys

#### Key Factors Affecting Memory Usage

| Factor | Impact | Configuration |
|--------|--------|---------------|
| **cache_mem** | Primary memory usage | Set based on available RAM |
| **Workers** | Multiplies memory if not shared | Use `memory_cache_shared on` |
| **Object Size** | Larger objects = more memory | `maximum_object_size_in_memory` |
| **Cache Hit Rate** | Higher rate = more memory used | Tune `refresh_pattern` |
| **Memory Pools** | Reduces fragmentation overhead | `memory_pools on` |
| **In-Transit Objects** | Temporary memory during downloads | Affected by `cache_mem` |

#### Memory Usage Formula

```
Estimated Memory Usage =
    cache_mem +
    (workers × cache_mem if memory_cache_shared off) +
    memory_pools_limit +
    (in_transit_objects × average_object_size) +
    overhead (DNS cache, connection state, etc.)
```

**Typical Overhead:** 50-200 MB for Squid process itself

### 11.6 Memory Optimization Strategies

#### For Large Multimedia Files

```conf
# Prioritize disk cache over memory
cache_mem 2048 MB
maximum_object_size_in_memory 100 MB  # Don't cache huge files in RAM

# Use memory for metadata and small objects
memory_cache_mode disk  # Only cache disk-fetched objects in memory

# Limit memory pools
memory_pools_limit 128 MB
```

#### For High-Throughput Environments

```conf
# Large memory cache for hot objects
cache_mem 16384 MB  # 16 GB
maximum_object_size_in_memory 1024 MB

# Shared memory for multiple workers
workers 8
memory_cache_shared on

# Generous pool limit
memory_pools_limit 512 MB
```

#### For Memory-Constrained Environments

```conf
# Minimal memory cache
cache_mem 256 MB
maximum_object_size_in_memory 10 MB

# Rely on disk cache
cache_dir ufs /var/spool/squid 50000 16 256

# Tight pool limit
memory_pools_limit 32 MB

# Reduce DNS/IP caches
fqdncache_size 100
ipcache_size 100
```

### 11.7 Monitoring Memory Usage

#### Cache Manager Interface

```bash
# View memory statistics
squidclient mgr:mem

# View pool statistics
squidclient mgr:mem_pools

# View cache statistics
squidclient mgr:info
```

#### Key Metrics to Monitor

| Metric | Description | Healthy Range |
|--------|-------------|---------------|
| **Memory Usage** | Total RSS of Squid process | < 80% of cache_mem + overhead |
| **Pool Utilization** | Percentage of pools in use | 40-70% |
| **Cache Hit Rate** | Percentage served from cache | > 30% for multimedia |
| **Memory Objects** | Number of objects in memory | Depends on average size |
| **Swap Usage** | Disk cache utilization | 60-90% |

#### Log Analysis

```bash
# Check for memory warnings
grep -i "memory" /var/log/squid/cache.log

# Monitor cache performance
tail -f /var/log/squid/access.log | grep -E "TCP_HIT|TCP_MISS"
```

### 11.8 Memory Consumption Best Practices

1. **Size cache_mem appropriately:**
   - Start with 25% of available RAM
   - Monitor and adjust based on hit rate
   - Leave room for OS and other processes

2. **Use shared memory for SMP:**
   - Enable `memory_cache_shared on` with multiple workers
   - Reduces total memory footprint
   - Improves cache efficiency

3. **Limit in-memory object size:**
   - Set `maximum_object_size_in_memory` to reasonable value
   - Large files should use disk cache
   - Prevents memory exhaustion

4. **Configure memory pools:**
   - Keep `memory_pools on` for performance
   - Set `memory_pools_limit` to prevent unbounded growth
   - Monitor pool utilization

5. **Monitor and tune:**
   - Regularly check memory usage
   - Adjust based on workload patterns
   - Use cache manager for insights

### 11.9 Troubleshooting Memory Issues

#### High Memory Usage

**Symptoms:**
- Squid process using more RAM than expected
- System swapping
- Out-of-memory errors

**Solutions:**
```conf
# Reduce memory cache
cache_mem 1024 MB

# Lower object size limit
maximum_object_size_in_memory 50 MB

# Tighten pool limit
memory_pools_limit 32 MB

# Reduce DNS caches
fqdncache_size 50
ipcache_size 50
```

#### Memory Leaks

**Symptoms:**
- Memory usage grows continuously
- Never stabilizes
- Eventually crashes

**Solutions:**
1. Update to latest Squid version
2. Check for known bugs in release notes
3. Enable debug logging: `debug_options ALL,1 20,3`
4. Report to Squid developers with logs

#### Poor Cache Performance

**Symptoms:**
- Low hit rate despite adequate memory
- Frequent evictions
- Slow response times

**Solutions:**
```conf
# Increase memory cache
cache_mem 8192 MB

# Use better replacement policy
memory_replacement_policy heap GDSF

# Adjust refresh patterns
refresh_pattern -i \.(jpg|png|mp4)$ 10080 100% 43200
```

---

## 12. HTTPS Request Handling

### 12.1 Overview

Handling HTTPS traffic is crucial for modern multimedia download services, as most content is served over encrypted connections. Squid provides multiple approaches to handle HTTPS requests, each with different trade-offs.

### 12.2 HTTPS Handling Methods

#### Method 1: CONNECT Tunneling (Default)

**Description:** Squid acts as a TCP tunnel without inspecting encrypted traffic.

**Configuration:**
```conf
# Allow CONNECT method
acl CONNECT method CONNECT
http_access allow CONNECT

# Standard HTTP port
http_port 3128
```

**Flow:**
```
Client → Squid: CONNECT example.com:443
Squid → Origin: TCP connection
Client ↔ Squid ↔ Origin: Encrypted tunnel (TLS passthrough)
```

**Characteristics:**
- ✅ No certificate management required
- ✅ Privacy preserved (no decryption)
- ✅ Simple configuration
- ❌ Cannot cache HTTPS content
- ❌ Cannot inspect traffic
- ❌ No bandwidth savings for HTTPS

**Best for:** Privacy-focused environments, minimal configuration

#### Method 2: SSL Bump (HTTPS Interception)

**Description:** Squid decrypts, inspects, and re-encrypts HTTPS traffic.

**Implementation:** `src/ssl/ServerBump.cc`, `src/ssl/PeekingPeerConnector.cc`

**Reference:** `src/cf.data.pre`, lines 3209-3294

**Configuration:**
```conf
# HTTPS port with SSL bump
https_port 3129 intercept ssl-bump \
    cert=/etc/squid/ssl/squid-ca.crt \
    key=/etc/squid/ssl/squid-ca.key \
    generate-host-certificates=on \
    dynamic_cert_mem_cache_size=4MB

# SSL bump rules
acl step1 at_step SslBump1
acl step2 at_step SslBump2
acl step3 at_step SslBump3

# Define sensitive sites to bypass
acl sensitive_sites ssl::server_name .bank.com .healthcare.org .gov
ssl_bump splice sensitive_sites

# Peek at SNI (Server Name Indication)
ssl_bump peek step1

# Bump (decrypt) everything else
ssl_bump bump all

# Certificate generation helper
sslcrtd_program /usr/lib/squid/security_file_certgen \
    -s /var/lib/squid/ssl_db -M 4MB

# SSL options
sslproxy_cert_error allow all
sslproxy_flags DONT_VERIFY_PEER
```

**SSL Bump Actions:**

| Action | Description | Use Case |
|--------|-------------|----------|
| **splice** | Pass through without decryption | Banking, sensitive sites |
| **bump** | Decrypt, inspect, cache, re-encrypt | Cacheable content |
| **peek** | Inspect SNI, then decide | Initial classification |
| **stare** | Inspect server certificate | Certificate validation |
| **terminate** | Block connection | Policy enforcement |

**SSL Bump Steps:**

```
Step 1 (SslBump1): Client Hello received
    ↓ (peek action)
Step 2 (SslBump2): Server Hello received
    ↓ (stare action)
Step 3 (SslBump3): Server certificate validated
    ↓ (bump/splice decision)
Final: Establish connection or tunnel
```

**Characteristics:**
- ✅ Can cache HTTPS content
- ✅ Can inspect traffic
- ✅ Bandwidth savings for HTTPS
- ✅ Content filtering possible
- ❌ Requires CA certificate installation on clients
- ❌ Certificate pinning sites will fail
- ❌ CPU overhead for encryption/decryption
- ❌ Privacy concerns
- ❌ Legal/compliance issues in some jurisdictions

**Best for:** Corporate environments with managed clients, content caching

#### Method 3: Explicit Proxy with CONNECT

**Description:** Clients configured to use Squid as explicit proxy for HTTPS.

**Configuration:**
```conf
# Standard proxy port
http_port 3128

# Allow CONNECT for HTTPS
acl SSL_ports port 443
acl CONNECT method CONNECT
http_access allow CONNECT SSL_ports
http_access deny CONNECT
```

**Client Configuration:**
```bash
# Linux/Mac
export http_proxy=http://squid.example.com:3128
export https_proxy=http://squid.example.com:3128

# Windows
set http_proxy=http://squid.example.com:3128
set https_proxy=http://squid.example.com:3128
```

**Characteristics:**
- ✅ Simple configuration
- ✅ No certificate management
- ✅ Works with all HTTPS sites
- ❌ Cannot cache HTTPS content
- ❌ Requires client configuration

**Best for:** Development environments, testing

### 12.3 SSL Bump Setup Guide

#### Step 1: Generate CA Certificate

```bash
# Create directory
mkdir -p /etc/squid/ssl
cd /etc/squid/ssl

# Generate CA private key
openssl genrsa -out squid-ca.key 4096

# Generate CA certificate (valid 10 years)
openssl req -new -x509 -days 3650 -key squid-ca.key -out squid-ca.crt \
    -subj "/C=US/ST=State/L=City/O=Organization/CN=Squid CA"

# Set permissions
chmod 600 squid-ca.key
chmod 644 squid-ca.crt
chown squid:squid squid-ca.*
```

#### Step 2: Initialize Certificate Database

```bash
# Create database directory
mkdir -p /var/lib/squid/ssl_db
chown squid:squid /var/lib/squid/ssl_db

# Initialize database
/usr/lib/squid/security_file_certgen -c -s /var/lib/squid/ssl_db -M 4MB
```

#### Step 3: Configure Squid

```conf
# Add to squid.conf
https_port 3129 intercept ssl-bump \
    cert=/etc/squid/ssl/squid-ca.crt \
    key=/etc/squid/ssl/squid-ca.key \
    generate-host-certificates=on \
    dynamic_cert_mem_cache_size=4MB

sslcrtd_program /usr/lib/squid/security_file_certgen \
    -s /var/lib/squid/ssl_db -M 4MB

acl step1 at_step SslBump1
ssl_bump peek step1
ssl_bump bump all
```

#### Step 4: Install CA on Clients

**Linux:**
```bash
# Copy CA certificate
sudo cp squid-ca.crt /usr/local/share/ca-certificates/

# Update certificate store
sudo update-ca-certificates
```

**Windows:**
```powershell
# Import to Trusted Root Certification Authorities
certutil -addstore -f "ROOT" squid-ca.crt
```

**macOS:**
```bash
# Add to system keychain
sudo security add-trusted-cert -d -r trustRoot \
    -k /Library/Keychains/System.keychain squid-ca.crt
```

**Firefox (uses own certificate store):**
1. Preferences → Privacy & Security → Certificates → View Certificates
2. Authorities → Import → Select squid-ca.crt
3. Trust for identifying websites

#### Step 5: Configure Firewall (for Transparent Interception)

**Linux (iptables):**
```bash
# Redirect HTTP traffic
iptables -t nat -A PREROUTING -i eth0 -p tcp --dport 80 \
    -j REDIRECT --to-port 3128

# Redirect HTTPS traffic
iptables -t nat -A PREROUTING -i eth0 -p tcp --dport 443 \
    -j REDIRECT --to-port 3129
```

### 12.4 HTTPS Caching Configuration

Once SSL bump is configured, optimize for multimedia caching:

```conf
# Aggressive caching for HTTPS content
refresh_pattern -i ^https:.*\.(jpg|png|gif|webp)$ \
    10080 100% 43200 \
    override-expire ignore-no-cache ignore-no-store

refresh_pattern -i ^https:.*\.(mp4|webm|mkv)$ \
    10080 100% 43200 \
    override-expire ignore-no-cache ignore-no-store

refresh_pattern -i ^https:.*\.(bin|safetensors|gguf)$ \
    10080 100% 43200 \
    override-expire ignore-no-cache ignore-no-store

# Allow large HTTPS objects
maximum_object_size 100 GB

# Cache HTTPS in memory
cache_mem 4096 MB
maximum_object_size_in_memory 512 MB
```

### 12.5 Selective SSL Bump (Recommended)

**Strategy:** Bump only cacheable content, splice sensitive sites.

```conf
# Define site categories
acl sensitive_sites ssl::server_name "/etc/squid/sensitive-sites.txt"
acl media_sites ssl::server_name "/etc/squid/media-sites.txt"

# SSL bump rules (order matters!)
ssl_bump splice sensitive_sites
ssl_bump peek step1
ssl_bump bump media_sites
ssl_bump splice all  # Default: don't bump unknown sites
```

**sensitive-sites.txt:**
```
.bank.com
.paypal.com
.healthcare.org
.gov
```

**media-sites.txt:**
```
.youtube.com
.vimeo.com
.cdn.example.com
huggingface.co
```

### 12.6 HTTPS Performance Considerations

#### CPU Usage

SSL/TLS operations are CPU-intensive:

```
Typical CPU overhead:
- CONNECT tunnel: ~1% CPU
- SSL bump: ~15-30% CPU (depends on traffic volume)
```

**Optimization:**
```conf
# Use hardware acceleration if available
sslproxy_options NO_SSLv3,NO_TLSv1,NO_TLSv1_1

# Limit concurrent SSL connections
sslcrtd_children 32 startup=5 idle=1
```

#### Memory Usage

SSL bump increases memory consumption:

```
Additional memory per connection:
- Certificate cache: ~4 KB per certificate
- SSL session: ~10-20 KB per connection
```

**Configuration:**
```conf
# Certificate cache
dynamic_cert_mem_cache_size 4MB  # ~1000 certificates

# SSL session cache
sslproxy_session_cache_size 4 MB
```

### 12.7 HTTPS Troubleshooting

#### Certificate Errors

**Problem:** Clients see certificate warnings

**Solutions:**
1. Verify CA certificate is installed on clients
2. Check certificate validity: `openssl x509 -in squid-ca.crt -text -noout`
3. Ensure certificate database is initialized
4. Check Squid logs: `tail -f /var/log/squid/cache.log`

#### Sites Not Loading

**Problem:** Some HTTPS sites fail to load

**Solutions:**
```conf
# Bypass certificate validation errors
sslproxy_cert_error allow all

# Don't verify peer certificates
sslproxy_flags DONT_VERIFY_PEER

# Splice problematic sites
acl broken_sites ssl::server_name .problematic-site.com
ssl_bump splice broken_sites
```

#### Certificate Pinning Failures

**Problem:** Apps with certificate pinning fail

**Solution:** Splice those connections
```conf
acl pinned_apps ssl::server_name .twitter.com .facebook.com
ssl_bump splice pinned_apps
```

### 12.8 Legal and Compliance Considerations

**Important:** SSL bump may violate:
- Privacy laws (GDPR, CCPA)
- Employee privacy rights
- Terms of service of some websites
- Industry regulations (HIPAA, PCI-DSS)

**Best Practices:**
1. **Inform users:** Clearly communicate SSL interception policy
2. **Obtain consent:** Get explicit user agreement
3. **Limit scope:** Only bump necessary traffic
4. **Protect data:** Secure logs and cached content
5. **Comply with regulations:** Consult legal counsel

**Recommended Policy:**
```conf
# Splice by default, bump only known-safe sites
ssl_bump splice all  # Default
ssl_bump bump media_sites  # Only bump approved sites
```

### 12.9 HTTPS Handling Comparison

| Method | Caching | Privacy | Setup | CPU | Best For |
|--------|---------|---------|-------|-----|----------|
| **CONNECT Tunnel** | ❌ No | ✅ High | ✅ Easy | ✅ Low | Privacy-focused |
| **SSL Bump** | ✅ Yes | ❌ Low | ❌ Complex | ❌ High | Corporate caching |
| **Explicit Proxy** | ❌ No | ✅ High | ✅ Easy | ✅ Low | Development |
| **Selective Bump** | ⚠️ Partial | ⚠️ Medium | ⚠️ Medium | ⚠️ Medium | **Recommended** |

### 12.10 HTTPS Caching Best Practices

1. **Use selective SSL bump:**
   - Only bump cacheable content
   - Splice sensitive sites
   - Default to splice for unknown sites

2. **Optimize certificate handling:**
   - Use adequate certificate cache size
   - Monitor certificate generation performance
   - Rotate certificates periodically

3. **Monitor performance:**
   - Track CPU usage
   - Monitor SSL connection rate
   - Watch for certificate errors

4. **Maintain security:**
   - Keep CA private key secure
   - Limit access to certificate database
   - Audit SSL bump rules regularly

5. **Document and communicate:**
   - Maintain clear SSL bump policy
   - Inform users about interception
   - Document bypassed sites

---


### 10.4 Image CDN

**Scenario:** Caching user-generated images and thumbnails

**Configuration Highlights:**
```conf
refresh_pattern -i \.(jpg|png|webp)$ 10080 100% 43200
maximum_object_size_in_memory 5 MB
cache_replacement_policy heap LFUDA
```

**Benefits:**
- High cache hit rate for popular images
- Reduced origin bandwidth
- Fast image delivery

---

## 11. Config-Map.yaml Explanation

### 11.1 Overview

The `config-map.yaml` file is a Kubernetes ConfigMap containing Squid configuration optimized for containerized environments, specifically for caching machine learning models from Hugging Face.

**File Location:** `/home/eres/mm_downloader/squid/config-map.yaml`

### 11.2 Key Sections

#### Port Configuration
```yaml
http_port 8080
```
- Listens on port 8080 (non-privileged port for containers)
- Suitable for Kubernetes/OpenShift environments

#### PID File Configuration
```yaml
pid_filename /var/cache/squid/squid.pid
netdb_filename none
```
- **Purpose:** OpenShift Security Context Constraints (SCC) compliance
- Writes PID to writable directory
- Disables network database (not needed in containers)

#### Timeout Configuration
```yaml
connect_timeout 30 seconds
read_timeout 300 seconds
request_timeout 300 seconds
persistent_request_timeout 300 seconds
client_lifetime 1 hour
peer_connect_timeout 30 seconds
forward_timeout 300 seconds
```
- **Critical for large files:** 5-minute timeouts prevent premature connection closure
- `client_lifetime 1 hour`: Allows long-running downloads
- **Why important:** ML models can be 10-100GB, requiring extended timeouts

#### Storage Configuration
```yaml
cache_dir null /tmp
cache_mem 2048 MB
maximum_object_size_in_memory 1024 MB
```
- **`cache_dir null`:** Memory-only caching (no disk cache)
  - **Reason:** Avoids permission issues in containers
  - **Trade-off:** Cache lost on pod restart
- **`cache_mem 2048 MB`:** 2GB RAM cache
- **`maximum_object_size_in_memory 1024 MB`:** Cache objects up to 1GB in RAM

##### Understanding Memory Cache Capacity

**What does `/tmp` mean in `cache_dir null /tmp`?**
- The `null` type means **no disk caching** - all caching is memory-only
- The `/tmp` path is **ignored** and serves only as a required syntax placeholder
- No files are written to `/tmp` or any disk location
- Cache is completely lost when Squid restarts

**Memory Overhead:**
Squid uses memory beyond just cached content for:
- Object metadata and index structures (hash tables, LRU lists)
- In-transit objects (active downloads - highest priority)
- DNS/IP caches (minimized with `fqdncache_size 100`, `ipcache_size 100`)
- Data stored in 4 KB blocks

**Typical overhead: 10-20% of `cache_mem`** for management structures.

**Practical Cache Capacity (with 2 GB `cache_mem`):**
- **Usable space: ~1.6-1.8 GB** (80-90% of configured memory)

**Example Capacity by Content Type:**

| Content Type | Size | Approximate Count |
|--------------|------|-------------------|
| Small images | 100 KB | 16,000-18,000 |
| Medium images | 500 KB | 3,200-3,600 |
| Large images | 2 MB | 800-900 |
| Very large images | 10 MB | 160-180 |
| Short video clips | 5 MB | 320-360 |
| Medium videos | 50 MB | 32-36 |
| Large videos | 200 MB | 8-9 |
| Max size objects | 1 GB | 1-2 |

**Important Considerations:**
1. **In-transit priority:** Active downloads consume memory first, reducing available cache
2. **Mixed content:** Real-world usage has varying object sizes
3. **LRU eviction:** Least recently used items are evicted when memory fills
4. **ML model limitation:** With 2 GB cache, only 1-2 large model files (1 GB each) can be cached simultaneously

**Recommendations for ML Model Caching:**
- Consider increasing `cache_mem` to 8-16 GB if RAM is available
- For persistent caching of large models, use disk-based `cache_dir` instead of `null`
- Use `cache_replacement_policy heap LFUDA` to optimize for large file byte hit rate
- Monitor cache hit rates with access logs to tune configuration


#### Memory Optimization
```yaml
fqdncache_size 100
ipcache_size 100
memory_pools off
```
- Reduces memory overhead for containerized environment
- Smaller DNS caches (fewer unique hosts in typical use)

#### Large Object Support
```yaml
maximum_object_size 100 GB
minimum_object_size 0 KB
```
- **Essential for ML models:** Allows caching files up to 100GB
- No minimum size restriction

#### Aggressive Caching Rules
```yaml
refresh_pattern -i \.(bin|safetensors|gguf|pt|pth|onnx|msgpack|json|yaml|txt)$ \
    10080 100% 43200 \
    override-expire ignore-no-cache ignore-no-store

refresh_pattern -i \.(jpg|jpeg|png|gif|webp|bmp|tiff)$ \
    10080 100% 43200 \
    override-expire ignore-no-cache ignore-no-store ignore-private

refresh_pattern . 10080 100% 43200 \
    override-expire ignore-no-cache ignore-no-store
```

**Breakdown:**
- **Pattern 1:** ML model files (`.bin`, `.safetensors`, etc.)
- **Pattern 2:** Image files
- **Pattern 3:** Catch-all for other content

**Parameters:**
- `10080`: Minimum age (7 days)
- `100%`: Percentage of age to use as freshness
- `43200`: Maximum age (30 days)

**Options:**
- `override-expire`: Ignore Expires header from Hugging Face
- `ignore-no-cache`: Cache even if server says "no-cache"
- `ignore-no-store`: Cache even if server says "no-store"
- `ignore-private`: Cache even if marked private (for images)

**Why aggressive?** Hugging Face often sends `Cache-Control: no-cache` headers, but models rarely change. Ignoring these headers saves massive bandwidth.

#### Access Control
```yaml
acl CONNECT method CONNECT
http_access allow localhost
http_access allow CONNECT
http_access allow all
```
- Allows all traffic (suitable for internal cluster use)
- Permits HTTPS tunneling via CONNECT method

#### Logging
```yaml
logformat cache_status %>a %[ui %[un [%tl] "%rm %ru HTTP/%rv" %>Hs %<st "%{Referer}>h" "%{User-Agent}>h" %Ss:%Sh
access_log stdio:/dev/stdout cache_status
cache_log /var/cache/squid/cache.log
```
- **Custom log format:** Includes cache status (TCP_HIT, TCP_MISS, etc.)
- **stdout logging:** Kubernetes-friendly (captured by container runtime)
- **Cache status codes:**
  - `TCP_HIT`: Served from cache
  - `TCP_MISS`: Fetched from origin
  - `TCP_REFRESH_HIT`: Revalidated, still fresh

#### Collapsed Forwarding
```yaml
collapsed_forwarding on
```
- **Critical feature:** Prevents multiple pods from downloading the same model simultaneously
- **Scenario:** 10 GPU pods start up, all need same 50GB model
  - Without collapsed forwarding: 10 × 50GB = 500GB download
  - With collapsed forwarding: 1 × 50GB = 50GB download (90% savings)

#### DNS Configuration
```yaml
dns_nameservers 8.8.8.8 8.8.4.4
```
- Uses Google DNS for reliable resolution
- Ensures `huggingface.co` can be resolved from within cluster

### 11.3 Use Case: ML Model Caching

This configuration is optimized for caching machine learning models in a Kubernetes cluster:

**Scenario:**
1. Multiple vLLM pods need to download models from Hugging Face
2. Models are 10-100GB in size
3. Models rarely change once published
4. Bandwidth is expensive

**Solution:**
1. Deploy Squid with this config as a service in the cluster
2. Configure vLLM pods to use Squid as HTTP proxy
3. First pod downloads model from Hugging Face (TCP_MISS)
4. Subsequent pods get model from Squid cache (TCP_HIT)
5. Bandwidth savings: 80-95%

**Example:**
```bash
# In vLLM pod
export HTTP_PROXY=http://squid-service:8080
export HTTPS_PROXY=http://squid-service:8080

# Download model (first time: from Hugging Face, subsequent: from cache)
huggingface-cli download meta-llama/Llama-2-70b-hf
```

### 11.4 Limitations of This Configuration

1. **No persistence:** Cache lost on pod restart (use persistent volume for production)
2. **Memory-only:** Limited by RAM (2GB cache for potentially 100GB+ models)
3. **No HTTPS decryption:** Cannot cache HTTPS traffic without SSL bump
4. **Permissive access:** Allows all traffic (add ACLs for production)

### 11.5 Production Improvements

```yaml
# Add persistent disk cache
cache_dir ufs /var/cache/squid/cache 50000 16 256

# Increase memory
cache_mem 8192 MB

# Add access control
acl allowed_clients src 10.0.0.0/8
http_access allow allowed_clients
http_access deny all

# Add authentication (optional)
auth_param basic program /usr/lib/squid/basic_ncsa_auth /etc/squid/passwd
acl authenticated proxy_auth REQUIRED
http_access allow authenticated
```

---

## 14. References

### 14.1 Source Code References

| Component | File | Description |
|-----------|------|-------------|
| Eviction Policies | `src/RemovalPolicy.h` | Policy interface |
| LRU Implementation | `src/repl/lru/store_repl_lru.cc` | LRU eviction |
| Heap Policies | `src/repl/heap/store_repl_heap.cc` | LFUDA, GDSF, Heap-LRU |
| ETag Handling | `src/ETag.cc` | ETag parsing and comparison |
| Memory Objects | `src/MemObject.cc` | In-memory object management |
| Store Client | `src/store_client.cc` | Collapsed forwarding |
| Store Digest | `src/store_digest.cc` | Bloom filter cache index |
| Memory Stats | `src/mem/Stats.cc` | Memory pool statistics |
| Memory Pools | `src/mem/Pool.cc` | Pool implementation |
| Memory Allocation | `src/mem/PoolMalloc.cc` | Pooled malloc |
| Configuration | `src/cf.data.pre` | All configuration directives |
| SSL Bump | `src/ssl/ServerBump.cc` | HTTPS decryption |
| SSL Peering | `src/ssl/PeekingPeerConnector.cc` | SSL connection handling |
| Range Requests | `src/HttpHdrRange.cc` | Partial content handling |

### 14.2 Configuration References

| Directive | Line in cf.data.pre | Description |
|-----------|---------------------|-------------|
| `cache_mem` | 4146-4188 | Memory cache size |
| `memory_cache_mode` | 4226-4232 | Memory cache behavior |
| `memory_cache_shared` | 4200-4223 | Shared memory for SMP workers |
| `memory_pools` | 10295-10303 | Enable memory pooling |
| `memory_pools_limit` | 10305-10326 | Limit pooled memory |
| `workers` | 477-491 | Number of SMP workers |
| `shared_memory_locking` | 518 | Lock shared memory |
| `cache_dir` | 4291-4483 | Disk cache configuration |
| `refresh_pattern` | 6641-6647 | Cache freshness rules |
| `quick_abort_*` | 6650-6697 | Interrupted download handling |
| `range_offset_limit` | 6754-6789 | Range request behavior |
| `ssl_bump` | 3209-3294 | HTTPS decryption |
| `https_port` | (with ssl-bump) | HTTPS interception port |
| `sslcrtd_program` | (SSL certificate generation) | Certificate helper |
| `http_port` | 1314-2327 | Port and mode configuration |
| `collapsed_forwarding` | (Config.onoff) | Duplicate request prevention |

### 12.3 Documentation References

| Document | Location | Description |
|----------|----------|-------------|
| Caching Overview | `squid-caching-overview.md` | Detailed caching architecture |
| Config Map | `config-map.yaml` | Kubernetes deployment config |
| Release Notes | `doc/release-notes/` | Version-specific features |
| RFC References 