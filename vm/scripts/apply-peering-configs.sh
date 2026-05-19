#!/usr/bin/env bash
# Apply all post-peering configuration in the correct order.
#
# Run this AFTER:
#   1. Both DC3 and DC4 Consul servers are bootstrapped.
#   2. Cluster peering is established (bootstrap-dc4-server.sh handles this).
#   3. All HashiCups VMs are up and running their services.
#   4. DC4 external nodes are registered (register-dc4-services.sh).
#
# Usage:
#   export DC3_IP=<DC3_CONSUL_SERVER_PRIVATE_IP>
#   export DC4_IP=<DC4_CONSUL_SERVER_PRIVATE_IP>
#   bash apply-peering-configs.sh
set -euo pipefail

DC3_IP="${DC3_IP:?Set DC3_IP to the DC3 Consul server private IP}"
DC4_IP="${DC4_IP:?Set DC4_IP to the DC4 Consul server private IP}"

DC3_ADDR="http://${DC3_IP}:8500"
DC4_ADDR="http://${DC4_IP}:8500"

VM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PQ_DIR="$(cd "${VM_DIR}/../prepared-queries" && pwd)"

apply_config() {
  local addr="$1" file="$2" dc="$3"
  echo "  [${dc}] consul config write $(basename ${file})"
  curl -fsS -X PUT "${addr}/v1/config" \
    -H "Content-Type: application/json" \
    -d @"${file}"
  echo ""
}

register_query() {
  local addr="$1" file="$2" dc="$3"
  local name existing_id
  name=$(python3 -c "import json,sys; print(json.load(open('$file'))['Name'])")
  existing_id=$(curl -s "${addr}/v1/query" | \
    python3 -c "import json,sys; qs=[q['ID'] for q in json.load(sys.stdin) if q['Name']=='${name}']; print(qs[0] if qs else '')")
  if [[ -n "$existing_id" ]]; then
    echo "  [${dc}] update query: ${name} (id: ${existing_id:0:8}...)"
    curl -fsS -X PUT "${addr}/v1/query/${existing_id}" \
      -H "Content-Type: application/json" \
      -d @"${file}"
  else
    echo "  [${dc}] create query: ${name}"
    curl -fsS -X POST "${addr}/v1/query" \
      -H "Content-Type: application/json" \
      -d @"${file}"
  fi
  echo ""
}

# ── Step 1: Verify peering is established ───────────────────────────────────
echo "==> Step 1: Verify cluster peering"
echo "  DC3 peers:"
curl -s "${DC3_ADDR}/v1/peerings" | python3 -c "
import json,sys
peers = json.load(sys.stdin)
for p in peers: print(f'    {p[\"Name\"]} — {p[\"State\"]}')
" 2>/dev/null || echo "  (could not reach DC3)"

echo "  DC4 peers:"
curl -s "${DC4_ADDR}/v1/peerings" | python3 -c "
import json,sys
peers = json.load(sys.stdin)
for p in peers: print(f'    {p[\"Name\"]} — {p[\"State\"]}')
" 2>/dev/null || echo "  (could not reach DC4)"
echo ""

# ── Step 2: Export services bidirectionally ─────────────────────────────────
# Required so each DC's prepared query can see the other DC's product-api
# instances via the Targets.Peer failover entry.
echo "==> Step 2: Apply exported-services (bidirectional)"
apply_config "${DC3_ADDR}" "${VM_DIR}/consul/exported-services-dc3.json" "dc3-vm"
apply_config "${DC4_ADDR}" "${VM_DIR}/consul/exported-services-dc4.json" "dc4-esm"

# ── Step 3: Apply terminating gateway config entry on DC4 ───────────────────
echo "==> Step 3: Apply terminating-gateway config entry on DC4"
apply_config "${DC4_ADDR}" "${VM_DIR}/terminating-gw/terminating-gateway.json" "dc4-esm"

# ── Step 4: Register prepared queries on both DCs ───────────────────────────
# DC3 copy: Targets = [dc3-vm local, peer dc4-esm]
# DC4 copy: Targets = [dc4-esm local, peer dc3-vm]  (mirrored preference)
echo "==> Step 4: Register prepared queries"
register_query "${DC3_ADDR}" "${PQ_DIR}/product-api-geo-failover.json" "dc3-vm"
register_query "${DC3_ADDR}" "${PQ_DIR}/product-api-local-only.json"   "dc3-vm"
register_query "${DC4_ADDR}" "${PQ_DIR}/product-api-geo-dc4.json"      "dc4-esm"

# ── Step 5: Verify ──────────────────────────────────────────────────────────
echo "==> Step 5: Verify"
echo ""
echo "  DC3 queries registered:"
curl -s "${DC3_ADDR}/v1/query" | python3 -c "
import json,sys
for q in json.load(sys.stdin): print(f'    {q[\"Name\"]} (ID: {q[\"ID\"][:8]}...)')
"
echo ""
echo "  DC4 queries registered:"
curl -s "${DC4_ADDR}/v1/query" | python3 -c "
import json,sys
for q in json.load(sys.stdin): print(f'    {q[\"Name\"]} (ID: {q[\"ID\"][:8]}...)')
"
echo ""
echo "  DC3 exported services:"
curl -s "${DC3_ADDR}/v1/config/exported-services" | python3 -c "
import json,sys
entries = json.load(sys.stdin)
for e in entries:
    for svc in e.get('Services', []):
        consumers = [c.get('Peer','?') for c in svc.get('Consumers',[])]
        print(f'    {svc[\"Name\"]} → peers: {consumers}')
" 2>/dev/null || true
echo ""
echo "  DC4 exported services:"
curl -s "${DC4_ADDR}/v1/config/exported-services" | python3 -c "
import json,sys
entries = json.load(sys.stdin)
for e in entries:
    for svc in e.get('Services', []):
        consumers = [c.get('Peer','?') for c in svc.get('Consumers',[])]
        print(f'    {svc[\"Name\"]} → peers: {consumers}')
" 2>/dev/null || true

echo ""
echo "==> All peering configs applied."
echo ""
echo "DNS test (laptop — dscacheutil respects /etc/resolver, dig does not on macOS):"
echo "  dscacheutil -q host -a name product-api-geo.query.consul.prabhjit-singh.sbx.hashidemos.io"
echo "  dscacheutil -q host -a name product-api-local.query.consul.prabhjit-singh.sbx.hashidemos.io"
