#!/usr/bin/env bash
# DC4: run on each product-api VM (product-api-1, -2, -3). No Consul agent.
# Usage: bash on-product-api.sh <POSTGRES_PRIVATE_IP>
# POSTGRES_PRIVATE_IP: DC4 postgres VM private IP (Terraform output hashicups_private_ips["postgres"]).
set -euo pipefail

POSTGRES_IP="${1:?Usage: $0 <POSTGRES_PRIVATE_IP>}"

install -d -m 0755 /opt/hashicups
cat >/opt/hashicups/product-api-config.json <<EOF
{
  "db_connection": "host=${POSTGRES_IP} port=5432 user=postgres password=password dbname=products sslmode=disable",
  "bind_address": "0.0.0.0:9090",
  "metrics_address": "0.0.0.0:9091"
}
EOF

docker rm -f product-api 2>/dev/null || true
docker run -d --name product-api --restart unless-stopped \
  -p 9090:9090 \
  -v /opt/hashicups/product-api-config.json:/config/config.json:ro \
  -e CONFIG_FILE=/config/config.json \
  hashicorpdemoapp/product-api:v4280cf7

echo "product-api started on :9090 (dc4-esm, postgres: ${POSTGRES_IP}) — ESM health-checks externally"
