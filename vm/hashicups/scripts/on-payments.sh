#!/usr/bin/env bash
# DC3: run on the payments VM.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/lib.sh"

docker rm -f payments 2>/dev/null || true
# --network host (canonical pattern)
docker run -d --name payments --restart unless-stopped \
  --network host \
  -e BIND_ADDRESS=0.0.0.0:8080 \
  hashicorpdemoapp/payments:latest

sleep 3

tmp=$(mktemp --suffix=.hcl)
tee "${tmp}" >/dev/null <<'EOF'
service {
  name = "payments"
  port = 8080
  tags = ["dc3"]
  connect { sidecar_service {} }
  check {
    tcp      = "127.0.0.1:8080"
    interval = "10s"
  }
}
EOF
reregister_connect_service payments "${tmp}"
echo "payments registered (dc3-vm)"
