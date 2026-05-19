#!/usr/bin/env bash
# DC4: run on the public-api VM. No Consul agent. Direct IP connections.
# Usage: bash on-public-api.sh <PRODUCT_API_PRIVATE_IP> <PAYMENTS_PRIVATE_IP>
# Use any one product-api IP (e.g. product-api-1). For demo purposes single upstream is fine.
set -euo pipefail

PRODUCT_API_IP="${1:?Usage: $0 <PRODUCT_API_IP> <PAYMENTS_IP>}"
PAYMENTS_IP="${2:?Usage: $0 <PRODUCT_API_IP> <PAYMENTS_IP>}"

docker rm -f public-api 2>/dev/null || true
docker run -d --name public-api --restart unless-stopped \
  -p 8080:8080 \
  -e BIND_ADDRESS=0.0.0.0:8080 \
  -e PRODUCT_API_URI="http://${PRODUCT_API_IP}:9090" \
  -e PAYMENT_API_URI="http://${PAYMENTS_IP}:8080" \
  hashicorpdemoapp/public-api:v0.0.7

echo "public-api started on :8080 (dc4-esm, product-api: ${PRODUCT_API_IP}, payments: ${PAYMENTS_IP})"
