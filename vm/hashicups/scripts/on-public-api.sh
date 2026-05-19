#!/usr/bin/env bash
# DC3: run on the public-api VM.
# Calls product-api and payments via Connect upstreams.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/lib.sh"

docker rm -f public-api 2>/dev/null || true
docker run -d --name public-api --restart unless-stopped \
  "${DNS_FLAGS[@]}" \
  "${DOCKER_HOST_GATEWAY_FLAGS[@]}" \
  -p 8080:8080 \
  -e BIND_ADDRESS=0.0.0.0:8080 \
  -e PRODUCT_API_URI="http://host.docker.internal:19090" \
  -e PAYMENT_API_URI="http://host.docker.internal:19091" \
  hashicorpdemoapp/public-api:v0.0.7

sleep 3

tmp=$(mktemp --suffix=.hcl)
tee "${tmp}" >/dev/null <<'EOF'
service {
  name = "public-api"
  port = 8080
  tags = ["dc3"]
  connect {
    sidecar_service {
      proxy {
        upstreams = [
          {
            destination_name = "product-api"
            local_bind_port  = 19090
          },
          {
            destination_name = "payments"
            local_bind_port  = 19091
          }
        ]
      }
    }
  }
  check {
    tcp      = "127.0.0.1:8080"
    interval = "10s"
  }
}
EOF
reregister_connect_service public-api "${tmp}"
echo "public-api registered (dc3-vm)"
