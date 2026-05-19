#!/usr/bin/env bash
# Bootstrap the DC4 terminating-gateway VM (Consul client + Envoy term-gw).
# Usage: sudo bash bootstrap-dc4-terminating-gw.sh <DC4_CONSUL_SERVER_IP>
#
# Before running, SCP from repo root:
#   scp -i $KEY_W2 -r vm/ ubuntu@$DC4_TERM_GW_PUB:/tmp/
#   scp -i $KEY_W2 vm/consul_*.zip ubuntu@$DC4_TERM_GW_PUB:/tmp/
#   ssh -i $KEY_W2 ubuntu@$DC4_TERM_GW_PUB \
#     "sudo bash /tmp/vm/scripts/bootstrap-dc4-terminating-gw.sh $DC4_CONSUL_SERVER_IP"
#
# After this script, apply the terminating-gateway config entry from DC4 server:
#   consul config write vm/terminating-gw/terminating-gateway.json
set -euo pipefail

CONSUL_SERVER_IP="${1:?Usage: $0 <DC4_CONSUL_SERVER_IP>}"

VM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# IMDSv2
IMDS_TOKEN=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 600")
PRIVATE_IP=$(curl -sf -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  http://169.254.169.254/latest/meta-data/local-ipv4)
NODE_NAME="dc4-terminating-gw"

echo "==> bootstrap-dc4-terminating-gw | node: ${NODE_NAME} | joining: ${CONSUL_SERVER_IP}"

# --- Consul user + dirs ---
useradd --system --home /etc/consul.d --shell /bin/false consul 2>/dev/null || true
mkdir -p /etc/consul.d /opt/consul/data
chown -R consul:consul /etc/consul.d /opt/consul/data

# --- Consul binary ---
unzip -o /tmp/consul_*.zip consul -d /usr/bin/
chmod +x /usr/bin/consul

# --- License ---
install -m 0640 -o consul -g consul /tmp/consul.hclic /etc/consul.d/consul.hclic

# --- Client config ---
sed -e "s/REPLACE_WITH_PRIVATE_IP/${PRIVATE_IP}/g" \
    -e "s/REPLACE_CONSUL_SERVER_IP/${CONSUL_SERVER_IP}/g" \
    -e "s/REPLACE_NODE_NAME/${NODE_NAME}/g" \
    "${VM_DIR}/consul/dc4-client.hcl" > /etc/consul.d/client.hcl
chown consul:consul /etc/consul.d/client.hcl

# --- Consul service ---
cp "${VM_DIR}/consul/consul.service" /etc/systemd/system/consul.service
systemctl daemon-reload
systemctl enable --now consul
echo "==> Waiting for Consul agent to join cluster..."
until consul members 2>/dev/null | grep -q "alive"; do
  echo "  ... not ready yet"
  sleep 3
done
consul members

# --- Envoy (terminating gateway) ---
ENVOY_VERSION="1.31.5"
ENVOY_CURRENT=$(/usr/local/bin/envoy --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "none")
if [[ "${ENVOY_CURRENT}" != "${ENVOY_VERSION}" ]]; then
  echo "==> Installing Envoy ${ENVOY_VERSION} (replacing ${ENVOY_CURRENT})..."
  curl -fsSL "https://github.com/tetratelabs/archive-envoy/releases/download/v${ENVOY_VERSION}/envoy-v${ENVOY_VERSION}-linux-amd64.tar.xz" \
    -o /tmp/envoy.tar.xz
  tar -xJf /tmp/envoy.tar.xz -C /tmp
  install -m 0755 "/tmp/envoy-v${ENVOY_VERSION}-linux-amd64/bin/envoy" /usr/local/bin/envoy
  rm -rf /tmp/envoy.tar.xz "/tmp/envoy-v${ENVOY_VERSION}-linux-amd64"
fi

# --- Terminating gateway systemd unit ---
cp "${VM_DIR}/terminating-gw/terminating-gw.service" \
  /etc/systemd/system/terminating-gw.service
systemctl daemon-reload
systemctl enable --now terminating-gw

echo "==> bootstrap-dc4-terminating-gw complete"
echo "    Verify: consul catalog services | grep terminating"
echo ""
echo "    Next: apply config entry from DC4 server:"
echo "    consul config write /tmp/vm/terminating-gw/terminating-gateway.json"
