#!/usr/bin/env bash
# Configure DNS on the bastion for dual-DC Consul resolution via the DNS NLBs.
#
# Each DC has an NLB listening on port 53 that forwards to the local Consul
# server's DNS port (8600). The bastion points to both NLBs as nameservers —
# no dnsmasq or per-host tooling needed.
#
# Run from your laptop after the bastion VM is up:
#   ssh -i $KEY ubuntu@$BASTION_PUB "sudo bash /tmp/vm/scripts/bootstrap-bastion.sh \
#     $(terraform -chdir=terraform/dc3 output -raw consul_dns_nlb_ip) \
#     $(terraform -chdir=terraform/dc4 output -raw consul_dns_nlb_ip)"
#
# Failover behaviour: when DC3's NLB is unreachable (Scenario B), systemd-resolved
# falls back to DC4's NLB within ~2 seconds. Non-.consul queries are forwarded by
# Consul to 169.254.169.253 (VPC DNS) via the recursors setting in the server HCL.
set -euo pipefail

DC3_NLB_IP="${1:?Usage: $0 <DC3_NLB_IP> <DC4_NLB_IP>}"
DC4_NLB_IP="${2:?Usage: $0 <DC3_NLB_IP> <DC4_NLB_IP>}"

echo "==> Configuring DNS for dual-DC Consul resolution"
echo "    DC3 DNS NLB: ${DC3_NLB_IP}:53 (primary)"
echo "    DC4 DNS NLB: ${DC4_NLB_IP}:53 (secondary)"

# Ubuntu 24.04 uses systemd-resolved. A drop-in config file survives reboots
# and will not be overwritten by cloud-init or NetworkManager.
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/consul-dns.conf <<EOF
[Resolve]
DNS=${DC3_NLB_IP} ${DC4_NLB_IP}
Domains=~consul ~consul.prabhjit-singh.sbx.hashidemos.io
EOF

systemctl restart systemd-resolved
sleep 2

echo "==> Active DNS configuration:"
resolvectl status | grep -A5 "Global"

echo ""
echo "==> Test — .consul domain (expects 10.10.x.x from DC3 if healthy):"
dig product-api-geo.query.consul. A +short \
  || echo "  (failed — check Consul is running and NLB target group is healthy)"

echo ""
echo "==> Test — org sub-zone via alt_domain (expects same result):"
dig product-api-geo.query.consul.prabhjit-singh.sbx.hashidemos.io. A +short \
  || echo "  (failed — verify alt_domain is set in both Consul server HCL files)"

echo ""
echo "==> Bootstrap complete."
echo "    Primary:   ${DC3_NLB_IP} (DC3 NLB)"
echo "    Secondary: ${DC4_NLB_IP} (DC4 NLB)"
echo "    Failover:  ~2s when DC3 NLB is unreachable (Scenario B)"
