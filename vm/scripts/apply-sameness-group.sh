#!/usr/bin/env bash
# Apply the sameness group that makes DC4 VMs and DC6 K8s instances interchangeable.
# Both sides of the sameness group must be configured — once for DC4's default partition,
# once for DC6's dc6-k8s partition. Both config entries are applied via the DC4 Consul server
# (the shared control plane for dc4-esm + dc6-k8s).
#
# Run from your laptop after DC6 EKS is up and catalog sync is running (Phase 11).
#   export DC4_SERVER_PUB=<DC4 consul server public IP>
#   bash vm/scripts/apply-sameness-group.sh

set -euo pipefail

DC4_SERVER_PUB="${DC4_SERVER_PUB:?Export DC4_SERVER_PUB first: terraform -chdir=terraform/dc4 output -raw consul_server_public_ip}"
DC4_ADDR="http://${DC4_SERVER_PUB}:8500"

SAMENESS_GROUP_NAME="dc4-dc6-product-api"

echo "==> Checking DC6 catalog sync is working"
DC6_PASSING=$(curl -sf "${DC4_ADDR}/v1/health/service/product-api?passing&partition=dc6-k8s" \
  | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
if [[ "$DC6_PASSING" -eq 0 ]]; then
  echo "  WARNING: No passing product-api instances in dc6-k8s partition."
  echo "  Catalog sync may not be running yet. Apply the sameness group anyway? [y/N]"
  read -r REPLY
  [[ "$REPLY" =~ ^[Yy]$ ]] || { echo "Aborting."; exit 1; }
else
  echo "  DC6 K8s passing product-api instances: ${DC6_PASSING}"
fi

echo ""
echo "==> Applying sameness group '${SAMENESS_GROUP_NAME}' on DC4 default partition"
curl -sf -X PUT "${DC4_ADDR}/v1/config" \
  -H "Content-Type: application/json" \
  -H "X-Consul-Partition: default" \
  -d "{
    \"Kind\": \"sameness-group\",
    \"Name\": \"${SAMENESS_GROUP_NAME}\",
    \"Partition\": \"default\",
    \"DefaultForFailover\": true,
    \"IncludeLocal\": true,
    \"Members\": [
      {\"Partition\": \"default\"},
      {\"Partition\": \"dc6-k8s\"}
    ]
  }"
echo "  OK"

echo ""
echo "==> Applying sameness group '${SAMENESS_GROUP_NAME}' on DC4 dc6-k8s partition"
curl -sf -X PUT "${DC4_ADDR}/v1/config" \
  -H "Content-Type: application/json" \
  -H "X-Consul-Partition: dc6-k8s" \
  -d "{
    \"Kind\": \"sameness-group\",
    \"Name\": \"${SAMENESS_GROUP_NAME}\",
    \"Partition\": \"dc6-k8s\",
    \"DefaultForFailover\": true,
    \"IncludeLocal\": true,
    \"Members\": [
      {\"Partition\": \"default\"},
      {\"Partition\": \"dc6-k8s\"}
    ]
  }"
echo "  OK"

echo ""
echo "==> Verifying sameness group on both partitions"
echo "  default partition:"
curl -sf "${DC4_ADDR}/v1/config/sameness-group/${SAMENESS_GROUP_NAME}?partition=default" \
  | python3 -c "
import json,sys
sg = json.load(sys.stdin)
print('    Name:', sg['Name'])
print('    Members:', [m.get('Partition','?') for m in sg.get('Members',[])])
print('    DefaultForFailover:', sg.get('DefaultForFailover'))
"

echo ""
echo "  dc6-k8s partition:"
curl -sf "${DC4_ADDR}/v1/config/sameness-group/${SAMENESS_GROUP_NAME}?partition=dc6-k8s" \
  | python3 -c "
import json,sys
sg = json.load(sys.stdin)
print('    Name:', sg['Name'])
print('    Members:', [m.get('Partition','?') for m in sg.get('Members',[])])
"

echo ""
echo "==> Done. Sameness group '${SAMENESS_GROUP_NAME}' is active."
echo "    Scenario C: stop DC4 VM product-api instances and traffic will shift to DC6 K8s."
echo "    Test: curl -s \"${DC4_ADDR}/v1/health/service/product-api?passing&partition=dc6-k8s\""
