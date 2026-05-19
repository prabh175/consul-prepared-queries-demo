#!/usr/bin/env bash
# DC3: run on each product-api VM (product-api-1, -2, -3).
# All three register as service "product-api" — Consul tracks them as separate instances.
# Upstream: postgres via Connect sidecar on host.docker.internal:15432.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/lib.sh"

install -d -m 0755 /opt/hashicups
cat >/opt/hashicups/product-api-config.json <<'EOF'
{
  "db_connection": "host=host.docker.internal port=15432 user=postgres password=password dbname=products sslmode=disable"
}
EOF

docker rm -f product-api 2>/dev/null || true
docker run -d --name product-api --restart unless-stopped \
  "${DNS_FLAGS[@]}" \
  "${DOCKER_HOST_GATEWAY_FLAGS[@]}" \
  -p 9090:9090 \
  -v /opt/hashicups/product-api-config.json:/config/config.json:ro \
  -e CONFIG_FILE=/config/config.json \
  hashicorpdemoapp/product-api:v4280cf7

sleep 3

tmp=$(mktemp --suffix=.hcl)
tee "${tmp}" >/dev/null <<'EOF'
service {
  name = "product-api"
  port = 9090
  tags = ["dc3", "v1"]
  connect {
    sidecar_service {
      proxy {
        upstreams = [{
          destination_name = "postgres"
          local_bind_port  = 15432
        }]
      }
    }
  }
  check {
    tcp      = "127.0.0.1:9090"
    interval = "10s"
  }
}
EOF
reregister_connect_service product-api "${tmp}"
echo "product-api registered (dc3-vm) — this instance: $(hostname -s)"
