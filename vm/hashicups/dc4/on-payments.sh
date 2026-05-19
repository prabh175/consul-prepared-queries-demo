#!/usr/bin/env bash
# DC4: run on the payments VM. No Consul agent.
set -euo pipefail

docker rm -f payments 2>/dev/null || true
docker run -d --name payments --restart unless-stopped \
  -p 8080:8080 \
  -e BIND_ADDRESS=0.0.0.0:8080 \
  hashicorpdemoapp/payments:latest

echo "payments started on :8080 (dc4-esm, no Consul agent)"
