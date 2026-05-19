#!/usr/bin/env bash
# Prepared Queries Geo-Failover Demo Walkthrough
#
# Story: Consul prepared queries act as a software F5 GTM — they resolve "product-api"
# to the nearest healthy instance.  Two failure scenarios are shown:
#
#   Scenario A — DC3 service failure:
#     All DC3 product-api containers stop → query fails over to DC4 ESM instances.
#
#   Scenario B — DC3 control plane failure:
#     DC3 Consul server stops → bastion's systemd-resolved falls back to DC4's
#     DNS NLB within ~2s and executes DC4's copy of the prepared query instead.
#
# Prerequisites (set before running):
#   Running from your laptop — all IPs must be PUBLIC (Consul API :8500 and SSH require it).
#   export DC3_IP=<DC3 Consul server PUBLIC IP>    # used for Consul API + DNS queries
#   export DC4_IP=<DC4 Consul server PUBLIC IP>    # used to verify DC4 query results
#   export KEY=<path to us-east-1 SSH key .pem>
#   export KEY_W2=<path to us-west-2 SSH key .pem>
#   export DC3_SERVER_PUB=<DC3 Consul server PUBLIC IP>
#   export BASTION_PUB=$(terraform -chdir=terraform/dc3 output -raw bastion_public_ip)
#   export DC3_PA1_IP=<product-api-1 PUBLIC IP>
#   export DC3_PA2_IP=<product-api-2 PUBLIC IP>
#   export DC3_PA3_IP=<product-api-3 PUBLIC IP>
#
# On-prem DNS setup (laptop): route the org sub-zone to both NLBs. Run once before the demo:
#   sudo mkdir -p /etc/resolver
#   sudo tee /etc/resolver/consul.prabhjit-singh.sbx.hashidemos.io <<EOF
#   nameserver $DC3_NLB_IP
#   nameserver $DC4_NLB_IP
#   EOF
# Note: 'dig' ignores /etc/resolver on macOS — use 'dscacheutil -q host -a name <fqdn>'
#
# Run from your laptop (not from within the DC3 VM) so Scenario B can be demonstrated
# without losing your shell session when DC3 goes down.
set -euo pipefail

DC3_CONSUL="http://${DC3_IP:?Set DC3_IP}:8500"
DC4_CONSUL="http://${DC4_IP:?Set DC4_IP}:8500"

banner() {
  echo ""
  echo "══════════════════════════════════════════════════"
  echo "  $*"
  echo "══════════════════════════════════════════════════"
}

pause() { echo ""; echo "  ▶  $*"; echo "  Press ENTER to continue..."; read -r; }

# ---------------------------------------------------------------------------
banner "PRE-FLIGHT — Verify peering + queries are registered on both DCs"
# ---------------------------------------------------------------------------
echo "DC3 peering state:"
curl -s "${DC3_CONSUL}/v1/peerings" | python3 -c "
import json,sys
body = sys.stdin.read().strip()
try:
    peers = json.loads(body) or []
    if not peers:
        print('  (no peerings listed yet — may still be syncing after restart)')
    else:
        for p in peers: print(f'  {p[\"Name\"]} — {p[\"State\"]}')
except Exception as e:
    print(f'  (parse error: {e})')
" || echo "  (could not reach DC3)"

echo ""
echo "DC3 registered queries:"
curl -s "${DC3_CONSUL}/v1/query" | python3 -c "
import json,sys
for q in json.load(sys.stdin): print(f'  {q[\"Name\"]}')
"

echo ""
echo "DC4 registered queries:"
curl -s "${DC4_CONSUL}/v1/query" | python3 -c "
import json,sys
for q in json.load(sys.stdin): print(f'  {q[\"Name\"]}')
" || echo "  (could not reach DC4)"

echo ""
echo "Expected: product-api-geo and product-api-local on DC3; product-api-geo on DC4."
echo "If missing, run: bash vm/scripts/apply-peering-configs.sh"
pause "Verify pre-flight looks clean"

# ---------------------------------------------------------------------------
banner "STEP 1 — Baseline: all DC3 product-api instances healthy"
# ---------------------------------------------------------------------------
echo "Three product-api nodes registered natively in DC3 via Consul agents."
echo ""
echo "Catalog check:"
curl -s "${DC3_CONSUL}/v1/health/service/product-api?passing" | python3 -c "
import json,sys
nodes = json.load(sys.stdin)
print(f'Healthy product-api instances in dc3-vm: {len(nodes)}')
for n in nodes:
    print(f'  - {n[\"Node\"][\"Node\"]} @ {n[\"Node\"][\"Address\"]}')
"

echo ""
echo "── AWS user (bastion — systemd-resolved → DC3 NLB → DC3 Consul DNS) ──"
ssh -n -i "${KEY}" -o StrictHostKeyChecking=no ubuntu@"${BASTION_PUB:?Set BASTION_PUB}" \
  'dig product-api-geo.query.consul. A +short' \
  || echo "  (bastion unreachable or DNS not configured — see Phase 8)"
echo "(Should be DC3 IPs — 10.10.x.x range)"

echo ""
echo "── On-prem client (laptop — /etc/resolver sub-zone → DC3 NLB → DC3 Consul DNS) ──"
dscacheutil -q host -a name product-api-geo.query.consul.prabhjit-singh.sbx.hashidemos.io \
  | grep ip_address || echo "  (not resolving — check /etc/resolver/consul.prabhjit-singh.sbx.hashidemos.io)"
echo "(Should match bastion — DC3 IPs, 10.10.x.x range)"

# ---------------------------------------------------------------------------
banner "STEP 2 — Execute prepared query via HTTP API"
# ---------------------------------------------------------------------------
echo "HTTP execute — shows which datacenter resolved + which nodes are returned:"
curl -s "${DC3_CONSUL}/v1/query/product-api-geo/execute?near=_agent" | python3 -c "
import json,sys
r = json.load(sys.stdin)
dc = r.get('Datacenter') or 'dc3-vm'
failovers = r.get('Failovers', 0)
print(f'Datacenter resolved: {dc}  (Failovers applied: {failovers})')
print(f'Nodes returned: {len(r[\"Nodes\"])}')
for n in r['Nodes']:
    addr = n['Service']['Address'] or n['Node']['Address']
    print(f'  - {n[\"Node\"][\"Node\"]} @ {addr}:{n[\"Service\"][\"Port\"]}')
"

echo ""
echo "Key: Failover.Targets = [{Datacenter: dc3-vm}, {Peer: dc4-esm}]"
echo "DC3-local instances are preferred; dc4-esm peer is only used when DC3 has none passing."
pause "Baseline looks good"

# ===========================================================================
banner "SCENARIO A — DC3 service-level failure"
# ===========================================================================

# ---------------------------------------------------------------------------
banner "STEP 3A — Stop DC3 product-api containers"
# ---------------------------------------------------------------------------
echo "Stopping product-api containers on all 3 DC3 VMs..."
for IP in "${DC3_PA1_IP:?Set DC3_PA1_IP}" "${DC3_PA2_IP:?Set DC3_PA2_IP}" "${DC3_PA3_IP:?Set DC3_PA3_IP}"; do
  echo "  Stopping product-api on ${IP}..."
  ssh -n -i "${KEY:?Set KEY}" -o StrictHostKeyChecking=no ubuntu@"${IP}" 'docker stop product-api' || true
done
echo ""
echo "Waiting 35s for Consul health checks to flip to critical..."
sleep 35

# ---------------------------------------------------------------------------
banner "STEP 4A — Observe automatic failover to DC4"
# ---------------------------------------------------------------------------
echo "DC3 healthy product-api count (should be 0):"
curl -s "${DC3_CONSUL}/v1/health/service/product-api?passing" | \
  python3 -c "import json,sys; print(f'  {len(json.load(sys.stdin))} passing')"

echo ""
echo "Prepared query now resolves to DC4 (Targets failover triggered):"
curl -s "${DC3_CONSUL}/v1/query/product-api-geo/execute?near=_agent" | python3 -c "
import json,sys
r = json.load(sys.stdin)
failovers = r.get('Failovers', 0)
nodes = r['Nodes']
dc = r.get('Datacenter') or ('dc4-esm (peer)' if failovers > 0 else 'dc3-vm')
print(f'Failovers applied: {failovers}  ← should be 1')
print(f'Resolved via: {dc}')
print(f'Nodes returned: {len(nodes)}')
for n in nodes:
    addr = n['Service']['Address'] or n['Node']['Address']
    print(f'  - {n[\"Node\"][\"Node\"]} @ {addr}:{n[\"Service\"][\"Port\"]}')
"

echo ""
echo "DNS also fails over — DC3 control plane is still up so DC3 NLB resolves the answer:"
echo "── On-prem client ──"
dscacheutil -q host -a name product-api-geo.query.consul.prabhjit-singh.sbx.hashidemos.io \
  | grep ip_address
echo "(Results should be DC4 ESM-registered IPs — 10.20.x.x range)"
echo "── AWS user (bastion) ──"
ssh -n -i "${KEY}" -o StrictHostKeyChecking=no ubuntu@"${BASTION_PUB}" \
  'dig product-api-geo.query.consul. A +short' || true

echo ""
echo "Local-only query returns 0 results — shows 'site down' for DC3-specific traffic:"
curl -s "${DC3_CONSUL}/v1/query/product-api-local/execute" | \
  python3 -c "import json,sys; r=json.load(sys.stdin); print(f'  product-api-local: {len(r[\"Nodes\"])} results (0 = DC3 down, no cross-DC fallback)')"

pause "Failover to DC4 confirmed"

# ---------------------------------------------------------------------------
banner "STEP 5A — Restore DC3 product-api"
# ---------------------------------------------------------------------------
echo "Restarting product-api containers on all 3 DC3 VMs..."
for IP in "${DC3_PA1_IP}" "${DC3_PA2_IP}" "${DC3_PA3_IP}"; do
  echo "  Starting product-api on ${IP}..."
  ssh -n -i "${KEY}" -o StrictHostKeyChecking=no ubuntu@"${IP}" 'docker start product-api' || true
done
echo ""
echo "Waiting 35s for health checks to pass..."
sleep 35

echo "Prepared query back to DC3 (Targets[0] = dc3-vm is healthy again):"
curl -s "${DC3_CONSUL}/v1/query/product-api-geo/execute?near=_agent" | python3 -c "
import json,sys
r = json.load(sys.stdin)
print(f'Datacenter resolved: {r[\"Datacenter\"]}  ← should be dc3-vm again')
print(f'Nodes returned: {len(r[\"Nodes\"])}')
"

# ===========================================================================
banner "SCENARIO B — DC3 control plane failure"
# ===========================================================================
echo "The bastion VM has systemd-resolved configured with two nameservers:"
echo "  Primary:   DC3 DNS NLB (port 53 → DC3 Consul :8600)"
echo "  Secondary: DC4 DNS NLB (port 53 → DC4 Consul :8600)"
echo ""
echo "When DC3 Consul stops, systemd-resolved falls back to DC4's NLB within ~2s."
echo "DC4's copy of product-api-geo (Targets[0]=dc4-esm local, Targets[1]=dc3-vm peer)"
echo "is executed — DC4-local ESM instances are returned immediately."
echo ""
pause "Ready to simulate DC3 control plane failure"

# ---------------------------------------------------------------------------
banner "STEP 3B — Stop the DC3 Consul server process"
# ---------------------------------------------------------------------------
echo "Stopping DC3 Consul server (stopping dependents first to prevent restart loops)..."
ssh -n -i "${KEY}" -o StrictHostKeyChecking=no ubuntu@"${DC3_SERVER_PUB}" \
  'sudo systemctl stop consul_exporter mesh-gateway consul 2>/dev/null; true'
echo ""
echo "DC3 Consul is down. DC4 API and DNS are still reachable."
sleep 5

echo "DC3 API (should fail):"
curl -s --max-time 3 "${DC3_CONSUL}/v1/status/leader" && echo "  (still responding)" || echo "  ✓ DC3 unreachable"

echo ""
echo "DC4 API (should still respond):"
curl -s "${DC4_CONSUL}/v1/status/leader" | python3 -c "import json,sys; print(f'  DC4 leader: {json.load(sys.stdin)}')"

echo ""
echo "DC4's copy of product-api-geo (Targets[0]=dc4-esm local, Targets[1]=dc3-vm peer):"
curl -s "${DC4_CONSUL}/v1/query/product-api-geo/execute?near=_agent" | python3 -c "
import json,sys
r = json.load(sys.stdin)
failovers = r.get('Failovers', 0)
dc = r.get('Datacenter') or 'dc4-esm (local)'
print(f'Resolved via: {dc}  (Failovers: {failovers})  ← dc4-esm local instances, no failover needed')
print(f'Nodes returned: {len(r[\"Nodes\"])}')
for n in r['Nodes']:
    addr = n['Service']['Address'] or n['Node']['Address']
    print(f'  - {n[\"Node\"][\"Node\"]} @ {addr}:{n[\"Service\"][\"Port\"]}')
"
pause "DC3 control plane is down — ready to test bastion DNS failover"

# ---------------------------------------------------------------------------
banner "STEP 4B — DNS failover: AWS user + on-prem client"
# ---------------------------------------------------------------------------
echo "Both clients have two nameservers configured:"
echo "  1. DC3 DNS NLB — now unreachable (Consul server is down)"
echo "  2. DC4 DNS NLB — still up"
echo ""
echo "Both fall back to DC4's NLB and execute DC4's local copy of the query."
echo "No config change on any client — same query, different DC."
echo ""

echo "── AWS user (bastion) ──"
ssh -n -i "${KEY}" -o StrictHostKeyChecking=no ubuntu@"${BASTION_PUB}" \
  'time dig product-api-geo.query.consul. A +short' \
  || echo "  (bastion unreachable — check Phase 8 setup)"
echo "(Should be DC4 ESM IPs — 10.20.x.x range, within ~2s)"

echo ""
echo "── On-prem client (laptop) ──"
time dscacheutil -q host -a name product-api-geo.query.consul.prabhjit-singh.sbx.hashidemos.io \
  | grep ip_address \
  || echo "  (not resolving — check /etc/resolver/consul.prabhjit-singh.sbx.hashidemos.io)"
echo "(Should match bastion — DC4 ESM IPs, 10.20.x.x range)"

echo ""
echo "Both clients transparently served by DC4 — zero intervention required."

pause "DNS failover confirmed on both AWS and on-prem clients"

# ---------------------------------------------------------------------------
banner "STEP 5B — Restore DC3 control plane"
# ---------------------------------------------------------------------------
echo "Restoring DC3 Consul server..."
ssh -n -i "${KEY}" -o StrictHostKeyChecking=no ubuntu@"${DC3_SERVER_PUB}" \
  'sudo bash -c "systemctl start consul && sleep 8 && systemctl start mesh-gateway consul_exporter 2>/dev/null; true"'
echo ""
echo "Waiting for DC3 Consul to re-join and NLB to mark target healthy..."
# Poll until DC3 API responds AND product-api health checks pass
for i in $(seq 1 24); do
  LEADER=$(curl -s --max-time 3 "${DC3_CONSUL}/v1/status/leader" 2>/dev/null | tr -d '"')
  PASSING=$(curl -s --max-time 3 "${DC3_CONSUL}/v1/health/service/product-api?passing" 2>/dev/null | \
    python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
  echo "  [${i}] leader=${LEADER:-none}  passing=${PASSING}/3"
  [[ -n "$LEADER" && "$PASSING" -eq 3 ]] && break
  sleep 5
done

echo ""
echo "Resetting DNS client state — waiting for NLB to detect DC3 healthy (10s interval)..."
sleep 12
ssh -n -i "${KEY}" -o StrictHostKeyChecking=no ubuntu@"${BASTION_PUB}" \
  "sudo systemctl restart systemd-resolved"
dscacheutil -flushcache && sudo killall -HUP mDNSResponder
echo "  Done — DNS clients reset to DC3 NLB as primary."

echo ""
echo "Verifying DC3 product-api health checks have re-passed:"
curl -s "${DC3_CONSUL}/v1/health/service/product-api?passing" | python3 -c "
import json,sys
nodes = json.load(sys.stdin)
print(f'  DC3 passing product-api: {len(nodes)}  (expect 3)')
"

echo ""
echo "── AWS user (bastion) — should return DC3 IPs again ──"
ssh -n -i "${KEY}" -o StrictHostKeyChecking=no ubuntu@"${BASTION_PUB}" \
  'dig product-api-geo.query.consul. A +short'
echo ""
echo "── On-prem client (laptop) ──"
dscacheutil -q host -a name product-api-geo.query.consul.prabhjit-singh.sbx.hashidemos.io \
  | grep ip_address
echo "(Both should be back to DC3 IPs — 10.10.x.x range)"

# ===========================================================================
banner "BONUS — View catalog across both DCs"
# ===========================================================================
echo "All product-api nodes in DC3 catalog:"
curl -s "${DC3_CONSUL}/v1/health/service/product-api" | python3 -c "
import json,sys
for n in json.load(sys.stdin):
    status = n['Checks'][-1]['Status'] if n['Checks'] else 'unknown'
    print(f'  [{status:8}] {n[\"Node\"][\"Node\"]} @ {n[\"Node\"][\"Address\"]}')
"

echo ""
echo "All product-api nodes in DC4 catalog (ESM-registered external nodes):"
curl -s "${DC4_CONSUL}/v1/health/service/product-api" | python3 -c "
import json,sys
for n in json.load(sys.stdin):
    status = n['Checks'][-1]['Status'] if n['Checks'] else 'unknown'
    print(f'  [{status:8}] {n[\"Node\"][\"Node\"]} @ {n[\"Node\"][\"Address\"]}')
" || echo "  (could not reach DC4)"

echo ""
echo "==> Demo complete."
