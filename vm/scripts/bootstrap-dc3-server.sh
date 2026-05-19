#!/usr/bin/env bash
# Bootstrap the DC3 Consul server VM.
# Usage: sudo bash bootstrap-dc3-server.sh
#
# Before running, SCP from repo root:
#   scp -i $KEY -r vm/ ubuntu@$DC3_SERVER_PUB:/tmp/
#   scp -i $KEY vm/consul_*.zip ubuntu@$DC3_SERVER_PUB:/tmp/
#   scp -i $KEY vm/license.hclic ubuntu@$DC3_SERVER_PUB:/tmp/consul.hclic
#   ssh -i $KEY ubuntu@$DC3_SERVER_PUB "sudo bash /tmp/vm/scripts/bootstrap-dc3-server.sh"
#
# Terraform user_data pre-installs: docker, dnsmasq, node_exporter, consul_exporter binaries.
# This script configures + starts the services that need runtime values (IPs, license).
set -euo pipefail

VM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# IMDSv2
IMDS_TOKEN=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 600")
PRIVATE_IP=$(curl -sf -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  http://169.254.169.254/latest/meta-data/local-ipv4)
PUBLIC_IP=$(curl -sf -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  http://169.254.169.254/latest/meta-data/public-ipv4 || echo "")

echo "==> bootstrap-dc3-server | private: ${PRIVATE_IP} | public: ${PUBLIC_IP}"

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
  "${VM_DIR}/consul/dc3-server.hcl" > /etc/consul.d/server.hcl
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

# --- consul_exporter service ---
useradd --system --no-create-home --shell /bin/false consul_exporter 2>/dev/null || true
cat > /etc/systemd/system/consul_exporter.service <<'UNIT'
[Unit]
Description=Prometheus Consul Exporter
After=consul.service
Wants=consul.service

[Service]
User=consul_exporter
Group=consul_exporter
ExecStart=/usr/local/bin/consul_exporter \
  --consul.server=http://127.0.0.1:8500 \
  --web.listen-address=:9107
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now consul_exporter

# --- Lightweight Prometheus + Grafana on Docker (standalone monitoring) ---
cat > /opt/prometheus.yml <<EOF
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: consul
    static_configs:
      - targets: ['127.0.0.1:8500']
    metrics_path: /v1/agent/metrics
    params:
      format: ['prometheus']

  - job_name: consul_exporter
    static_configs:
      - targets: ['127.0.0.1:9107']

  - job_name: node
    static_configs:
      - targets: ['127.0.0.1:9100']
EOF

docker rm -f prometheus grafana 2>/dev/null || true
docker run -d --name prometheus --restart unless-stopped \
  --network host \
  -v /opt/prometheus.yml:/etc/prometheus/prometheus.yml:ro \
  prom/prometheus:v2.51.2 \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.retention.time=7d

docker run -d --name grafana --restart unless-stopped \
  --network host \
  -e GF_AUTH_ANONYMOUS_ENABLED=true \
  -e GF_AUTH_ANONYMOUS_ORG_ROLE=Admin \
  grafana/grafana:10.4.2

echo "==> bootstrap-dc3-server complete"
echo "    Consul UI : http://${PUBLIC_IP:-$PRIVATE_IP}:8500/ui/"
echo "    Prometheus: http://${PUBLIC_IP:-$PRIVATE_IP}:9090/"
echo "    Grafana   : http://${PUBLIC_IP:-$PRIVATE_IP}:3000/"
echo ""
echo "    Next: generate peering token for DC4"
echo "    consul peering generate-token -name dc4-esm"
