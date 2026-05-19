#!/usr/bin/env bash
# DC4: run on the frontend VM. No Consul agent. Direct IP to public-api.
# Usage: bash on-frontend.sh <PUBLIC_API_PRIVATE_IP>
set -euo pipefail

PUBLIC_API_IP="${1:?Usage: $0 <PUBLIC_API_IP>}"

docker rm -f frontend 2>/dev/null || true
docker run -d --name frontend --restart unless-stopped \
  -p 80:80 \
  -e NEXT_PUBLIC_PUBLIC_API_HOST="http://${PUBLIC_API_IP}:8080" \
  hashicorpdemoapp/frontend:latest

echo "frontend started on :80 (dc4-esm, public-api: ${PUBLIC_API_IP})"
