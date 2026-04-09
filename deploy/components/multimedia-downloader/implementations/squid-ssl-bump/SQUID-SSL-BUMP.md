# Squid SSL Bump Implementation Guide for vLLM

This guide provides step-by-step instructions to enable SSL Bump in Squid proxy to intercept and cache HTTPS traffic from vLLM pods downloading ML models from Hugging Face.

## Table of Contents
- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Step 1: Generate SSL Certificates](#step-1-generate-ssl-certificates)
- [Step 2: Create Kubernetes Secrets](#step-2-create-kubernetes-secrets)
- [Step 3: Update Squid Configuration](#step-3-update-squid-configuration)
- [Step 4: Update Squid Deployment](#step-4-update-squid-deployment)
- [Step 5: Configure vLLM Client Pods](#step-5-configure-vllm-client-pods)
- [Step 6: Verification](#step-6-verification)
- [Troubleshooting](#troubleshooting)
- [Security Considerations](#security-considerations)

---

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

---

## Prerequisites

- Kubernetes cluster with Squid proxy deployed
- `kubectl` access to the cluster
- OpenSSL installed locally for certificate generation
- Understanding that SSL Bump is a man-in-the-middle technique

---

## Step 1: Generate SSL Certificates

### 1.1 Create Certificate Authority (CA)

On your local machine or a secure environment:

```bash
# Create directory for certificates
mkdir -p squid-ssl-certs
cd squid-ssl-certs

# Generate CA private key (4096-bit for security)
openssl genrsa -out squid-ca-key.pem 4096

# Generate CA certificate (valid for 10 years)
openssl req -new -x509 -days 3650 \
  -key squid-ca-key.pem \
  -out squid-ca-cert.pem \
  -subj "/C=US/ST=State/L=City/O=YourOrganization/OU=IT/CN=Squid Proxy CA"
```

**Important:** Keep `squid-ca-key.pem` secure! Anyone with this key can impersonate any website.

### 1.2 Verify Certificates

```bash
# Check CA certificate details
openssl x509 -in squid-ca-cert.pem -text -noout

# Verify key and cert match
openssl x509 -noout -modulus -in squid-ca-cert.pem | openssl md5
openssl rsa -noout -modulus -in squid-ca-key.pem | openssl md5
# The MD5 hashes should match
```

---

## Step 2: Create Kubernetes Secrets

### 2.1 Create Secret for Squid Proxy (with private key)

```bash
# Create secret containing both CA cert and private key for Squid
kubectl create secret generic squid-ssl-certs \
  --from-file=squid-ca-cert.pem=squid-ca-cert.pem \
  --from-file=squid-ca-key.pem=squid-ca-key.pem \
  -n default

# Verify secret creation
kubectl get secret squid-ssl-certs -n default
```

### 2.2 Create Secret for vLLM Clients (public cert only)

```bash
# Create secret containing only the public CA certificate for clients
kubectl create secret generic squid-ca-public-cert \
  --from-file=squid-ca-cert.pem=squid-ca-cert.pem \
  -n default

# Verify secret creation
kubectl get secret squid-ca-public-cert -n default
```

---

## Step 3: Update Squid Configuration

### 3.1 Update ConfigMap

Edit your `config-map.yaml` to add SSL Bump configuration:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: squid-config
  namespace: default
data:
  squid.conf: |-
    # Listen on 8080 with SSL Bump enabled
    http_port 8080 ssl-bump \
      cert=/etc/squid/certs/squid-ca-cert.pem \
      key=/etc/squid/certs/squid-ca-key.pem \
      generate-host-certificates=on \
      dynamic_cert_mem_cache_size=16MB

    # --- PID File Configuration ---
    pid_filename /var/cache/squid/squid.pid
    netdb_filename none

    # --- SSL Certificate Generation ---
    sslcrtd_program /usr/lib/squid/security_file_certgen -s /var/lib/squid/ssl_db -M 16MB
    sslcrtd_children 10 startup=5 idle=1

    # --- SSL Bump ACLs and Rules ---
    # Define SSL bump steps
    acl step1 at_step SslBump1
    acl step2 at_step SslBump2
    acl step3 at_step SslBump3

    # Optional: Define sites to NOT decrypt (splice instead of bump)
    # Uncomment and customize if needed for sensitive sites
    # acl no_bump_sites ssl::server_name .bank.com .healthcare.gov
    # acl no_bump_sites ssl::server_name .your-sensitive-site.com

    # SSL Bump decision logic
    ssl_bump peek step1              # Peek at client hello to get SNI
    # ssl_bump splice no_bump_sites  # Uncomment to bypass sensitive sites
    ssl_bump stare step2             # Stare at server certificate
    ssl_bump bump all                # Bump (decrypt) everything else

    # --- Timeout Configuration ---
    connect_timeout 30 seconds
    read_timeout 300 seconds
    request_timeout 300 seconds
    persistent_request_timeout 300 seconds
    client_lifetime 1 hour
    peer_connect_timeout 30 seconds
    forward_timeout 300 seconds

    # --- Storage Configuration ---
    cache_dir null /tmp
    cache_mem 2048 MB
    maximum_object_size_in_memory 1024 MB

    # --- Memory Optimization ---
    fqdncache_size 100
    ipcache_size 100
    memory_pools off

    # --- Large Object Support ---
    maximum_object_size 100 GB
    minimum_object_size 0 KB

    # --- HTTP-Compliant Caching for Models ---
    # Cache ML model files and images with long freshness times
    refresh_pattern -i \.(bin|safetensors|gguf|pt|pth|onnx|msgpack|json|yaml|txt)$ 10080 100% 43200 store-stale
    refresh_pattern -i \.(jpg|jpeg|png|gif|webp|bmp|tiff)$ 10080 100% 43200 store-stale
    refresh_pattern . 0 20% 4320 store-stale

    # --- Access Control ---
    acl CONNECT method CONNECT
    http_access allow localhost
    http_access allow CONNECT
    http_access allow all

    # --- Logging ---
    logformat cache_status %>a %[ui %[un [%tl] "%rm %ru HTTP/%rv" %>Hs %<st "%{Referer}>h" "%{User-Agent}>h" %Ss:%Sh
    access_log stdio:/dev/stdout cache_status
    cache_log /var/cache/squid/cache.log

    # --- Performance ---
    collapsed_forwarding on

    # --- DNS ---
    dns_nameservers 8.8.8.8 8.8.4.4
```

### 3.2 Apply ConfigMap

```bash
kubectl apply -f config-map.yaml
```

---

## Step 4: Update Squid Deployment

### 4.1 Create/Update Squid Deployment

Create `squid-deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: squid-proxy
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: squid-proxy
  template:
    metadata:
      labels:
        app: squid-proxy
    spec:
      initContainers:
      # Initialize SSL certificate database
      - name: init-ssl-db
        image: ubuntu/squid:latest
        command:
        - /bin/sh
        - -c
        - |
          if [ ! -d /var/lib/squid/ssl_db ]; then
            echo "Initializing SSL certificate database..."
            /usr/lib/squid/security_file_certgen -c -s /var/lib/squid/ssl_db -M 16MB
            chown -R proxy:proxy /var/lib/squid/ssl_db
          else
            echo "SSL certificate database already exists"
          fi
        volumeMounts:
        - name: ssl-db
          mountPath: /var/lib/squid/ssl_db
      
      containers:
      - name: squid
        image: ubuntu/squid:latest
        ports:
        - containerPort: 8080
          name: http-proxy
        volumeMounts:
        # Mount Squid configuration
        - name: squid-config
          mountPath: /etc/squid/squid.conf
          subPath: squid.conf
        # Mount SSL certificates (CA cert + private key)
        - name: ssl-certs
          mountPath: /etc/squid/certs
          readOnly: true
        # Mount SSL certificate database
        - name: ssl-db
          mountPath: /var/lib/squid/ssl_db
        # Mount cache directory
        - name: cache
          mountPath: /var/cache/squid
        resources:
          requests:
            memory: "2Gi"
            cpu: "500m"
          limits:
            memory: "4Gi"
            cpu: "2000m"
        livenessProbe:
          tcpSocket:
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          tcpSocket:
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 5
      
      volumes:
      # Squid configuration from ConfigMap
      - name: squid-config
        configMap:
          name: squid-config
      # SSL certificates secret (contains CA cert + private key)
      - name: ssl-certs
        secret:
          secretName: squid-ssl-certs
      # SSL certificate database (ephemeral)
      - name: ssl-db
        emptyDir: {}
      # Cache directory (ephemeral)
      - name: cache
        emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: squid-service
  namespace: default
spec:
  selector:
    app: squid-proxy
  ports:
  - port: 8080
    targetPort: 8080
    name: http-proxy
  type: ClusterIP
```

### 4.2 Apply Deployment

```bash
kubectl apply -f squid-deployment.yaml

# Wait for pod to be ready
kubectl wait --for=condition=ready pod -l app=squid-proxy --timeout=120s

# Check logs
kubectl logs -l app=squid-proxy -f
```

---

## Step 5: Configure vLLM Client Pods

### 5.1 Create vLLM Deployment with CA Trust

Create `vllm-deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm-service
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vllm
  template:
    metadata:
      labels:
        app: vllm
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
          value: "http://squid-service:8080"
        - name: HTTPS_PROXY
          value: "http://squid-service:8080"
        - name: NO_PROXY
          value: "localhost,127.0.0.1,.svc,.cluster.local"
        # Point to updated CA certificates
        - name: SSL_CERT_DIR
          value: "/etc/ssl/certs"
        - name: REQUESTS_CA_BUNDLE
          value: "/etc/ssl/certs/ca-certificates.crt"
        - name: CURL_CA_BUNDLE
          value: "/etc/ssl/certs/ca-certificates.crt"
        # vLLM specific configuration
        - name: HF_HOME
          value: "/data/huggingface"
        ports:
        - containerPort: 8000
          name: http
        volumeMounts:
        # Mount updated CA certificates from init container
        - name: shared-certs
          mountPath: /etc/ssl/certs
          readOnly: true
        # Mount for model cache
        - name: model-cache
          mountPath: /data/huggingface
        resources:
          requests:
            memory: "8Gi"
            cpu: "2000m"
          limits:
            memory: "16Gi"
            cpu: "4000m"
      
      volumes:
      # Squid CA certificate (public only)
      - name: squid-ca-cert
        secret:
          secretName: squid-ca-public-cert
      # Shared volume for CA certificates
      - name: shared-certs
        emptyDir: {}
      # Model cache
      - name: model-cache
        emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: vllm-service
  namespace: default
spec:
  selector:
    app: vllm
  ports:
  - port: 8000
    targetPort: 8000
    name: http
  type: ClusterIP
```

### 5.2 Apply vLLM Deployment

```bash
kubectl apply -f vllm-deployment.yaml

# Wait for pod to be ready
kubectl wait --for=condition=ready pod -l app=vllm --timeout=300s

# Check logs
kubectl logs -l app=vllm -f
```

---

## Step 6: Verification

### 6.1 Verify Squid SSL Bump is Working

```bash
# Check Squid logs for SSL bump activity
kubectl logs -l app=squid-proxy | grep -i "ssl\|bump\|certificate"

# You should see entries like:
# "SSL negotiation with client"
# "Generating SSL certificate for..."
```

### 6.2 Test from vLLM Pod

```bash
# Get vLLM pod name
VLLM_POD=$(kubectl get pod -l app=vllm -o jsonpath='{.items[0].metadata.name}')

# Test HTTPS connection through proxy
kubectl exec -it $VLLM_POD -- curl -v https://huggingface.co

# Should show:
# * Connected to squid-service (10.x.x.x) port 8080
# * Server certificate:
# *  subject: CN=huggingface.co
# *  issuer: CN=Squid Proxy CA  <-- This confirms SSL bump is working
```

### 6.3 Verify Caching

```bash
# Download a model file twice and check cache hits
kubectl exec -it $VLLM_POD -- bash -c '
  # First download (should be MISS)
  curl -x http://squid-service:8080 -o /tmp/test1.bin \
    https://huggingface.co/some-model/resolve/main/model.bin
  
  # Second download (should be HIT)
  curl -x http://squid-service:8080 -o /tmp/test2.bin \
    https://huggingface.co/some-model/resolve/main/model.bin
'

# Check Squid access logs for cache status
kubectl logs -l app=squid-proxy | grep "TCP_MISS\|TCP_HIT"
# First request: TCP_MISS
# Second request: TCP_HIT or TCP_MEM_HIT
```

### 6.4 Monitor Cache Statistics

```bash
# Get cache statistics
kubectl exec -it $(kubectl get pod -l app=squid-proxy -o jsonpath='{.items[0].metadata.name}') \
  -- squidclient -h localhost -p 8080 mgr:info | grep -A 20 "Cache information"
```

---

## Troubleshooting

### Issue 1: SSL Certificate Verification Failed

**Symptom:**
```
SSL certificate problem: unable to get local issuer certificate
```

**Solution:**
```bash
# Verify CA cert is installed in vLLM pod
kubectl exec -it $VLLM_POD -- ls -la /etc/ssl/certs/ | grep squid

# Check if update-ca-certificates ran successfully
kubectl logs $VLLM_POD -c install-ca-cert

# Manually test certificate trust
kubectl exec -it $VLLM_POD -- openssl s_client -connect huggingface.co:443 \
  -proxy squid-service:8080 -showcerts
```

### Issue 2: Squid SSL Database Initialization Failed

**Symptom:**
```
security_file_certgen: Cannot create ssl certificate database
```

**Solution:**
```bash
# Check init container logs
kubectl logs -l app=squid-proxy -c init-ssl-db

# Manually initialize if needed
kubectl exec -it $(kubectl get pod -l app=squid-proxy -o jsonpath='{.items[0].metadata.name}') \
  -- /usr/lib/squid/security_file_certgen -c -s /var/lib/squid/ssl_db -M 16MB

# Restart Squid pod
kubectl rollout restart deployment squid-proxy
```

### Issue 3: Connection Refused or Timeout

**Symptom:**
```
Failed to connect to squid-service port 8080: Connection refused
```

**Solution:**
```bash
# Check if Squid service is running
kubectl get svc squid-service
kubectl get pods -l app=squid-proxy

# Check Squid logs for errors
kubectl logs -l app=squid-proxy --tail=100

# Test connectivity from vLLM pod
kubectl exec -it $VLLM_POD -- nc -zv squid-service 8080
```

### Issue 4: Certificate Mismatch

**Symptom:**
```
SSL: certificate subject name 'huggingface.co' does not match target host name
```

**Solution:**
```bash
# Verify Squid is generating certificates correctly
kubectl logs -l app=squid-proxy | grep "Generating SSL certificate"

# Check dynamic_cert_mem_cache_size is sufficient
kubectl exec -it $(kubectl get pod -l app=squid-proxy -o jsonpath='{.items[0].metadata.name}') \
  -- grep "dynamic_cert_mem_cache_size" /etc/squid/squid.conf
```

### Issue 5: Python/Requests Not Using Proxy

**Symptom:**
vLLM downloads bypass proxy

**Solution:**
```bash
# Verify environment variables in vLLM pod
kubectl exec -it $VLLM_POD -- env | grep -i proxy

# Test with Python
kubectl exec -it $VLLM_POD -- python3 -c "
import os
import requests
print('HTTP_PROXY:', os.environ.get('HTTP_PROXY'))
print('HTTPS_PROXY:', os.environ.get('HTTPS_PROXY'))
response = requests.get('https://huggingface.co')
print('Status:', response.status_code)
"
```

---

## Security Considerations

### 1. **Private Key Security**

⚠️ **CRITICAL**: The CA private key (`squid-ca-key.pem`) can be used to impersonate ANY website.

**Best Practices:**
- Store the private key in a Kubernetes Secret with restricted RBAC
- Never commit the private key to version control
- Rotate the CA certificate periodically (e.g., annually)
- Use separate CAs for different environments (dev/staging/prod)

```bash
# Restrict secret access with RBAC
kubectl create role squid-secret-reader \
  --verb=get --resource=secrets --resource-name=squid-ssl-certs

kubectl create rolebinding squid-secret-binding \
  --role=squid-secret-reader \
  --serviceaccount=default:squid-service-account
```

### 2. **Sites to Exclude from SSL Bump**

Some sites should NOT be decrypted:
- Banking and financial services
- Healthcare portals
- Government sites
- Sites with certificate pinning

**Update squid.conf:**
```yaml
acl no_bump_sites ssl::server_name .bank.com
acl no_bump_sites ssl::server_name .healthcare.gov
acl no_bump_sites ssl::server_name .irs.gov
ssl_bump splice no_bump_sites
```

### 3. **Compliance and Legal**

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

### 4. **Certificate Transparency**

Modern browsers check Certificate Transparency logs. Squid-generated certificates won't appear in CT logs, which may trigger warnings in some browsers.

**Mitigation:**
- Use SSL Bump only for automated clients (like vLLM), not web browsers
- Configure applications to trust your CA explicitly
- Consider using a proper CA for production environments

### 5. **Monitoring and Auditing**

```bash
# Enable detailed SSL logging in squid.conf
debug_options ALL,1 33,2 83,3

# Monitor for suspicious activity
kubectl logs -l app=squid-proxy | grep -i "error\|fail\|denied"

# Set up alerts for certificate generation failures
```

---

## Performance Tuning

### 1. **SSL Certificate Cache**

Increase cache size for high-traffic environments:

```yaml
# In squid.conf
http_port 8080 ssl-bump \
  dynamic_cert_mem_cache_size=64MB  # Increase from 16MB
```

### 2. **Certificate Generation Workers**

Increase workers for better performance:

```yaml
# In squid.conf
sslcrtd_children 20 startup=10 idle=5  # Increase from 10
```

### 3. **Memory Allocation**

```yaml
# In squid-deployment.yaml
resources:
  requests:
    memory: "4Gi"  # Increase for SSL operations
    cpu: "1000m"
  limits:
    memory: "8Gi"
    cpu: "4000m"
```

---

## Rollback Plan

If SSL Bump causes issues, you can quickly rollback:

### Option 1: Disable SSL Bump (Keep Proxy)

```bash
# Update ConfigMap to remove ssl-bump
kubectl edit configmap squid-config

# Change:
# http_port 8080 ssl-bump ...
# To:
# http_port 8080

# Restart Squid
kubectl rollout restart deployment squid-proxy
```

### Option 2: Remove Proxy Entirely

```bash
# Remove proxy environment variables from vLLM
kubectl edit deployment vllm-service
# Delete HTTP_PROXY and HTTPS_PROXY env vars

# Restart vLLM
kubectl rollout restart deployment vllm-service
```

---

## Additional Resources

- [Squid SSL Bump Documentation](https://wiki.squid-cache.org/Features/SslBump)
- [Squid Configuration Reference](http://www.squid-cache.org/Doc/config/)
- [OpenSSL Certificate Management](https://www.openssl.org/docs/man1.1.1/man1/openssl-req.html)
- [Kubernetes Secrets Best Practices](https://kubernetes.io/docs/concepts/configuration/secret/)

---

## Summary Checklist

- [ ] Generated CA certificate and private key
- [ ] Created Kubernetes secrets (squid-ssl-certs, squid-ca-public-cert)
- [ ] Updated Squid ConfigMap with SSL Bump configuration
- [ ] Deployed Squid with SSL certificate mounts
- [ ] Configured vLLM pods to trust Squid CA
- [ ] Verified SSL Bump is working (check certificate issuer)
- [ ] Tested caching (TCP_HIT in logs)
- [ ] Reviewed security considerations
- [ ] Documented the deployment for your team
- [ ] Set up monitoring and alerts

---

**Last Updated:** 2026-04-09
**Version:** 1.0