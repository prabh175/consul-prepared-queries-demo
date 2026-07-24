#!/usr/bin/env bash
# Bootstrap the DC4 Consul server VM (also runs mesh-gw and consul-esm).
# Usage: sudo bash bootstrap-dc4-server.sh <DC3_PEER_TOKEN>
#
# Optional env var CONSUL_MGMT_TOKEN: if set, the script provisions a dedicated
# consul-esm ACL policy + token and injects it into esm.hcl. Provide this whenever the
# anonymous token is restricted (default_policy=deny, or an explicit service:write deny
# on anonymous) so ESM does not depend on anonymous permissions. The token is written
# only to /etc/consul-esm/esm.hcl on the server and is never committed.
#
# Before running, SCP from repo root:
#   scp -i $KEY_W2 -r vm/ ubuntu@$DC4_SERVER_PUB:/tmp/
#   scp -i $KEY_W2 vm/consul_*.zip ubuntu@$DC4_SERVER_PUB:/tmp/
#   scp -i $KEY_W2 vm/license.hclic ubuntu@$DC4_SERVER_PUB:/tmp/consul.hclic
#   # consul-esm is downloaded automatically if not present at /tmp/consul-esm_*.zip
#   ssh -i $KEY_W2 ubuntu@$DC4_SERVER_PUB "sudo CONSUL_MGMT_TOKEN='<MGMT_TOKEN>' bash /tmp/vm/scripts/bootstrap-dc4-server.sh '<PEER_TOKEN>'"
#
# Get <PEER_TOKEN> from DC3 server: consul peering generate-token -name dc4-esm
set -euo pipefail

DC3_PEER_TOKEN="${1:?Usage: $0 <DC3_PEER_TOKEN>}"

VM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# IMDSv2
IMDS_TOKEN=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 600")
PRIVATE_IP=$(curl -sf -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  http://169.254.169.254/latest/meta-data/local-ipv4)
PUBLIC_IP=$(curl -sf -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  http://169.254.169.254/latest/meta-data/public-ipv4 || echo "")

echo "==> bootstrap-dc4-server | private: ${PRIVATE_IP} | public: ${PUBLIC_IP}"

# --- Consul user + dirs ---
useradd --system --home /etc/consul.d --shell /bin/false consul 2>/dev/null || true
mkdir -p /etc/consul.d /opt/consul/data
chown -R consul:consul /etc/consul.d /opt/consul/data

# --- Consul binary ---
unzip -o /tmp/consul_*.zip consul -d /usr/bin/
chmod +x /usr/bin/consul
consul version

# --- Server config ---
sed "s/REPLACE_WITH_PRIVATE_IP/${PRIVATE_IP}/g" \
  "${VM_DIR}/consul/dc4-server.hcl" > /etc/consul.d/server.hcl
chown consul:consul /etc/consul.d/server.hcl

# --- License ---
install -m 0640 -o consul -g consul /tmp/consul.hclic /etc/consul.d/consul.hclic

# --- Consul service ---
cp "${VM_DIR}/consul/consul.service" /etc/systemd/system/consul.service
systemctl daemon-reload
systemctl reset-failed consul.service 2>/dev/null || true
systemctl enable --now consul
echo "==> Consul started, waiting for leader election..."
until curl -sf http://127.0.0.1:8500/v1/status/leader 2>/dev/null | grep -qE '[0-9]'; do
  echo "  ... not ready yet"
  sleep 3
done
echo "==> Leader elected"
consul members

# --- Envoy (required by consul connect envoy for mesh gateway) ---
# AMI ships Envoy 1.38.x which is incompatible with Consul 1.21.x bootstrap config format.
# Always install a known-compatible build (1.31.x) from tetratelabs archive.
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
echo "==> Envoy version: $(/usr/local/bin/envoy --version 2>&1 | head -1)"

# --- Mesh gateway (VPC peering: both -address and -wan-address use private IP) ---
sed -e "s/REPLACE_WITH_PRIVATE_IP/${PRIVATE_IP}/g" \
    "${VM_DIR}/consul/mesh-gateway.service" > /etc/systemd/system/mesh-gateway.service
systemctl daemon-reload
systemctl enable --now mesh-gateway
echo "==> Mesh gateway started (WAN: ${PRIVATE_IP}:8443)"

# --- Establish cluster peering back to DC3 ---
echo "==> Establishing cluster peer to dc3-vm..."
consul peering delete -name dc3-vm >/dev/null 2>&1 || true
consul peering establish -name dc3-vm -peering-token "${DC3_PEER_TOKEN}"
echo "==> Peering established. Verify: consul peering list"

# --- consul-esm install ---
if compgen -G "/tmp/consul-esm_*.zip" > /dev/null; then
  unzip -o /tmp/consul-esm_*.zip consul-esm -d /usr/bin/ 2>/dev/null || \
    unzip -o /tmp/consul-esm_*.zip -d /tmp/esm_extract && \
    install -m 0755 /tmp/esm_extract/consul-esm /usr/bin/consul-esm
  chmod +x /usr/bin/consul-esm
else
  echo "==> Downloading consul-esm..."
  curl -fsSL 'https://releases.hashicorp.com/consul-esm/0.7.2/consul-esm_0.7.2_linux_amd64.zip' \
    -o /tmp/consul-esm.zip || { echo "ERROR: consul-esm download failed"; exit 1; }
  unzip -o /tmp/consul-esm.zip -d /tmp/esm_extract
  install -m 0755 /tmp/esm_extract/consul-esm /usr/bin/consul-esm
  rm -rf /tmp/consul-esm.zip /tmp/esm_extract
fi
consul-esm -version || { echo "ERROR: consul-esm binary not functional after install"; exit 1; }

# --- ESM config ---
mkdir -p /etc/consul-esm
cp "${VM_DIR}/esm/esm.hcl" /etc/consul-esm/esm.hcl

# --- ESM ACL token (only when a management token is supplied) ---
# ESM registers a "consul-esm" service and writes external node/service health. Under a
# restricted anonymous token it gets 403 on service:write and crash-loops, freezing every
# external check. Provision a dedicated token so ESM never relies on anonymous perms.
if [[ -n "${CONSUL_MGMT_TOKEN:-}" ]]; then
  echo "==> Provisioning consul-esm ACL policy + token..."
  export CONSUL_HTTP_TOKEN="${CONSUL_MGMT_TOKEN}"
  cat > /tmp/esm-policy.hcl <<'POLICY'
node_prefix "" { policy = "write" }
service_prefix "" { policy = "write" }
agent_prefix "" { policy = "read" }
session_prefix "" { policy = "write" }
key_prefix "consul-esm/" { policy = "write" }
POLICY
  consul acl policy create -name consul-esm -rules @/tmp/esm-policy.hcl >/dev/null 2>&1 || \
    echo "    (consul-esm policy already exists — reusing)"
  ESM_TOKEN=$(consul acl token create -description "consul-esm dc4" \
    -policy-name consul-esm -format=json | python3 -c "import json,sys;print(json.load(sys.stdin)['SecretID'])")
  rm -f /tmp/esm-policy.hcl
  unset CONSUL_HTTP_TOKEN
  if [[ -n "${ESM_TOKEN}" ]]; then
    sed -i '/^token *= *"/d' /etc/consul-esm/esm.hcl
    echo "token = \"${ESM_TOKEN}\"" >> /etc/consul-esm/esm.hcl
    echo "==> consul-esm token written to /etc/consul-esm/esm.hcl"
  else
    echo "WARNING: failed to mint consul-esm token — ESM will run with anonymous perms"
  fi
fi

# --- ESM service ---
cp "${VM_DIR}/esm/esm.service" /etc/systemd/system/consul-esm.service
systemctl daemon-reload
systemctl enable --now consul-esm
echo "==> consul-esm started"

echo "==> bootstrap-dc4-server complete"
echo "    Consul UI: http://${PUBLIC_IP:-$PRIVATE_IP}:8500/ui/"
echo ""
echo "    Next steps:"
echo "    1. Bootstrap DC4 hashicups VMs: bash bootstrap-dc4-hashicups.sh"
echo "    2. Register external nodes: bash vm/esm/register-dc4-services.sh <IPs...>"
echo "    3. Bootstrap terminating-gw VM: bash bootstrap-dc4-terminating-gw.sh $PRIVATE_IP"
