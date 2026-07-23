#!/usr/bin/env bash
# DC3: run on the frontend VM.
# HASHICUPS_PUBLIC_API_URL: set in /etc/hashicups.env if browser needs a reachable URL.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/lib.sh"

test -f /etc/hashicups.env && source /etc/hashicups.env
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || hostname -I | awk '{print $1}')
# NEXT_PUBLIC_PUBLIC_API_HOST is baked into the browser bundle, so it must be an address
# the browser can reach. Point it at THIS VM's public IP on the public-api upstream port;
# the sidecar upstream below binds 0.0.0.0:18080, so browser traffic still flows through
# Connect mTLS to public-api. Override with HASHICUPS_PUBLIC_API_URL in /etc/hashicups.env.
API_BASE="${HASHICUPS_PUBLIC_API_URL:-http://${PUBLIC_IP}:18080}"

docker rm -f frontend 2>/dev/null || true
# --network host (canonical pattern): reach public-api Connect upstream on localhost.
docker run -d --name frontend --restart unless-stopped \
  --network host \
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
          destination_name   = "public-api"
          local_bind_address = "0.0.0.0"
          local_bind_port    = 18080
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
