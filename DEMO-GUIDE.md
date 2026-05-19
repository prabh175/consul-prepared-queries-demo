# Consul Prepared Queries — Geo-Failover Demo

## Health-Aware Geo-Failover Without Application Changes

Most organisations running multi-region workloads rely on an F5 GTM or a cloud load
balancer to route DNS queries to the nearest healthy endpoint and fail over when a site
goes down. That approach is powerful, but it lives outside your service mesh — health
checks are shallow (TCP ping), config changes require a separate workflow, and the failover
logic doesn't know anything about the actual health of your application.

**Consul prepared queries bring that routing intelligence inside the service mesh.**

With a single DNS name — `product-api-geo.query.consul.` — Consul evaluates real
application health checks at query time and returns only healthy instances, sorted by
proximity. When all instances in the primary site fail, it automatically returns instances
from the peer datacenter. No application change, no DNS record update, no manual
intervention.

We will cover four scenarios across two regions and three deployment models:

| Scenario | What fails | Infrastructure | Mechanism |
|----------|-----------|----------------|-----------|
| **A — Service failure** | product-api containers on DC3 | DC3 + DC4 VMs | Prepared query, health-check driven |
| **B — Control plane failure** | DC3 Consul server | DC3 + DC4 VMs | Dual DNS NLB nameservers |
| **C — VM ↔ K8s failover** | DC4 VM product-api | DC4 VMs + DC6 K8s | Sameness group, cross-partition |
| **D — K8s mesh failover** | DC5 K8s app services | DC5 K8s + DC4 VMs | Prepared query, cross-peer from dc5-k8s partition |

Scenarios A and B use the existing VM infrastructure and can be run immediately after
README Phases 1–8. Scenarios C and D require the K8s clusters (README Phases 10–13).

---

## Before You Start

### Set environment variables

Run all commands from the repo root (`Prepared_Queries/`). `$KEY` is a relative path and
all SSH commands depend on it.

```bash
export KEY=vm/devops-keypair.pem

export DC3_SERVER_PUB=$(terraform -chdir=terraform/dc3 output -raw consul_server_public_ip)
export DC3_SERVER_PRIV=$(terraform -chdir=terraform/dc3 output -raw consul_server_private_ip)
export DC4_SERVER_PUB=$(terraform -chdir=terraform/dc4 output -raw consul_server_public_ip)
export DC3_NLB_IP=$(terraform -chdir=terraform/dc3 output -raw consul_dns_nlb_ip)
export DC4_NLB_IP=$(terraform -chdir=terraform/dc4 output -raw consul_dns_nlb_ip)
export BASTION_PUB=$(terraform -chdir=terraform/dc3 output -raw bastion_public_ip)   # if bastion provisioned — see README Phase 8

DC3_HC_PUB=$(terraform -chdir=terraform/dc3 output -json hashicups_public_ips)
export DC3_PA1_IP=$(echo $DC3_HC_PUB | jq -r '."product-api-1"')
export DC3_PA2_IP=$(echo $DC3_HC_PUB | jq -r '."product-api-2"')
export DC3_PA3_IP=$(echo $DC3_HC_PUB | jq -r '."product-api-3"')

DC4_HC_PUB=$(terraform -chdir=terraform/dc4 output -json hashicups_public_ips)
export DC4_PA1_IP=$(echo $DC4_HC_PUB | jq -r '."product-api-1"')
export DC4_PA2_IP=$(echo $DC4_HC_PUB | jq -r '."product-api-2"')
export DC4_PA3_IP=$(echo $DC4_HC_PUB | jq -r '."product-api-3"')
```

### Open the Consul UI

Keep these open in browser tabs throughout the demo — they give the customer a live visual
of health check state as you run each step:

- **Site 1:** `http://$DC3_SERVER_PUB:8500/ui`
- **Site 2:** `http://$DC4_SERVER_PUB:8500/ui`

### Pre-flight checks

Run these before the customer joins. If anything is not as expected, do not proceed.

```bash
# Prepared queries registered on Site 1
curl -s "http://$DC3_SERVER_PUB:8500/v1/query" | python3 -c "
import json,sys; qs=json.load(sys.stdin)
print('Registered queries:', [q['Name'] for q in qs])
"
# Expected: ['product-api-geo', 'product-api-local']

# Cluster peering is ACTIVE
curl -s "http://$DC3_SERVER_PUB:8500/v1/peerings" | python3 -c "
import json,sys
body=sys.stdin.read(); ps=json.loads(body) if body else []
for p in ps: print(p['Name'], '→', p['State'])
"
# Expected: dc4-esm → ACTIVE

# All product-api instances passing on Site 1
curl -s "http://$DC3_SERVER_PUB:8500/v1/health/service/product-api?passing" | \
  python3 -c "import json,sys; s=json.load(sys.stdin); print('Passing on Site 1:', len(s))"
# Expected: 3

# All product-api instances passing on Site 2
curl -s "http://$DC4_SERVER_PUB:8500/v1/health/service/product-api?passing" | \
  python3 -c "import json,sys; s=json.load(sys.stdin); print('Passing on Site 2:', len(s))"
# Expected: 3
```

---

## Two-Region Architecture: Six Datacenters Across Two Deployment Models

The demo spans two AWS regions. Scenarios A and B use the VM layer only. Scenarios C and D
add K8s clusters that share control planes with the VM datacenters:

```
us-east-1 PRIMARY
  DC3 (VMs) — Consul server, native agents
    data layer: postgres, product-api
    app layer:  payments, public-api, frontend
    DNS NLB:    port 53 → Consul DNS 8600

  DC5 (EKS, admin partition dc5-k8s of DC3)
    app layer:  frontend, public-api, payments (mesh, Connect sidecars)
    mesh-gw:    cross-partition communication with DC3
    term-gw:    reaches DC3's postgres across the partition boundary

us-west-2 FAILOVER
  DC4 (VMs) — Consul server, ESM external nodes
    product-api × 3 (no Consul agent — ESM health-checked)
    DNS NLB: port 53 → Consul DNS 8600
    sameness group member: default partition

  DC6 (EKS, admin partition dc6-k8s of DC4)
    ALL HashiCups components together (self-contained failover target)
    catalog sync only — no mesh, no sidecars
    sameness group member: dc6-k8s partition
```

**DC3 is the control plane for DC3 and DC5.** DC5 runs no Consul server — it connects to
DC3's server via `externalServers` in the consul-k8s Helm values.

**DC4 is the control plane for DC4 and DC6.** DC6 syncs its K8s services into DC4's
Consul catalog via the catalog sync controller.

**DC5 and DC6 share no connection** — they are in different regions and different control
planes.

---

## DNS-Transparent Routing: How Prepared Queries Work

A prepared query is a saved Consul template. When a client resolves
`product-api-geo.query.consul.`, Consul evaluates the query rules right now — it checks
health, sorts by proximity, and applies failover if needed.

Here is the query registered on Site 1:

```json
{
  "Name": "product-api-geo",
  "Service": {
    "Service": "product-api",
    "Near": "_agent",
    "OnlyPassing": true,
    "Failover": {
      "Targets": [
        { "Datacenter": "dc3-vm" },
        { "Peer": "dc4-esm" }
      ]
    }
  }
}
```

| Field | What it does |
|-------|-------------|
| `Near: "_agent"` | Returns instances sorted by proximity to the querying agent — latency-aware routing |
| `OnlyPassing` | Filters to instances where **all** health checks are green |
| `Targets[0]` — dc3-vm | Try Site 1 instances first |
| `Targets[1]` — dc4-esm peer | If Site 1 has zero passing → automatically query Site 2 |

The `Failovers` counter in the API response tells you exactly how many target hops were
needed. A value of `0` means Site 1 is healthy. A value of `1` means we fell through to
Site 2.

There is also a `product-api-local` query with no failover configured. We'll use that to
show a side-by-side contrast — some traffic may be intentionally site-bound and should go
dark rather than cross regions.

---

## Scenario A — Service-Level Failover

**The story:** Three product-api instances on Site 1 crash simultaneously — imagine a bad
deployment or an OOM event. We want to show that traffic automatically reroutes to Site 2
with no operator involvement and no application change.

### Step 1 — Establish the baseline

Right now, Site 1 is fully healthy. Let's confirm:

```bash
# HTTP API — Failovers: 0 means Site 1 is serving
curl -s "http://$DC3_SERVER_PUB:8500/v1/query/product-api-geo/execute" | \
  python3 -c "
import json,sys; r=json.load(sys.stdin)
print('Failovers applied:', r['Failovers'])
print('Instances returned:', len(r['Nodes']))
for n in r['Nodes']: print(' ', n['Node']['Node'], '@', n['Node']['Address'])
"

# DNS — returns 3 Site 1 IPs (10.10.x.x)
dig +tcp @$DC3_SERVER_PUB -p 8600 product-api-geo.query.consul. A +short
```

You'll see three Site 1 addresses returned (`10.10.x.x`) and `Failovers: 0`.

### Step 2 — Take down product-api on all three Site 1 VMs

```bash
for IP in $DC3_PA1_IP $DC3_PA2_IP $DC3_PA3_IP; do
  ssh -n -i $KEY -o StrictHostKeyChecking=no ubuntu@$IP 'docker stop product-api'
done
```

Consul's health checks run on a 15-second interval. Within 30 seconds you'll see all three
instances flip to critical in the UI at `http://$DC3_SERVER_PUB:8500/ui`.

### Step 3 — Observe automatic failover

```bash
# Failovers is now 1 — Site 2 peer was used
curl -s "http://$DC3_SERVER_PUB:8500/v1/query/product-api-geo/execute" | \
  python3 -c "
import json,sys; r=json.load(sys.stdin)
print('Failovers applied:', r['Failovers'], ' ← 1 = Site 2 peer used')
print('Instances returned:', len(r['Nodes']))
for n in r['Nodes']: print(' ', n['Node']['Node'], '@', n['Service']['Address'])
"

# DNS now returns Site 2 IPs (10.20.x.x)
dig +tcp @$DC3_SERVER_PUB -p 8600 product-api-geo.query.consul. A +short
```

Notice: **the DNS name hasn't changed**. The application resolving
`product-api-geo.query.consul.` is now transparently receiving Site 2 addresses.

Also notice what happens to the local-only query:

```bash
curl -s "http://$DC3_SERVER_PUB:8500/v1/query/product-api-local/execute" | \
  python3 -c "import json,sys; r=json.load(sys.stdin); print('Instances:', len(r['Nodes']))"
# Returns 0 — no cross-site fallback for intentionally site-bound traffic
```

### Step 4 — Automatic recovery

```bash
for IP in $DC3_PA1_IP $DC3_PA2_IP $DC3_PA3_IP; do
  ssh -n -i $KEY -o StrictHostKeyChecking=no ubuntu@$IP 'docker start product-api'
done
```

Within 30 seconds the health checks pass, `Failovers` drops back to `0`, and Site 1 is
serving again — with no manual step and no cache flush.

> **Key point for the customer:** This is Consul evaluating your actual application health
> at DNS resolution time. Compare that to a GTM TCP ping — it tells you the port is open,
> not that your application is healthy. Consul knows if your sidecar is passing, your
> custom health check is green, your readiness endpoint is responding. The failover
> decision is based on real service health.

---

## Scenario B — Control Plane Failure

**The story:** The Site 1 Consul server itself goes down — a node failure or network
partition. With a conventional single-server DNS setup, `.consul` queries simply time out.
We've configured clients with a dual-server dnsmasq rule so they query both control planes
in parallel. When Site 1 is silent, Site 2 answers in the same round trip.

### The dual-NLB DNS configuration

Each DC has a Network Load Balancer that listens on port 53 and forwards to its local
Consul server on port 8600. The bastion's systemd-resolved is configured with both NLB
IPs as nameservers — no dnsmasq or per-host tooling needed.

```
/etc/systemd/resolved.conf.d/consul-dns.conf:
  [Resolve]
  DNS=<DC3_NLB_IP> <DC4_NLB_IP>
```

When DC3's NLB is unreachable, systemd-resolved falls back to DC4's NLB within ~2 seconds.
Non-`.consul` queries are forwarded by Consul to the VPC DNS resolver (169.254.169.253) via
the `recursors` setting in the Consul server HCL.

To bootstrap the bastion after provisioning (see README Phase 8):

```bash
rsync -av -e "ssh -i $KEY" vm/ ubuntu@$BASTION_PUB:/tmp/vm/
ssh -i $KEY ubuntu@$BASTION_PUB \
  "sudo bash /tmp/vm/scripts/bootstrap-bastion.sh $DC3_NLB_IP $DC4_NLB_IP"
```

Site 2 also has its own copy of the prepared query, with reversed preference:

```json
{
  "Name": "product-api-geo",
  "Failover": {
    "Targets": [
      { "Datacenter": "dc4-esm" },
      { "Peer": "dc3-vm" }
    ]
  }
}
```

When Site 2's DNS answers, it runs this query — returns its own local instances first
(`Failovers: 0`), only crossing back to Site 1 if Site 2 itself has no passing instances.

### Step 1 — Verify both control planes are healthy and capture the baseline

```bash
curl -s http://$DC3_SERVER_PUB:8500/v1/status/leader   # Site 1 leader
curl -s http://$DC4_SERVER_PUB:8500/v1/status/leader   # Site 2 leader
```

From the bastion host, capture the DNS result **now** — before Site 1 goes down — so you
can show the before/after contrast in the next steps:

```bash
# Baseline — returns Site 1 IPs (10.10.x.x), answered by Site 1
ssh -i $KEY ubuntu@$BASTION_PUB 'dig product-api-geo.query.consul. A +short'
ssh -i $KEY ubuntu@$BASTION_PUB \
  'dig product-api-geo.query.consul. A +stats 2>&1 | grep "SERVER:"'
```

### Step 2 — Take down the Site 1 Consul server

We stop consul along with its dependents to prevent systemd restart loops:

```bash
ssh -i $KEY ubuntu@$DC3_SERVER_PUB \
  'sudo systemctl stop consul_exporter mesh-gateway consul'
```

### Step 3 — Site 1 API is gone; the same DNS query still works

```bash
# Site 1 — unreachable
curl -s --max-time 3 http://$DC3_SERVER_PUB:8500/v1/status/leader \
  && echo "still up" || echo "Site 1 unreachable ✓"

# Site 2 — still serving, resolves its own local instances (Failovers: 0)
curl -s "http://$DC4_SERVER_PUB:8500/v1/query/product-api-geo/execute" | \
  python3 -c "
import json,sys; r=json.load(sys.stdin)
print('Failovers:', r['Failovers'], ' ← 0, Site 2 resolving locally')
for n in r['Nodes']: print(' ', n['Node']['Node'], '@', n['Service']['Address'])
"
```

From the bastion host — same command as Step 1, now answered by Site 2:

```bash
# After Site 1 goes down — Site 2 answers (10.20.x.x)
ssh -i $KEY ubuntu@$BASTION_PUB 'dig product-api-geo.query.consul. A +short'

# Confirm which server answered
ssh -i $KEY ubuntu@$BASTION_PUB \
  'dig product-api-geo.query.consul. A +stats 2>&1 | grep "SERVER:"'
```

**The DNS name is identical. The client is unaware anything changed.**

### Step 4 — Restore Site 1

```bash
ssh -i $KEY ubuntu@$DC3_SERVER_PUB \
  'sudo systemctl start consul && sleep 8 && sudo systemctl start mesh-gateway consul_exporter'
```

Within 15–20 seconds DC3 re-elects a leader, clients with dual dnsmasq entries start
receiving responses from either site again, and the system returns to its normal state.

> **Key point for the customer:** The application doesn't have a "Site 1 endpoint" and a
> "Site 2 endpoint" — it has one DNS name. The resilience is in the DNS layer and the
> control plane, not in the application. A client with the dual-server dnsmasq config
> never waits for a timeout — Site 2 is always a parallel option.

---

## Scenario C — VM and K8s Services Are Interchangeable

> **Requires README Phases 11–12 (DC6 EKS + sameness group).**

**The story:** DC4 runs product-api on VMs registered via ESM. DC6 runs an equivalent
product-api in Kubernetes with catalog sync. A Consul sameness group declares them
equivalent — when DC4's VM instances go critical, traffic moves to DC6's K8s instances
automatically. No prepared query. No failover target to maintain per service.

**The contrast with Scenarios A and B:** Those scenarios use explicit `Failover.Targets`
in a prepared query — you decide the failover order at query registration time. A sameness
group is declarative: you define which partitions are equivalent once, and every service in
those partitions gets the policy automatically. Adding a new service to DC6 doesn't require
updating any query.

### Step 1 — Confirm the sameness group is active

```bash
curl -s "http://$DC4_SERVER_PUB:8500/v1/config/sameness-group/dc4-dc6-product-api" | \
  python3 -m json.tool
# Members should show: default partition and dc6-k8s partition
```

### Step 2 — Confirm both partitions have passing product-api instances

```bash
# DC4 default partition (VMs)
curl -s "http://$DC4_SERVER_PUB:8500/v1/health/service/product-api?passing" | \
  python3 -c "import json,sys; s=json.load(sys.stdin); print('DC4 VMs passing:', len(s))"

# DC6 partition (K8s)
curl -s "http://$DC4_SERVER_PUB:8500/v1/health/service/product-api?passing&partition=dc6-k8s" | \
  python3 -c "import json,sys; s=json.load(sys.stdin); print('DC6 K8s passing:', len(s))"
```

### Step 3 — Stop DC4 VM product-api instances

```bash
for IP in $DC4_PA1_IP $DC4_PA2_IP $DC4_PA3_IP; do
  ssh -n -i $KEY_W2 -o StrictHostKeyChecking=no ubuntu@$IP 'docker stop product-api'
done
```

Within 30 seconds DC4's instances go critical. Consul's sameness group routing
automatically shifts traffic to DC6's K8s instances — no query update, no DNS change.

### Step 4 — Confirm routing shifted to DC6

```bash
curl -s "http://$DC4_SERVER_PUB:8500/v1/health/service/product-api?passing" | \
  python3 -c "
import json,sys; s=json.load(sys.stdin)
print('Passing instances:', len(s))
for n in s: print(' ', n['Node']['Node'], '@', n['Service']['Address'],
  '— partition:', n['Service'].get('Partition','default'))
"
```

### Step 5 — Restore DC4

```bash
for IP in $DC4_PA1_IP $DC4_PA2_IP $DC4_PA3_IP; do
  ssh -n -i $KEY_W2 -o StrictHostKeyChecking=no ubuntu@$IP 'docker start product-api'
done
```

> **Key point for the customer:** The sameness group is a one-time, per-datacenter
> declaration. Compare that to Scenario A where each prepared query explicitly names its
> failover targets. With sameness groups, every service you add to DC4 or DC6 is
> automatically covered — zero per-service failover config.

---

## Scenario D — K8s Mesh Services Fail Over to VM Peer

> **Requires README Phases 10 and 13 (DC5 EKS mesh + DC5 prepared query).**

**The story:** The HashiCups app layer runs in Kubernetes on DC5 — containerised, with
Envoy sidecars and Connect mesh. The data layer (postgres, product-api) stays on DC3 VMs.
DC5 is an admin partition of DC3, sharing its control plane. When the K8s app services
fail, a prepared query registered in the dc5-k8s partition falls back to DC4's VM-based
equivalents via cluster peering — the same mechanism as Scenario A, but now the primary is
K8s rather than VM.

**What this shows:** Consul treats K8s services and VM services as first-class citizens in
the same catalog. A service registered by a K8s pod and a service registered by a VM agent
are indistinguishable to a prepared query. The failover works because the service *name* is
what matters, not the runtime environment.

### Step 1 — Confirm DC5 K8s services are registered and passing

```bash
# K8s services are visible in DC3's Consul UI under the dc5-k8s partition
curl -s "http://$DC3_SERVER_PUB:8500/v1/health/service/product-api?passing&partition=dc5-k8s" | \
  python3 -c "import json,sys; s=json.load(sys.stdin); print('DC5 K8s passing:', len(s))"
```

You can also open the Consul UI at `http://$DC3_SERVER_PUB:8500/ui` and switch to the
`dc5-k8s` partition — the K8s services appear alongside the DC3 VM services in the same
interface.

### Step 2 — Baseline: DC5 partition resolves locally (Failovers: 0)

```bash
curl -s "http://$DC3_SERVER_PUB:8500/v1/query/product-api-hybrid/execute?partition=dc5-k8s" | \
  python3 -c "
import json,sys; r=json.load(sys.stdin)
print('Failovers:', r['Failovers'], ' ← 0 = DC5 K8s serving')
for n in r['Nodes']: print(' ', n['Node']['Node'], '@', n['Service']['Address'])
"
```

### Step 3 — Stop product-api pods in DC5

```bash
kubectl --context dc5 scale deployment product-api --replicas=0
```

Within 15 seconds the K8s readiness probe fails, the service goes critical in Consul, and
the prepared query falls over to DC4's VM instances.

### Step 4 — Observe peer failover (Failovers: 1)

```bash
curl -s "http://$DC3_SERVER_PUB:8500/v1/query/product-api-hybrid/execute?partition=dc5-k8s" | \
  python3 -c "
import json,sys; r=json.load(sys.stdin)
print('Failovers:', r['Failovers'], ' ← 1 = DC4 VM peer used')
for n in r['Nodes']: print(' ', n['Node']['Node'], '@', n['Service']['Address'])
"
```

### Step 5 — Restore DC5

```bash
kubectl --context dc5 scale deployment product-api --replicas=3
```

> **Key point for the customer:** DC5 is an admin partition of DC3 — it shares the control
> plane but has its own service registry scope. The prepared query is registered in that
> partition and fails over to a peer. The runtime (K8s vs VM) is invisible to the failover
> logic. Consul sees service names and health checks, not container runtimes.

---

## DNS Reference

### Prepared query FQDNs

| DNS name | Served by | Behaviour |
|----------|-----------|-----------|
| `product-api-geo.query.consul.` | DC3 (Site 1) | Site 1 first, fails over to dc4-esm peer |
| `product-api-geo.query.consul.` | DC4 (Site 2) | Site 2 first, peers back to dc3-vm |
| `product-api-local.query.consul.` | DC3 only | Site 1 only — returns empty when Site 1 is down |

Queries run against port **8600** on the Consul server. From outside the VPC, use `+tcp`
(UDP 8600 is restricted to VPC traffic):

```bash
dig +tcp @consul.dc3.prabhjit-singh.sbx.hashidemos.io -p 8600 \
  product-api-geo.query.consul. A +short

dig +tcp @consul.dc4.prabhjit-singh.sbx.hashidemos.io -p 8600 \
  product-api-geo.query.consul. A +short
```

### Bastion host — transparent single-query demo

> **Setup:** See **README Phase 8** to provision the bastion, then run `bootstrap-bastion.sh`
> with both NLB IPs to configure systemd-resolved. The `$DC3_NLB_IP` and `$DC4_NLB_IP`
> env vars are set in the **Before You Start** block above.

```bash
export BASTION_PUB=$(terraform -chdir=terraform/dc3 output -raw bastion_public_ip)

# One query — always returns healthy instances regardless of which site is up
ssh -i $KEY ubuntu@$BASTION_PUB 'dig product-api-geo.query.consul. A +short'

# See which Consul server answered
ssh -i $KEY ubuntu@$BASTION_PUB \
  'dig product-api-geo.query.consul. A +stats 2>&1 | grep "SERVER:"'
```
