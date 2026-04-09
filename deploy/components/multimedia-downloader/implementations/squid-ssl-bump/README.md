# Squid SSL Bump Implementation

This directory contains a complete implementation of Squid proxy with SSL Bump enabled for intercepting and caching HTTPS traffic from vLLM pods downloading ML models from Hugging Face.

## Overview

**What is SSL Bump?**

SSL Bump allows Squid to act as a man-in-the-middle proxy, intercepting HTTPS connections, decrypting them, and re-encrypting them. This enables:
- Caching of HTTPS content (ML models from Hugging Face)
- Content inspection and filtering
- Bandwidth optimization for encrypted traffic

**Architecture:**
```
vLLM Pod → HTTPS Request → Squid (SSL Bump) → Decrypt → Cache → Re-encrypt → Hugging Face
                                    ↓
                            Generate dynamic cert
                            signed by Squid CA
```

## Files in This Directory

- **`generate-certs.sh`**: Script to generate SSL certificates and create Kubernetes secrets
- **`squid-ssl-bump-config.yaml`**: ConfigMap with Squid configuration including SSL Bump settings
- **`deployment.yaml`**: Deployment manifest with init containers for SSL database initialization
- **`kustomization.yaml`**: Kustomize configuration for easy deployment
- **`README.md`**: This file

## Quick Start

### Step 1: Generate SSL Certificates

Run the certificate generation script to create the CA certificate and Kubernetes secrets:

```bash
cd deploy/components/multimedia-downloader/implementations/squid-ssl-bump
./generate-certs.sh
```

This script will:
1. Generate a 4096-bit CA private key
2. Create a CA certificate valid for 10 years
3. Create Kubernetes secret `squid-ssl-certs` (for Squid proxy)
4. Create Kubernetes secret `squid-ca-public-cert` (for client pods)

**Important:** Keep the generated `squid-ssl-certs/squid-ca-key.pem` file secure!

### Step 2: Deploy Squid with SSL Bump

Deploy the Squid proxy with SSL Bump enabled:

```bash
kubectl apply -k deploy/components/multimedia-downloader/implementations/squid-ssl-bump
```

Wait for the pod to be ready:

```bash
kubectl wait --for=condition=ready pod -l cache-implementation=squid-ssl-bump --timeout=120s
```

Check the logs:

```bash
kubectl logs -l cache-implementation=squid-ssl-bump -f
```

### Step 3: Configure Client Pods

To use the Squid SSL Bump proxy, client pods (like vLLM) need to:

1. **Trust the Squid CA certificate**
2. **Set proxy environment variables**

#### Example vLLM Deployment with SSL Bump Support

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm-service
spec:
  template:
    spec:
      initContainers:
      # Install Squid CA certificate to trust store
      - name: install-ca-cert
        image: ubuntu:22.04
        command:
        - /bin/bash
        - -c
        - |
          echo "Installing Squid CA certificate..."
          apt-get update && apt-get install -y ca-certificates
          cp /tmp/squid-ca/squid-ca-cert.pem /usr/local/share/ca-certificates/squid-ca.crt
          update-ca-certificates
          echo "CA certificate installed successfully"
          # Copy to shared volume for main container
          cp -r /etc/ssl/certs/* /shared-certs/
        volumeMounts:
        - name: squid-ca-cert
          mountPath: /tmp/squid-ca
          readOnly: true
        - name: shared-certs
          mountPath: /shared-certs
      
      containers:
      - name: vllm
        image: vllm/vllm-openai:latest
        env:
        # Configure proxy environment variables
        - name: HTTP_PROXY
          value: "http://multimedia-downloader:8080"
        - name: HTTPS_PROXY
          value: "http://multimedia-downloader:8080"
        - name: NO_PROXY
          value: "localhost,127.0.0.1,.svc,.cluster.local"
        # Point to updated CA certificates
        - name: SSL_CERT_DIR
          value: "/etc/ssl/certs"
        - name: REQUESTS_CA_BUNDLE
          value: "/etc/ssl/certs/ca-certificates.crt"
        - name: CURL_CA_BUNDLE
          value: "/etc/ssl/certs/ca-certificates.crt"
        volumeMounts:
        # Mount updated CA certificates from init container
        - name: shared-certs
          mountPath: /etc/ssl/certs
          readOnly: true
      
      volumes:
      # Squid CA certificate (public only)
      - name: squid-ca-cert
        secret:
          secretName: squid-ca-public-cert
      # Shared volume for CA certificates
      - name: shared-certs
        emptyDir: {}
```

## Verification

### Verify SSL Bump is Working

```bash
# Check Squid logs for SSL bump activity
kubectl logs -l cache-implementation=squid-ssl-bump | grep -i "ssl\|bump\|certificate"
```

### Test from Client Pod

```bash
# Get vLLM pod name
VLLM_POD=$(kubectl get pod -l app=vllm -o jsonpath='{.items[0].metadata.name}')

# Test HTTPS connection through proxy
kubectl exec -it $VLLM_POD -- curl -v https://huggingface.co

# Should show:
# * Server certificate:
# *  issuer: CN=Squid Proxy CA  <-- This confirms SSL bump is working
```

### Verify Caching

```bash
# Check Squid access logs for cache status
kubectl logs -l cache-implementation=squid-ssl-bump | grep "TCP_MISS\|TCP_HIT"
# First request: TCP_MISS
# Second request: TCP_HIT or TCP_MEM_HIT
```

## Configuration Details

### SSL Bump Configuration

The Squid configuration includes:

- **SSL Bump Mode**: `ssl-bump` on port 8080
- **Certificate Generation**: Dynamic certificates signed by Squid CA
- **Certificate Cache**: 16MB in-memory cache for generated certificates
- **SSL Database**: Initialized by init container at `/var/lib/squid/ssl_db`

### SSL Bump Decision Logic

```
ssl_bump peek step1   # Peek at client hello to get SNI
ssl_bump stare step2  # Stare at server certificate
ssl_bump bump all     # Bump (decrypt) everything
```

### Caching Configuration

- **Cache Memory**: 2GB RAM cache
- **Max Object Size**: 100GB (for large ML models)
- **Max Object in Memory**: 1GB
- **Refresh Patterns**: Optimized for ML model files (.bin, .safetensors, etc.)

## Troubleshooting

### Issue: SSL Certificate Verification Failed

**Symptom:**
```
SSL certificate problem: unable to get local issuer certificate
```

**Solution:**
```bash
# Verify CA cert is installed in client pod
kubectl exec -it $VLLM_POD -- ls -la /etc/ssl/certs/ | grep squid

# Check if update-ca-certificates ran successfully
kubectl logs $VLLM_POD -c install-ca-cert
```

### Issue: Squid SSL Database Initialization Failed

**Symptom:**
```
security_file_certgen: Cannot create ssl certificate database
```

**Solution:**
```bash
# Check init container logs
kubectl logs -l cache-implementation=squid-ssl-bump -c init-ssl-db

# Restart Squid pod
kubectl rollout restart deployment multimedia-downloader
```

### Issue: Connection Refused

**Symptom:**
```
Failed to connect to multimedia-downloader port 8080: Connection refused
```

**Solution:**
```bash
# Check if Squid service is running
kubectl get pods -l cache-implementation=squid-ssl-bump

# Check Squid logs for errors
kubectl logs -l cache-implementation=squid-ssl-bump --tail=100
```

## Security Considerations

### ⚠️ CRITICAL: Private Key Security

The CA private key (`squid-ca-key.pem`) can be used to impersonate ANY website.

**Best Practices:**
- Store the private key in a Kubernetes Secret with restricted RBAC
- Never commit the private key to version control
- Rotate the CA certificate periodically (e.g., annually)
- Use separate CAs for different environments (dev/staging/prod)

### Sites to Exclude from SSL Bump

Some sites should NOT be decrypted:
- Banking and financial services
- Healthcare portals
- Government sites
- Sites with certificate pinning

To exclude sites, uncomment and customize in `squid-ssl-bump-config.yaml`:

```yaml
acl no_bump_sites ssl::server_name .bank.com
acl no_bump_sites ssl::server_name .healthcare.gov
ssl_bump splice no_bump_sites
```

### Compliance and Legal

⚠️ **WARNING**: SSL Bump may violate:
- Privacy laws (GDPR, CCPA)
- Terms of Service of some websites
- Corporate security policies
- Industry regulations (HIPAA, PCI-DSS)

**Recommendations:**
- Document the use of SSL Bump in your security policy
- Inform users that HTTPS traffic is being intercepted
- Obtain necessary approvals from legal/compliance teams
- Only use in controlled environments (not public proxies)

## Performance Tuning

### Increase SSL Certificate Cache

For high-traffic environments:

```yaml
# In squid-ssl-bump-config.yaml
http_port 8080 ssl-bump \
  dynamic_cert_mem_cache_size=64MB  # Increase from 16MB
```

### Increase Certificate Generation Workers

```yaml
# In squid-ssl-bump-config.yaml
sslcrtd_children 20 startup=10 idle=5  # Increase from 10
```

### Increase Memory Allocation

```yaml
# In deployment.yaml
resources:
  requests:
    memory: "4Gi"  # Increase for SSL operations
    cpu: "1000m"
  limits:
    memory: "8Gi"
    cpu: "4000m"
```

## Rollback

If SSL Bump causes issues, you can quickly rollback:

### Option 1: Switch to Regular Squid (No SSL Bump)

```bash
kubectl apply -k deploy/components/multimedia-downloader/implementations/squid
```

### Option 2: Remove Proxy Entirely

```bash
# Remove proxy environment variables from client pods
kubectl edit deployment vllm-service
# Delete HTTP_PROXY and HTTPS_PROXY env vars
```

## Additional Resources

- [Squid SSL Bump Documentation](https://wiki.squid-cache.org/Features/SslBump)
- [Squid Configuration Reference](http://www.squid-cache.org/Doc/config/)
- [OpenSSL Certificate Management](https://www.openssl.org/docs/man1.1.1/man1/openssl-req.html)
- [Main SQUID-SSL-BUMP.md Guide](../../../../SQUID-SSL-BUMP.md)

## Summary Checklist

- [ ] Generated CA certificate and private key (`./generate-certs.sh`)
- [ ] Created Kubernetes secrets (squid-ssl-certs, squid-ca-public-cert)
- [ ] Deployed Squid with SSL Bump (`kubectl apply -k .`)
- [ ] Configured client pods to trust Squid CA
- [ ] Verified SSL Bump is working (check certificate issuer)
- [ ] Tested caching (TCP_HIT in logs)
- [ ] Reviewed security considerations
- [ ] Documented the deployment for your team
- [ ] Set up monitoring and alerts

---

**Last Updated:** 2026-04-09  
**Version:** 1.0