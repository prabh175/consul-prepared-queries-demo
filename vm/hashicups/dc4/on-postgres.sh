#!/usr/bin/env bash
# DC4: run on the postgres VM. No Consul agent. Direct TCP only.
set -euo pipefail

docker rm -f postgres 2>/dev/null || true
docker run -d --name postgres --restart unless-stopped \
  -p 5432:5432 \
  -e POSTGRES_DB=products \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=password \
  hashicorpdemoapp/product-api-db:v4280cf7

echo "postgres started on :5432 (dc4-esm, no Consul agent — ESM health-checks externally)"
