#!/usr/bin/env bash
# Register DC4 HashiCups VMs as external nodes in the dc4-esm Consul catalog.
# Run from the DC4 consul-server after all service VMs are up.
#
# Usage:
#   bash register-dc4-services.sh \
#     --postgres      <IP> \
#     --product-api-1 <IP> \
#     --product-api-2 <IP> \
#     --product-api-3 <IP> \
#     --payments      <IP> \
#     --public-api    <IP> \
#     --frontend      <IP>
#
# IPs come from: terraform -chdir=terraform/dc4 output -json hashicups_private_ips
#
# ESM picks up nodes with NodeMeta "external-node"="true" and executes the
# health check Definitions written into each node's check.
set -euo pipefail

CONSUL_ADDR="${CONSUL_HTTP_ADDR:-http://127.0.0.1:8500}"

declare -A IPS=()

# Parse --key value pairs
while [[ $# -gt 0 ]]; do
  case "$1" in
    --postgres|--product-api-1|--product-api-2|--product-api-3|--payments|--public-api|--frontend)
      key="${1#--}"
      IPS["$key"]="$2"
      shift 2
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

register_node() {
  local node="$1" ip="$2" service="$3" port="$4"
  echo "  Registering ${node} (${service}:${port}) @ ${ip}"
  curl -fsS -X PUT "${CONSUL_ADDR}/v1/catalog/register" \
    -H "Content-Type: application/json" \
    -d @- <<EOF
{
  "Node": "${node}",
  "Address": "${ip}",
  "NodeMeta": {
    "external-node": "true",
    "external-probe": "false"
  },
  "Service": {
    "ID": "${service}",
    "Service": "${service}",
    "Tags": ["dc4", "external"],
    "Address": "${ip}",
    "Port": ${port}
  },
  "Checks": [
    {
      "Node": "${node}",
      "CheckID": "service:${service}",
      "Name": "${service} TCP",
      "Status": "critical",
      "ServiceID": "${service}",
      "Definition": {
        "TCP": "${ip}:${port}",
        "Interval": "15s",
        "Timeout": "5s"
      }
    }
  ]
}
EOF
  echo ""
}

echo "==> Registering DC4 external nodes in ${CONSUL_ADDR}"

[[ -n "${IPS[postgres]:-}"      ]] && register_node "dc4-postgres"      "${IPS[postgres]}"      "postgres"   5432
[[ -n "${IPS[product-api-1]:-}" ]] && register_node "dc4-product-api-1" "${IPS[product-api-1]}" "product-api" 9090
[[ -n "${IPS[product-api-2]:-}" ]] && register_node "dc4-product-api-2" "${IPS[product-api-2]}" "product-api" 9090
[[ -n "${IPS[product-api-3]:-}" ]] && register_node "dc4-product-api-3" "${IPS[product-api-3]}" "product-api" 9090
[[ -n "${IPS[payments]:-}"      ]] && register_node "dc4-payments"      "${IPS[payments]}"      "payments"   8080
[[ -n "${IPS[public-api]:-}"    ]] && register_node "dc4-public-api"    "${IPS[public-api]}"    "public-api" 8080
[[ -n "${IPS[frontend]:-}"      ]] && register_node "dc4-frontend"      "${IPS[frontend]}"      "frontend"   80

echo "==> Registration complete. ESM will begin health checks within 15s."
echo "    Verify: consul catalog nodes -service=product-api"
echo "    Check health: consul health service product-api"
