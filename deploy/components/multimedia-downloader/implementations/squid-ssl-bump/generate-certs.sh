#!/bin/bash
# Script to generate SSL certificates for Squid SSL Bump
# This script creates a Certificate Authority (CA) for Squid to use when intercepting HTTPS traffic

set -e

# Configuration
CERT_DIR="squid-ssl-certs"
CA_KEY="squid-ca-key.pem"
CA_CERT="squid-ca-cert.pem"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Squid SSL Bump Certificate Generation ===${NC}"
echo ""

# Create directory for certificates
echo -e "${YELLOW}Creating certificate directory...${NC}"
mkdir -p "$CERT_DIR"
cd "$CERT_DIR"

# Generate CA private key (4096-bit for security)
echo -e "${YELLOW}Generating CA private key (4096-bit)...${NC}"
openssl genrsa -out "$CA_KEY" 4096

# Generate CA certificate (valid for 10 years)
echo -e "${YELLOW}Generating CA certificate (valid for 10 years)...${NC}"
openssl req -new -x509 -days 3650 \
  -key "$CA_KEY" \
  -out "$CA_CERT" \
  -subj "/C=US/ST=State/L=City/O=YourOrganization/OU=IT/CN=Squid Proxy CA"

# Verify certificates
echo -e "${YELLOW}Verifying certificates...${NC}"
echo "CA Certificate Details:"
openssl x509 -in "$CA_CERT" -text -noout | grep -E "Subject:|Issuer:|Not Before|Not After"

echo ""
echo -e "${YELLOW}Verifying key and cert match...${NC}"
KEY_MD5=$(openssl rsa -noout -modulus -in "$CA_KEY" | openssl md5)
CERT_MD5=$(openssl x509 -noout -modulus -in "$CA_CERT" | openssl md5)

if [ "$KEY_MD5" = "$CERT_MD5" ]; then
    echo -e "${GREEN}✓ Key and certificate match${NC}"
else
    echo -e "${RED}✗ Key and certificate do NOT match!${NC}"
    exit 1
fi

cd ..

echo ""
echo -e "${GREEN}=== Creating Kubernetes Secrets ===${NC}"

# Create secret for Squid Proxy (with private key)
echo -e "${YELLOW}Creating secret 'squid-ssl-certs' for Squid proxy...${NC}"
kubectl create secret generic squid-ssl-certs \
  --from-file="$CERT_DIR/$CA_CERT" \
  --from-file="$CERT_DIR/$CA_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

# Create secret for vLLM Clients (public cert only)
echo -e "${YELLOW}Creating secret 'squid-ca-public-cert' for client pods...${NC}"
kubectl create secret generic squid-ca-public-cert \
  --from-file="$CERT_DIR/$CA_CERT" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo -e "${GREEN}=== Verification ===${NC}"
kubectl get secret squid-ssl-certs -o jsonpath='{.data}' | jq 'keys'
kubectl get secret squid-ca-public-cert -o jsonpath='{.data}' | jq 'keys'

echo ""
echo -e "${GREEN}=== Certificate Generation Complete ===${NC}"
echo -e "${YELLOW}IMPORTANT SECURITY NOTES:${NC}"
echo -e "${RED}1. Keep $CERT_DIR/$CA_KEY SECURE! Anyone with this key can impersonate any website.${NC}"
echo -e "${RED}2. Never commit the private key to version control.${NC}"
echo -e "${YELLOW}3. The CA certificate is valid for 10 years.${NC}"
echo -e "${YELLOW}4. Rotate certificates periodically for security.${NC}"
echo ""
echo -e "${GREEN}Next steps:${NC}"
echo "1. Apply the squid-ssl-bump deployment: kubectl apply -k deploy/components/multimedia-downloader/implementations/squid-ssl-bump"
echo "2. Configure your vLLM pods to trust the Squid CA certificate"
echo "3. Set HTTP_PROXY and HTTPS_PROXY environment variables in client pods"
echo ""

# Made with Bob
