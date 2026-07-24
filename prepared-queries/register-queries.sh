#!/usr/bin/env bash
# Register prepared queries on Consul servers.
#
# Scenarios covered:
#   DC3  — product-api-geo   (Scenarios A, B): DC3 primary → DC4 peer failover.
#   DC3  — product-api-hybrid (Scenario D):   DC5 K8s primary → DC4 VM peer failover.
#                                             CONSUL_HTTP_ADDR must point to DC3 server.
#   DC3  — frontend-geo      (Scenario E):    DC5 K8s NLB primary → DC6 K8s NLB fallback.
#                                             Register AFTER vm/scripts/register-esm-frontends.sh.
#   DC4  — product-api-geo   (Scenarios A, B): DC4 primary → DC3 peer failover.
#   DC4  — frontend-geo      (Scenario E):    DC6 K8s NLB primary → DC4 VM frontend fallback.
#                                             Register AFTER vm/scripts/register-esm-frontends.sh.
#
# Usage:
#   # DC3 product-api queries (Scenarios A, B):
#   CONSUL_HTTP_ADDR=http://$DC3_SERVER_PUB:8500 bash prepared-queries/register-queries.sh
#
#   # DC4 product-api queries (Scenarios A, B):
#   CONSUL_HTTP_ADDR=http://$DC4_SERVER_PUB:8500 DC=dc4 bash prepared-queries/register-queries.sh
#
#   # DC5 product-api-hybrid (Scenario D) — registered in dc5-k8s partition on DC3 server:
#   CONSUL_HTTP_ADDR=http://$DC3_SERVER_PUB:8500 DC=dc5 bash prepared-queries/register-queries.sh
#
#   # DC3 frontend-geo (Scenario E) — requires ESM registrations to exist first:
#   CONSUL_HTTP_ADDR=http://$DC3_SERVER_PUB:8500 DC=dc3-frontend bash prepared-queries/register-queries.sh
#
#   # DC4 frontend-geo (Scenario E) — registered in dc6-k8s partition, requires ESM first:
#   CONSUL_HTTP_ADDR=http://$DC4_SERVER_PUB:8500 DC=dc4-frontend bash prepared-queries/register-queries.sh
#
# Env:
#   CONSUL_HTTP_ADDR   Consul HTTP endpoint (default: http://127.0.0.1:8500)
#   DC                 dc3 (default), dc4, dc5, dc3-frontend, dc4-frontend
set -euo pipefail

CONSUL_ADDR="${CONSUL_HTTP_ADDR:-http://127.0.0.1:8500}"
DC="${DC:-dc3}"
CONSUL_TOKEN="${CONSUL_HTTP_TOKEN:-}"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

register_query() {
  local file="$1"
  local partition_header="${2:-}"
  local name
  name=$(python3 -c "import json,sys; print(json.load(open('$file'))['Name'])")
  echo "  Registering: ${name} (from ${file##*/})"
  local -a extra=()
  [[ -n "$partition_header" ]] && extra+=(-H "$partition_header")
  [[ -n "$CONSUL_TOKEN" ]] && extra+=(-H "X-Consul-Token: $CONSUL_TOKEN")
  curl -fsS -X POST "${CONSUL_ADDR}/v1/query" \
    -H "Content-Type: application/json" \
    ${extra[@]+"${extra[@]}"} \
    -d @"${file}"
  echo ""
}

echo "==> Registering prepared queries on ${CONSUL_ADDR} (DC=${DC})"

case "${DC}" in
  dc4)
    # DC4: geo query prefers DC4-local product-api, peers to DC3 on failure
    register_query "${SCRIPT_DIR}/product-api-geo-dc4.json"
    ;;

  dc3-frontend)
    # DC3: Scenario E frontend query — registered in dc5-k8s partition so dc5-frontend-nlb
    # is the primary. Failover target is default partition (dc6-frontend-nlb).
    # Register AFTER vm/scripts/register-esm-frontends.sh.
    register_query "${SCRIPT_DIR}/frontend-geo-dc3.json" "X-Consul-Partition: dc5-k8s"
    ;;

  dc5)
    # DC5 (dc5-k8s partition on DC3 server): Scenario D — DC5 K8s product-api primary,
    # fails over to DC4 VM product-api via dc4-peer cluster peer.
    # CONSUL_HTTP_ADDR must point to DC3 server ($DC3_SERVER_PUB:8500).
    register_query "${SCRIPT_DIR}/product-api-hybrid.json" "X-Consul-Partition: dc5-k8s"
    ;;

  dc4-frontend)
    # DC4 dc6-k8s partition: Scenario E frontend query — DC6 K8s frontend primary,
    # DC4 VM frontend fallback. Registered in dc6-k8s partition so DC6 NLB is primary.
    # Register AFTER vm/scripts/register-esm-frontends.sh.
    register_query "${SCRIPT_DIR}/frontend-geo-dc4.json" "X-Consul-Partition: dc6-k8s"
    ;;

  dc3|*)
    # DC3 (default): Scenarios A+B product-api geo queries
    register_query "${SCRIPT_DIR}/product-api-geo-failover.json"
    register_query "${SCRIPT_DIR}/product-api-local-only.json"
    ;;
esac

echo "==> Done. Verify:"
echo "  curl -s ${CONSUL_ADDR}/v1/query | python3 -c \"import json,sys; [print(q['Name']) for q in json.load(sys.stdin)]\""
echo ""
echo "DNS test (from a node with Consul DNS on :8600):"
echo "  dig @127.0.0.1 -p 8600 product-api-geo.query.consul. SRV +short"
echo "  dig @127.0.0.1 -p 8600 frontend-geo.query.consul. SRV +short"
