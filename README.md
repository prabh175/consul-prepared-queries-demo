# Consul Prepared Queries — Geo-Failover Demo

F5 GTM-like geo-failover using Consul prepared queries across two VM-based datacenters in separate AWS regions.

## Architecture

### Current (Scenarios A + B) — VM-based, two regions

```
DC3 (us-east-1) — Native agents          DC4 (us-west-2) — ESM external
─────────────────────────────────        ─────────────────────────────────
Consul server (control plane             Consul server (control plane
  for DC3 + DC5 partition)                 for DC4 + DC6 partition)
  └─ mesh-gw (port 8443)                   └─ mesh-gw (port 8443)
  └─ DNS NLB (port 53 → 8600)              └─ DNS NLB (port 53 → 8600)
product-api × 3  ← native agents         product-api × 3  ← ESM
postgres, payments, public-api, frontend  postgres, payments, public-api, frontend

             ◄──── Cluster Peer (mesh-gw ↔ mesh-gw, TCP 8443) ────►
```

### Full (Scenarios A–D) — adds K8s clusters

```
us-east-1 PRIMARY                        us-west-2 FAILOVER
──────────────────────────────────────   ──────────────────────────────────────
DC3 (VMs, control plane for DC3+DC5)     DC4 (VMs, control plane for DC4+DC6)
  postgres, product-api (data layer)       product-api × 3 (ESM)
  payments, public-api, frontend           └─ sameness group with DC6

DC5 (EKS, admin partition dc5-k8s)      DC6 (EKS, admin partition dc6-k8s)
  frontend, public-api, payments           ALL HashiCups (apps + postgres)
  (app layer — connects to DC3 data)       catalog sync only, no mesh
  mesh-gw (cross-partition)               └─ sameness group with DC4
  terminating-gw (→ DC3 postgres)
```

DC5 and DC6 share no connection — they belong to different control planes in different regions.

## Prerequisites

- AWS credentials with EC2/VPC/Route53 permissions
- Consul Enterprise binary zip + `.hclic` license
- `consul-esm` binary zip (or internet access to download on DC4 server)
- Terraform ≥ 1.5
- EC2 key pair in both `us-east-1` and `us-west-2`

## Deployment Order

### Phase 1 — Infrastructure

Run all commands from the **repo root** (`Prepared_Queries/`). The `-chdir=` flag keeps Terraform in the right module directory without changing your shell's working directory — this matters because later phases reference files like `vm/scripts/...` relative to the root.

Each module creates its own VPC — no pre-existing infrastructure required.

VPC peering between DC3 and DC4 requires a three-step apply: DC4 first (to get its VPC ID), then DC3 (which creates the peering request), then DC4 again (to accept it and add the route). The peering tightens port 8443 from `0.0.0.0/0` to only the peer VPC CIDR.

```bash
# Step 1 — DC4 (us-west-2) first: we need its VPC ID for the DC3 peering request
cp terraform/dc4/terraform.tfvars.example terraform/dc4/terraform.tfvars
# Edit terraform/dc4/terraform.tfvars: set ssh_key_name and operator_public_cidr
# Leave peer_connection_id = "" for now
terraform -chdir=terraform/dc4 init
terraform -chdir=terraform/dc4 apply
export DC4_SERVER_PUB=$(terraform -chdir=terraform/dc4 output -raw consul_server_public_ip)
export DC4_SERVER_PRIV=$(terraform -chdir=terraform/dc4 output -raw consul_server_private_ip)
export DC4_TERM_GW_PUB=$(terraform -chdir=terraform/dc4 output -raw terminating_gw_public_ip)
export DC4_TERM_GW_PRIV=$(terraform -chdir=terraform/dc4 output -raw terminating_gw_private_ip)
export DC4_EIP=$(terraform -chdir=terraform/dc4 output -raw consul_dns_endpoint)
export DC4_VPC_ID=$(terraform -chdir=terraform/dc4 output -raw vpc_id)

# Step 2 — DC3 (us-east-1): fill in peer_vpc_id, then apply to create the peering request
cp terraform/dc3/terraform.tfvars.example terraform/dc3/terraform.tfvars
# Edit terraform/dc3/terraform.tfvars: set ssh_key_name, operator_public_cidr, and:
#   peer_vpc_id = "$DC4_VPC_ID"
terraform -chdir=terraform/dc3 init
terraform -chdir=terraform/dc3 apply
export DC3_SERVER_PUB=$(terraform -chdir=terraform/dc3 output -raw consul_server_public_ip)
export DC3_SERVER_PRIV=$(terraform -chdir=terraform/dc3 output -raw consul_server_private_ip)
export DC3_EIP=$(terraform -chdir=terraform/dc3 output -raw consul_dns_endpoint)
export PEER_CONN_ID=$(terraform -chdir=terraform/dc3 output -raw peering_connection_id)

# Step 3 — DC4 again: fill in peer_connection_id to accept the peering and add the route
# Edit terraform/dc4/terraform.tfvars:
#   peer_connection_id = "$PEER_CONN_ID"
terraform -chdir=terraform/dc4 apply
```

Set your SSH key paths (same `.pem` file works for both regions if you imported it):

```bash
export KEY=vm/devops-keypair.pem
export KEY_W2=vm/devops-keypair.pem
```

**DNS NLBs** are provisioned automatically by `terraform apply` for both DCs. Export their IPs after each apply:

```bash
export DC3_NLB_IP=$(terraform -chdir=terraform/dc3 output -raw consul_dns_nlb_ip)
export DC4_NLB_IP=$(terraform -chdir=terraform/dc4 output -raw consul_dns_nlb_ip)
```

These are used in Phase 8 (bastion DNS config) and as conditional forwarder targets for any org DNS server that needs to resolve the `consul.prabhjit-singh.sbx.hashidemos.io` sub-zone.

### Phase 2 — Bootstrap DC3 Server

```bash
rsync -a --exclude='*.pem' -e "ssh -i $KEY" vm/ ubuntu@$DC3_SERVER_PUB:/tmp/vm/
scp -i $KEY vm/consul_*.zip ubuntu@$DC3_SERVER_PUB:/tmp/
scp -i $KEY vm/license.hclic ubuntu@$DC3_SERVER_PUB:/tmp/consul.hclic
ssh -i $KEY ubuntu@$DC3_SERVER_PUB "sudo bash /tmp/vm/scripts/bootstrap-dc3-server.sh"

# Generate peering token for DC4
ssh -i $KEY ubuntu@$DC3_SERVER_PUB \
  "consul peering generate-token -name dc4-esm" > /tmp/dc4-peer-token.txt
```

### Phase 3 — Bootstrap DC4 Server

The bootstrap script installs three services on this VM: `consul` (server), `mesh-gateway`, and `consul-esm`. ESM is downloaded automatically from HashiCorp releases unless you pre-stage a `consul-esm_*.zip` at `/tmp/` on the server (useful in air-gapped environments).

```bash
rsync -a --exclude='*.pem' -e "ssh -i $KEY_W2" vm/ ubuntu@$DC4_SERVER_PUB:/tmp/vm/
scp -i $KEY_W2 vm/consul_*.zip ubuntu@$DC4_SERVER_PUB:/tmp/
scp -i $KEY_W2 vm/license.hclic ubuntu@$DC4_SERVER_PUB:/tmp/consul.hclic
# Optional: pre-stage ESM binary to avoid download (air-gapped envs)
# scp -i $KEY_W2 vm/consul-esm_*.zip ubuntu@$DC4_SERVER_PUB:/tmp/
PEER_TOKEN=$(cat /tmp/dc4-peer-token.txt)
ssh -i $KEY_W2 ubuntu@$DC4_SERVER_PUB \
  "sudo bash /tmp/vm/scripts/bootstrap-dc4-server.sh '${PEER_TOKEN}'"
```

After bootstrap, verify all three services are active before proceeding:

```bash
ssh -i $KEY_W2 ubuntu@$DC4_SERVER_PUB \
  "sudo systemctl is-active consul mesh-gateway consul-esm"
# Expected: active / active / active
```

### Phase 4 — Bootstrap DC3 HashiCups VMs

A single loop handles all 7 VMs. The role is derived from the instance key by stripping the trailing numeric suffix (`product-api-1` → `product-api`).

```bash
terraform -chdir=terraform/dc3 output -json hashicups_public_ips | \
  jq -r 'to_entries[] | "\(.key) \(.value)"' | \
while read INSTANCE_KEY PUBLIC_IP; do
  ROLE=$(echo "$INSTANCE_KEY" | sed 's/-[0-9]*$//')
  echo "==> ${INSTANCE_KEY} (${ROLE}) @ ${PUBLIC_IP}"
  rsync -a --no-progress --exclude='*.pem' -e "ssh -i $KEY -o StrictHostKeyChecking=no" \
    vm/ ubuntu@${PUBLIC_IP}:/tmp/vm/
  scp -i $KEY -o StrictHostKeyChecking=no vm/consul_*.zip ubuntu@${PUBLIC_IP}:/tmp/
  scp -i $KEY -o StrictHostKeyChecking=no vm/license.hclic ubuntu@${PUBLIC_IP}:/tmp/consul.hclic
  ssh -n -i $KEY -o StrictHostKeyChecking=no ubuntu@${PUBLIC_IP} \
    "sudo bash /tmp/vm/scripts/bootstrap-dc3-hashicups.sh ${DC3_SERVER_PRIV}"
  ssh -n -i $KEY -o StrictHostKeyChecking=no ubuntu@${PUBLIC_IP} \
    "sudo bash /tmp/vm/hashicups/scripts/on-${ROLE}.sh"
done
```

Verify all 7 nodes joined the DC3 cluster:

```bash
ssh -i $KEY ubuntu@$DC3_SERVER_PUB "consul members"
# Expect: dc3-consul-server + dc3-<role> for all 7 hashicups VMs
```

### Phase 5 — Bootstrap DC4 HashiCups VMs

DC4 VMs run Docker only — no Consul agent installed.

```bash
DC4_PRIV=$(terraform -chdir=terraform/dc4 output -json hashicups_private_ips)
DC4_PUB=$(terraform -chdir=terraform/dc4 output -json hashicups_public_ips)

POSTGRES_IP=$(echo $DC4_PRIV | jq -r '.postgres')
PA1_IP=$(echo $DC4_PRIV | jq -r '."product-api-1"')
PA2_IP=$(echo $DC4_PRIV | jq -r '."product-api-2"')
PA3_IP=$(echo $DC4_PRIV | jq -r '."product-api-3"')
PAYMENTS_IP=$(echo $DC4_PRIV | jq -r '.payments')
PUBLIC_API_IP=$(echo $DC4_PRIV | jq -r '."public-api"')
FRONTEND_IP=$(echo $DC4_PRIV | jq -r '.frontend')

# DC4 hashicups VMs only need the vm/ directory (Docker only, no consul binary)
_scp4() { rsync -a --exclude='*.pem' -e "ssh -i $KEY_W2" vm/ ubuntu@$1:/tmp/vm/; }

POSTGRES_PUB=$(echo $DC4_PUB | jq -r '.postgres')
_scp4 $POSTGRES_PUB
ssh -i $KEY_W2 ubuntu@$POSTGRES_PUB \
  "sudo bash /tmp/vm/scripts/bootstrap-dc4-hashicups.sh postgres"

for N in 1 2 3; do
  PA_PUB=$(echo $DC4_PUB | jq -r ".[\"product-api-$N\"]")
  _scp4 $PA_PUB
  ssh -i $KEY_W2 ubuntu@$PA_PUB \
    "sudo bash /tmp/vm/scripts/bootstrap-dc4-hashicups.sh product-api $POSTGRES_IP"
done

PAYMENTS_PUB=$(echo $DC4_PUB | jq -r '.payments')
_scp4 $PAYMENTS_PUB
ssh -i $KEY_W2 ubuntu@$PAYMENTS_PUB \
  "sudo bash /tmp/vm/scripts/bootstrap-dc4-hashicups.sh payments"

PUBLIC_API_PUB=$(echo $DC4_PUB | jq -r '."public-api"')
_scp4 $PUBLIC_API_PUB
ssh -i $KEY_W2 ubuntu@$PUBLIC_API_PUB \
  "sudo bash /tmp/vm/scripts/bootstrap-dc4-hashicups.sh public-api $PA1_IP $PAYMENTS_IP"

FRONTEND_PUB=$(echo $DC4_PUB | jq -r '.frontend')
_scp4 $FRONTEND_PUB
ssh -i $KEY_W2 ubuntu@$FRONTEND_PUB \
  "sudo bash /tmp/vm/scripts/bootstrap-dc4-hashicups.sh frontend $PUBLIC_API_IP"
```

### Phase 6 — Register DC4 External Nodes + Terminating Gateway

```bash
# Register DC4 service VMs in Consul via ESM
ssh -i $KEY_W2 ubuntu@$DC4_SERVER_PUB "
  bash /tmp/vm/esm/register-dc4-services.sh \
    --postgres      $POSTGRES_IP \
    --product-api-1 $PA1_IP \
    --product-api-2 $PA2_IP \
    --product-api-3 $PA3_IP \
    --payments      $PAYMENTS_IP \
    --public-api    $PUBLIC_API_IP \
    --frontend      $FRONTEND_IP
"

# Bootstrap terminating-gateway VM
rsync -a --no-progress --exclude='*.pem' -e "ssh -i $KEY_W2" vm/ ubuntu@$DC4_TERM_GW_PUB:/tmp/vm/
scp -i $KEY_W2 vm/consul_*.zip ubuntu@$DC4_TERM_GW_PUB:/tmp/
scp -i $KEY_W2 vm/license.hclic ubuntu@$DC4_TERM_GW_PUB:/tmp/consul.hclic
ssh -i $KEY_W2 ubuntu@$DC4_TERM_GW_PUB \
  "sudo bash /tmp/vm/scripts/bootstrap-dc4-terminating-gw.sh $DC4_SERVER_PRIV"
```

### Phase 7 — Apply Peering Configs + Register Prepared Queries

This single script applies exported-services (bidirectional), the terminating-gateway config entry on DC4, and registers the prepared query on **both** DCs. Run it from your laptop.

```bash
# Run from your laptop — requires port 8500 open to your IP (set operator_public_cidr in tfvars).
export DC3_IP=$DC3_SERVER_PUB
export DC4_IP=$DC4_SERVER_PUB
bash vm/scripts/apply-peering-configs.sh
```

### Phase 8 — Provision Bastion Host

The bastion is a t3.micro in DC3's VPC. Its systemd-resolved is configured with both DC
DNS NLB IPs as nameservers — DC3 primary, DC4 secondary. When DC3's NLB is unreachable
(Scenario B), the OS falls back to DC4's NLB within ~2 seconds with no manual
intervention.

**Step 1 — Enable the bastion in DC3 tfvars:**

```bash
# In terraform/dc3/terraform.tfvars, set:
#   enable_bastion = true
terraform -chdir=terraform/dc3 apply
export BASTION_PUB=$(terraform -chdir=terraform/dc3 output -raw bastion_public_ip)
```

**Step 2 — Allow the bastion IP in both security groups:**

```bash
# In terraform/dc3/terraform.tfvars AND terraform/dc4/terraform.tfvars, set:
#   bastion_public_cidr = "<BASTION_PUB>/32"
terraform -chdir=terraform/dc3 apply
terraform -chdir=terraform/dc4 apply
```

**Step 3 — Copy scripts and configure DNS:**

```bash
rsync -av --exclude='*.pem' -e "ssh -i $KEY" vm/ ubuntu@$BASTION_PUB:/tmp/vm/
ssh -i $KEY ubuntu@$BASTION_PUB \
  "sudo bash /tmp/vm/scripts/bootstrap-bastion.sh $DC3_NLB_IP $DC4_NLB_IP"
```

This writes `/etc/systemd/resolved.conf.d/consul-dns.conf` with both NLB IPs. Non-`.consul`
queries are forwarded by Consul to the VPC DNS resolver (169.254.169.253) via `recursors`
in the server HCL.

**Step 4 — Verify:**

```bash
ssh -i $KEY ubuntu@$BASTION_PUB 'dig product-api-geo.query.consul. A +short'
# Should return 3 DC3 IPs (10.10.x.x) while DC3 is healthy
ssh -i $KEY ubuntu@$BASTION_PUB \
  'dig product-api-geo.query.consul.prabhjit-singh.sbx.hashidemos.io. A +short'
# Same result via org sub-zone (alt_domain)
```

### Phase 9 — Run Demo Walkthrough

Running from your laptop — all IPs must be **public** (Consul API on 8500 and SSH both require it).

```bash
# Set env vars required by the walkthrough script
export DC3_IP=$DC3_SERVER_PUB
export DC4_IP=$DC4_SERVER_PUB
export DC3_SERVER_PUB=$DC3_SERVER_PUB
export BASTION_PUB=$(terraform -chdir=terraform/dc3 output -raw bastion_public_ip)
export KEY=<path to us-east-1 key>

DC3_HC_PUB=$(terraform -chdir=terraform/dc3 output -json hashicups_public_ips)
export DC3_PA1_IP=$(echo $DC3_HC_PUB | jq -r '."product-api-1"')
export DC3_PA2_IP=$(echo $DC3_HC_PUB | jq -r '."product-api-2"')
export DC3_PA3_IP=$(echo $DC3_HC_PUB | jq -r '."product-api-3"')

bash prepared-queries/demo-walkthrough.sh
```

**DNS lookups from laptop:** UDP port 8600 is not open in the operator SG rule — use `+tcp`:
```bash
dig +tcp @$DC3_SERVER_PUB -p 8600 product-api-geo.query.consul. ANY
dig +tcp @$DC3_SERVER_PUB -p 8600 product-api-local.query.consul. ANY
```

> **Ready to demo?** Phase 9 is a scripted sanity check. For the live customer walkthrough — narrative, what to show, and talking points — see **[DEMO-GUIDE.md](DEMO-GUIDE.md)**.

### Phase 10 — DC5 EKS Mesh Cluster (Scenario D)

DC5 is an EKS cluster (single node, t3.medium) in us-east-1 that connects to DC3's Consul
server as admin partition `dc5-k8s`. It runs the HashiCups app layer (frontend, public-api,
payments, product-api) with full Connect mesh, a mesh gateway for cross-partition
communication, and a terminating gateway so mesh services can reach DC3's postgres across
the partition boundary.

**Step 1 — Enable K8s partition ingress on DC3 and export its outputs:**

```bash
# In terraform/dc3/terraform.tfvars, add:
#   enable_k8s_partition = true
terraform -chdir=terraform/dc3 apply

export DC3_VPC_ID=$(terraform -chdir=terraform/dc3 output -raw vpc_id)
export DC3_VPC_CIDR=$(terraform -chdir=terraform/dc3 output -raw vpc_cidr)
export DC3_SG_ID=$(terraform -chdir=terraform/dc3 output -raw security_group_id)
```

**Step 2 — Create the dc5-k8s admin partition before helm install:**

```bash
bash vm/scripts/create-partitions.sh
```

**Step 3 — Provision DC5 EKS cluster:**

```bash
cp terraform/dc5/terraform.tfvars.example terraform/dc5/terraform.tfvars
# Edit terraform/dc5/terraform.tfvars — fill in:
#   dc3_vpc_id            = "$DC3_VPC_ID"
#   dc3_vpc_cidr          = "$DC3_VPC_CIDR"
#   dc3_subnet_ids        = <paste JSON from: terraform -chdir=terraform/dc3 output -json subnet_ids>
#   dc3_security_group_id = "$DC3_SG_ID"
#   operator_public_cidr  = "YOUR_IP/32"
#   ssh_key_name          = "devops-keypair"
terraform -chdir=terraform/dc5 init
terraform -chdir=terraform/dc5 apply
eval "$(terraform -chdir=terraform/dc5 output -raw kubeconfig_hint)"
```

**Step 4 — Create enterprise license secret and install consul-k8s:**

```bash
kubectl create secret generic consul-ent-license \
  --from-file=key=vm/license.hclic \
  --namespace consul --create-namespace --context dc5

# Edit k8s/dc5/consul-values.yaml: replace REPLACE_WITH_DC3_SERVER_IP with $DC3_SERVER_PRIV
helm repo add hashicorp https://helm.releases.hashicorp.com
helm install consul hashicorp/consul \
  --namespace consul \
  --version 1.6.x \
  -f k8s/dc5/consul-values.yaml \
  --kube-context dc5

kubectl get pods -n consul --context dc5 --watch
```

**Step 5 — Deploy HashiCups app layer and apply Consul config:**

```bash
kubectl apply -f k8s/dc5/workloads.yaml --context dc5
kubectl apply -f k8s/dc5/service-intentions.yaml --context dc5
kubectl apply -f k8s/dc5/terminating-gateway.yaml --context dc5
kubectl apply -f k8s/dc5/exported-services.yaml --context dc5
```

**Step 6 — Push updated DC3 exported-services (adds postgres → dc5-k8s consumer):**

```bash
curl -s -X PUT "http://$DC3_SERVER_PUB:8500/v1/config" \
  -H "Content-Type: application/json" \
  -d @vm/consul/exported-services-dc3.json
```

**Verify:**

```bash
curl -s "http://$DC3_SERVER_PUB:8500/v1/health/service/product-api?passing&partition=dc5-k8s" | \
  python3 -c "import json,sys; s=json.load(sys.stdin); print('DC5 K8s passing:', len(s))"
```

> **Dependencies:** DC3 must be fully deployed (Phases 1–7). The dc5-k8s partition must
> exist (Step 2) before helm install — it is not created automatically.

---

### Phase 11 — DC6 EKS Service Discovery Cluster (Scenario C)

DC6 is an EKS cluster (single node, t3.small) in us-west-2 that connects to DC4's Consul
server as admin partition `dc6-k8s`. It runs all HashiCups components together (apps +
postgres) as a self-contained failover target. Catalog sync registers K8s services into
DC4's Consul catalog — no mesh, no sidecars, no gateways.

**Step 1 — Enable K8s partition ingress on DC4 and export its outputs:**

```bash
# In terraform/dc4/terraform.tfvars, add:
#   enable_k8s_partition = true
terraform -chdir=terraform/dc4 apply

export DC4_VPC_ID=$(terraform -chdir=terraform/dc4 output -raw vpc_id)
export DC4_VPC_CIDR=$(terraform -chdir=terraform/dc4 output -raw vpc_cidr)
export DC4_SG_ID=$(terraform -chdir=terraform/dc4 output -raw security_group_id)
```

**Step 2 — Create the dc6-k8s admin partition before helm install:**

```bash
# create-partitions.sh creates both dc5-k8s and dc6-k8s — safe to re-run.
bash vm/scripts/create-partitions.sh
```

**Step 3 — Provision DC6 EKS cluster:**

```bash
cp terraform/dc6/terraform.tfvars.example terraform/dc6/terraform.tfvars
# Edit terraform/dc6/terraform.tfvars — fill in:
#   dc4_vpc_id            = "$DC4_VPC_ID"
#   dc4_vpc_cidr          = "$DC4_VPC_CIDR"
#   dc4_subnet_ids        = <paste JSON from: terraform -chdir=terraform/dc4 output -json subnet_ids>
#   dc4_security_group_id = "$DC4_SG_ID"
#   operator_public_cidr  = "YOUR_IP/32"
#   ssh_key_name          = "devops-keypair"
terraform -chdir=terraform/dc6 init
terraform -chdir=terraform/dc6 apply
eval "$(terraform -chdir=terraform/dc6 output -raw kubeconfig_hint)"
```

**Step 4 — Create enterprise license secret and install consul-k8s:**

```bash
kubectl create secret generic consul-ent-license \
  --from-file=key=vm/license.hclic \
  --namespace consul --create-namespace --context dc6

# Edit k8s/dc6/consul-values.yaml: replace REPLACE_WITH_DC4_SERVER_IP with $DC4_SERVER_PRIV
helm install consul hashicorp/consul \
  --namespace consul \
  --version 1.6.x \
  -f k8s/dc6/consul-values.yaml \
  --kube-context dc6

kubectl get pods -n consul --context dc6 --watch
```

**Step 5 — Deploy all HashiCups components:**

```bash
kubectl apply -f k8s/dc6/workloads.yaml --context dc6
```

**Verify catalog sync:**

```bash
curl -s "http://$DC4_SERVER_PUB:8500/v1/health/service/product-api?passing&partition=dc6-k8s" | \
  python3 -c "import json,sys; s=json.load(sys.stdin); print('DC6 K8s passing:', len(s))"
```

> **Dependencies:** DC4 must be fully deployed (Phases 1–6).

---

### Phase 12 — Configure Sameness Group (Scenario C)

Defines a sameness group `dc4-dc6-product-api` spanning DC4's default partition (VMs) and
the dc6-k8s partition (K8s). Consul automatically routes away from unhealthy VM instances
to K8s instances — no prepared query required. Adding a new service to either partition
automatically inherits the same failover policy.

```bash
export DC4_SERVER_PUB=$(terraform -chdir=terraform/dc4 output -raw consul_server_public_ip)
bash vm/scripts/apply-sameness-group.sh
```

> **Dependencies:** Phases 6 and 11 must be complete. DC6 services must be synced and
> passing health checks in DC4's catalog before applying.

---

### Phase 13 — Register DC5 Prepared Query + Peering (Scenario D)

Establishes partition-level peering between DC5 (dc5-k8s partition of DC3) and DC4, then
registers `product-api-hybrid` — a prepared query that targets DC5 K8s instances first and
falls back to DC4 VM instances via the peer.

**Step 1 — Generate peering token on DC4 (acceptor side):**

```bash
curl -s -X POST "http://$DC4_SERVER_PUB:8500/v1/peering/token" \
  -d '{"PeerName":"dc5-k8s-peer","Partition":"default"}' \
  | jq -r '.PeeringToken' > /tmp/dc5-peering-token.txt
```

**Step 2 — Load token into DC5 K8s and apply the PeeringDialer:**

```bash
kubectl create secret generic dc4-peering-token \
  --from-file=data=/tmp/dc5-peering-token.txt \
  --namespace consul --context dc5
kubectl apply -f k8s/dc5/peering-dc4.yaml --context dc5
```

Verify peering is ACTIVE:
```bash
curl -s "http://$DC4_SERVER_PUB:8500/v1/peerings" | \
  python3 -c "import json,sys; [print(p['Name'], '→', p['State']) for p in json.load(sys.stdin)]"
# Expected: dc5-k8s-peer → ACTIVE
```

**Step 3 — Register the DC5 prepared query:**

```bash
CONSUL_HTTP_ADDR="http://$DC3_SERVER_PUB:8500" DC=dc5 \
  bash prepared-queries/register-queries.sh
```

Verify:
```bash
curl -s "http://$DC3_SERVER_PUB:8500/v1/query?partition=dc5-k8s" | \
  python3 -c "import json,sys; [print(q['Name']) for q in json.load(sys.stdin)]"
# Expected: product-api-hybrid
```

> **Dependencies:** Phases 7, 10, and 11 must be complete.

## Key Demo Points

| Query | DNS name | Behavior |
|-------|----------|----------|
| `product-api-geo` | `product-api-geo.query.consul.` | Nearest DC first, auto-failover to peer |
| `product-api-local` | `product-api-local.query.consul.` | DC3 only — shows "site down" when DC3 fails |

**Failover trigger (service-level):** All DC3 product-api health checks go critical → prepared query `Failover.Targets[{Peer: dc4-esm}]` kicks in → resolves to DC4 ESM instances.

**Failover trigger (control-plane):** DC3 Consul server stops → bastion's systemd-resolved falls back to DC4's DNS NLB within ~2s → DC4's copy of the query resolves DC4-local ESM instances.

**Recovery:** DC3 instances/server recover → query returns to DC3 automatically (no manual intervention).

Mesh gateways communicate over the VPC peering link (TCP 8443) — port 8443 is restricted to the peer VPC CIDR on both sides.

## Troubleshooting

**`mesh-gateway.service` shows `REPLACE_WITH_*` literals**
The bootstrap script exits early (e.g. consul startup failure) before the `sed` substitution runs. Fix on the running VM:
```bash
ssh -i $KEY ubuntu@$SERVER_PUB bash <<'EOF'
  TOKEN=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
  PRIV=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)
  PUB=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4)
  sudo sed -i -e "s/REPLACE_WITH_PRIVATE_IP/${PRIV}/g" -e "s/REPLACE_WITH_PUBLIC_IP/${PUB}/g" \
    /etc/systemd/system/mesh-gateway.service
  sudo systemctl daemon-reload && sudo systemctl start mesh-gateway
EOF
```

**`consul_exporter` exits with `217/USER`**
The `consul_exporter` system user was not created (user_data failure). Fix: `sudo useradd --system --no-create-home --shell /bin/false consul_exporter && sudo systemctl restart consul_exporter`

**`mesh-gateway` inactive (dead) even though consul is running**
consul.service was in a failed state when mesh-gateway last tried to start. Fix: `sudo systemctl start mesh-gateway`

**Peering token embeds private IP (`:8503`) instead of mesh gateway public IP (`:8443`)**
Token was generated before mesh-gateway registered with Consul. Run delete and generate as **separate** SSH commands so the delete's stdout doesn't contaminate the token file: `ssh ... "consul peering delete -name dc4-esm" >/dev/null 2>&1 || true`, then `ssh ... "consul peering generate-token -name dc4-esm" > /tmp/dc4-peer-token.txt`. Re-run the DC4 bootstrap with the new token.

## Teardown

Destroy DC4 first — it holds the VPC peering accepter and route. Destroying DC3 first would remove the peering connection while DC4 still has a dangling route, causing Terraform errors.

```bash
terraform -chdir=terraform/dc4 destroy
terraform -chdir=terraform/dc3 destroy
```
