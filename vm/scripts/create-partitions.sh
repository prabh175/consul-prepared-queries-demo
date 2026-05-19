#!/usr/bin/env bash
# Create Consul admin partitions for DC5 and DC6 before deploying consul-k8s.
# DC5 → dc5-k8s partition on DC3 Consul server.
# DC6 → dc6-k8s partition on DC4 Consul server.
#
# Partitions must exist before the consul-k8s chart bootstraps; otherwise the
# chart's partition-init job fails with "partition not found".
#
# Run from your laptop after both DC3 and DC4 Consul servers are up:
#   bash vm/scripts/create-partitions.sh

set -euo pipefail

DC3_SERVER_PUB="${DC3_SERVER_PUB:?Export DC3_SERVER_PUB first. terraform -chdir=terraform/dc3 output -raw consul_server_public_ip}"
DC4_SERVER_PUB="${DC4_SERVER_PUB:?Export DC4_SERVER_PUB first. terraform -chdir=terraform/dc4 output -raw consul_server_public_ip}"

echo "==> Creating admin partition dc5-k8s on DC3 (${DC3_SERVER_PUB})"
curl -sf -X PUT "http://${DC3_SERVER_PUB}:8500/v1/operator/partition" \
  -d '{"Name":"dc5-k8s","Description":"EKS mesh partition — app layer, Scenario D"}' \
  | jq -r '.Partition.Name + " created"' \
  || echo "  (partition may already exist — continuing)"

echo ""
echo "==> Creating admin partition dc6-k8s on DC4 (${DC4_SERVER_PUB})"
curl -sf -X PUT "http://${DC4_SERVER_PUB}:8500/v1/operator/partition" \
  -d '{"Name":"dc6-k8s","Description":"EKS catalog-sync partition — data layer, Scenario C"}' \
  | jq -r '.Partition.Name + " created"' \
  || echo "  (partition may already exist — continuing)"

echo ""
echo "==> Verifying partitions"
echo "DC3 partitions:"
curl -sf "http://${DC3_SERVER_PUB}:8500/v1/operator/partitions" | jq '[.[].Name]'

echo ""
echo "DC4 partitions:"
curl -sf "http://${DC4_SERVER_PUB}:8500/v1/operator/partitions" | jq '[.[].Name]'

echo ""
echo "==> Done. Next steps:"
echo "    1. Deploy DC5 EKS: terraform -chdir=terraform/dc5 apply"
echo "    2. Deploy DC6 EKS: terraform -chdir=terraform/dc6 apply"
echo "    3. Configure kubectl: run the kubeconfig_hint outputs from each"
echo "    4. Install consul-k8s on DC5:"
echo "       kubectl create secret generic consul-ent-license --from-file=key=vm/license.hclic -n consul --create-namespace --context dc5"
echo "       helm install consul hashicorp/consul --namespace consul -f k8s/dc5/consul-values.yaml --kube-context dc5"
echo "    5. Install consul-k8s on DC6:"
echo "       kubectl create secret generic consul-ent-license --from-file=key=vm/license.hclic -n consul --create-namespace --context dc6"
echo "       helm install consul hashicorp/consul --namespace consul -f k8s/dc6/consul-values.yaml --kube-context dc6"
echo "    6. Deploy workloads: kubectl apply -f k8s/dc5/workloads.yaml --context dc5"
echo "    7. Deploy workloads: kubectl apply -f k8s/dc6/workloads.yaml --context dc6"
echo "    8. Apply Consul config: kubectl apply -f k8s/dc5/service-intentions.yaml --context dc5"
echo "    9. Apply Consul config: kubectl apply -f k8s/dc5/terminating-gateway.yaml --context dc5"
echo "   10. Apply Consul config: kubectl apply -f k8s/dc5/exported-services.yaml --context dc5"
echo "   11. Set up DC5↔DC4 peering: see k8s/dc5/peering-dc4.yaml"
echo "   12. Apply sameness group: kubectl apply -f k8s/dc6/sameness-group.yaml --context dc6"
