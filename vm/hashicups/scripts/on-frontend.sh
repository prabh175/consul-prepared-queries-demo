#!/usr/bin/env bash
# DC3: run on the frontend VM.
# HASHICUPS_PUBLIC_API_URL: set in /etc/hashicups.env if browser needs a reachable URL.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/lib.sh"

test -f /etc/hashicups.env && source /etc/hashicups.env
API_BASE="${HASHICUPS_PUBLIC_API_URL:-http://host.docker.internal:18080}"

docker rm -f frontend 2>/dev/null || true
docker run -d --name frontend --restart unless-stopped \
  "${DNS_FLAGS[@]}" \
  "${DOCKER_HOST_GATEWAY_FLAGS[@]}" \
  -p 80:80 \
  -e NEXT_PUBLIC_PUBLIC_API_HOST="${API_BASE}" \
  hashicorpdemoapp/frontend:latest

sleep 3

tmp=$(mktemp --suffix=.hcl)
tee "${tmp}" >/dev/null <<'EOF'
service {
  name = "frontend"
  port = 80
  tags = ["dc3"]
  connect {
    sidecar_service {
      proxy {
        upstreams = [{
          destination_name = "public-api"
          local_bind_port  = 18080
        }]
      }
    }
  }
  check {
    tcp      = "127.0.0.1:80"
    interval = "10s"
  }
}
EOF
reregister_connect_service frontend "${tmp}"
echo "frontend registered (dc3-vm) — UI: http://$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || hostname -I | awk '{print $1}')"
