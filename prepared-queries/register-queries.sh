#!/usr/bin/env bash
# Register prepared queries on Consul servers.
#
# Scenarios covered:
#   DC3  — product-api-geo (DC3 primary → DC4 peer failover). Scenarios A, B.
#   DC4  — product-api-geo (DC4 primary → DC3 peer failover). Scenarios A, B.
#   DC5  — product-api-hybrid (dc5-k8s primary → DC4 peer failover). Scenario D.
#          Registered in the dc5-k8s admin partition via X-Consul-Partition header.
#
# Usage:
#   # On DC3 server:
#   bash register-queries.sh
#
#   # On DC4 server:
#   CONSUL_HTTP_ADDR=http://<DC4_SERVER_IP>:8500 DC=dc4 bash register-queries.sh
#
#   # For DC5 partition (after consul-k8s is up, using DC3 as the control plane):
#   CONSUL_HTTP_ADDR=http://<DC3_SERVER_IP>:8500 DC=dc5 bash register-queries.sh
#
# Env:
#   CONSUL_HTTP_ADDR   Consul HTTP endpoint (default: http://127.0.0.1:8500)
#   DC                 Which DC to register for: dc3 (default), dc4, or dc5
set -euo pipefail

CONSUL_ADDR="${CONSUL_HTTP_ADDR:-http://127.0.0.1:8500}"
DC="${DC:-dc3}"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

register_query() {
  local file="$1"
  local extra_headers="${2:-}"
  local name
  name=$(python3 -c "import json,sys; print(json.load(open('$file'))['Name'])")
  echo "  Registering: ${name} (from ${file##*/})"
  # shellcheck disable=SC2086
  curl -fsS -X POST "${CONSUL_ADDR}/v1/query" \
    -H "Content-Type: application/json" \
    ${extra_headers} \
    -d @"${file}"
  echo ""
}

echo "==> Registering prepared queries on ${CONSUL_ADDR} (DC=${DC})"

if [[ "${DC}" == "dc4" ]]; then
  # DC4: geo query prefers DC4-local instances, peers to DC3 on failure
  register_query "${SCRIPT_DIR}/product-api-geo-dc4.json"

elif [[ "${DC}" == "dc5" ]]; then
  # DC5 (dc5-k8s partition of dc3-vm): hybrid query targeting K8s product-api
  # with fallback to DC4 peer. Registered under X-Consul-Partition: dc5-k8s.
  register_query "${SCRIPT_DIR}/product-api-hybrid.json" \
    '-H "X-Consul-Partition: dc5-k8s"'

else
  # DC3 (default): geo query prefers DC3-local instances, peers to DC4 on failure
  register_query "${SCRIPT_DIR}/product-api-geo-failover.json"
  register_query "${SCRIPT_DIR}/product-api-local-only.json"
fi

echo "==> Done. Verify:"
echo "  curl -s ${CONSUL_ADDR}/v1/query | python3 -m json.tool"
echo ""
echo "DNS (from a node with Consul DNS on :8600):"
echo "  dig @127.0.0.1 -p 8600 product-api-geo.query.consul. SRV +short"
echo ""
if [[ "${DC}" == "dc3" ]]; then
  echo "Next steps:"
  echo "  Register on DC4: CONSUL_HTTP_ADDR=http://<DC4_IP>:8500 DC=dc4 bash register-queries.sh"
  echo "  Register on DC5: CONSUL_HTTP_ADDR=http://<DC3_IP>:8500 DC=dc5 bash register-queries.sh"
fi
