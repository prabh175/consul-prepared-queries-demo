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

We will cover five scenarios across two regions and four deployment models:

| Scenario | What fails | Infrastructure | Mechanism |
|----------|-----------|----------------|-----------|
| **A — Service failure** | product-api containers on DC3 | DC3 + DC4 VMs | Prepared query, health-check driven |
| **B — Control plane failure** | DC3 Consul server | DC3 + DC4 VMs | Dual DNS NLB nameservers |
| **C — VM ↔ K8s failover** | DC4 VM product-api | DC4 VMs + DC6 K8s | Sameness group, cross-partition |
| **D — K8s mesh failover** | DC5 K8s product-api | DC5 K8s + DC4 VMs | Prepared query, cross-peer from dc5-k8s partition |
| **E — Cross-cluster frontend** | DC5 K8s frontend NLB | DC5 K8s + DC6 K8s | Prepared query + ESM, mesh → non-mesh |

Scenarios A and B use the existing VM infrastructure and can be run immediately after
README Phases 1–8. Scenarios C, D, and E require the K8s clusters (README Phases 10–14).

---

## How Consul Compares to F5 GTM and LTM

Today's global traffic story is built on two appliance tiers: **BIG-IP DNS (GTM)** for
cross-site and cross-region failover, and **BIG-IP LTM** for load balancing within a site.
Consul delivers both capabilities from one control plane, driven by real service health and
workload identity rather than network position — and it does so for VMs and Kubernetes with
the same constructs, with no appliance pair to license, size, or fail over itself.

| Traditional F5 | What it does | Consul equivalent | Why Consul is different |
|----------------|-------------|-------------------|-------------------------|
| **GTM / BIG-IP DNS (GSLB)** | DNS-based failover across data centers via wide-IPs, pools, topology records | **Prepared queries + Consul DNS** | The failover decision uses *application* health evaluated at query time — not a shallow TCP/ICMP monitor — and there is no wide-IP or DNS record to edit when topology changes |
| **GTM health monitors** | Periodic TCP/HTTP probe launched from the appliance | **Agent / ESM / sidecar checks** | Health is reported by the workload's own Consul agent or Envoy sidecar (script, gRPC, TTL, readiness) and shared fleet-wide, not polled from one central box |
| **LTM virtual servers + pools** | L4/L7 load balancing to backend pool members inside a site | **Service mesh (Connect) + discovery** | Balancing happens in a distributed Envoy sidecar next to each workload — no VIP to provision, no appliance to size — and mTLS is on by default |
| **LTM iRules / SNAT / SSL offload** | Per-connection policy enforced on the appliance | **Service intentions + automatic mTLS** | Policy is identity-based (SPIFFE), declared once and enforced everywhere; certificates are issued and rotated by Consul automatically |
| **New GSLB pool for a new DC** | Add pool, members, monitors, and a wide-IP entry by hand | **Sameness group** | Declare two partitions equivalent once; every current and future service is covered with zero per-service config |
| **Separate config per environment** | Different modules/appliances for physical vs cloud vs K8s | **One catalog + partitions + peering + catalog sync** | VM, EKS-mesh, and EKS-non-mesh services are all first-class catalog entries and resolve through the same query |

**The one-line version for the customer:** GTM and LTM route based on *where* a server sits
and whether a port answers. Consul routes based on *what* a service is and whether the
application is actually healthy — and the same model spans every runtime, with no separate
appliance tier in the data path.

Each scenario below opens with an **At a glance** block that names exactly which Consul
components are in play and which F5 capability it replaces or improves on.

---

## Before You Start

### Set environment variables

Run all commands from the repo root (`Prepared_Queries/`). `$KEY` is a relative path and
all SSH commands depend on it.

```bash
export KEY=vm/devops-keypair.pem
export KEY_W2=vm/devops-keypair.pem   # us-west-2 VMs (Scenario C) — same key material

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

# All product-api instances passing on Site 2 (registered in hashicups namespace)
curl -s "http://$DC4_SERVER_PUB:8500/v1/health/service/product-api?passing&ns=hashicups" | \
  python3 -c "import json,sys; s=json.load(sys.stdin); print('Passing on Site 2:', len(s))"
# Expected: 3 (ESM-monitored VMs in dc4-esm datacenter, hashicups namespace)
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
    full stack: postgres, product-api, payments, public-api, frontend (mesh, Connect sidecars)
    nginx:      single entry point — API Gateway → nginx → frontend/public-api
    mesh-gw:    cross-partition and cross-peer communication
    term-gw:    external service egress

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

**At a glance**

| | |
|---|---|
| **What's happening** | All three `product-api` VMs in the us-east-1 site fail; the shared DNS name `product-api-geo.query.consul.` transparently begins returning healthy us-west-2 instances instead. |
| **Consul components** | Consul servers (DC3 + DC4), native Consul agent + Connect sidecar (Envoy) on each VM, **cluster peering** DC3↔DC4, **prepared query** `product-api-geo` with `Failover.Targets`, agent-level health checks, Consul DNS interface. |
| **How it's accomplished** | The query filters on `OnlyPassing` health at resolve time and sorts by `Near: _agent`. When Site 1 returns zero passing instances, Consul walks to the next failover target — the `dc4-esm` **peer** — and returns its instances. The `Failovers` counter reports how many hops were taken. |
| **Replaces / improves on** | An F5 **GTM** wide-IP with a two-DC pool and TCP health monitors. |
| **Customer benefit** | Failover is keyed on *real application health*, not a port probe; there is no wide-IP or DNS record to touch; it is automatic in under 30 seconds; and the side-by-side `product-api-local` query proves you can also deliberately *contain* traffic to one site when cross-region bleed is not wanted. |

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

**At a glance**

| | |
|---|---|
| **What's happening** | The Site 1 Consul **control plane** itself dies. `.consul` resolution keeps working because Site 2's independent control plane answers the identical query. |
| **Consul components** | Redundant Consul servers per region, a per-DC **DNS NLB** (port 53 → Consul DNS 8600), `recursors` for non-`.consul` names, clients/bastion configured with **both** NLB IPs as nameservers (systemd-resolved), and a mirrored `product-api-geo` prepared query on Site 2. |
| **How it's accomplished** | systemd-resolved lists both NLB IPs. When DC3's NLB stops answering, the resolver falls to DC4's NLB within ~2 seconds; DC4 runs its own copy of the query and answers from its local instances (`Failovers: 0`). |
| **Replaces / improves on** | F5 **GTM** DNS-listener HA — a redundant GTM appliance pair or anycast'd DNS front end. |
| **Customer benefit** | There is no single DNS "brain" to lose. The resolver never waits out a full timeout — the second control plane is a *parallel* answer path, not a cold standby that has to be promoted. |

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

**At a glance**

| | |
|---|---|
| **What's happening** | DC4's VM `product-api` fails and traffic shifts to DC6's **Kubernetes** `product-api` — VM and K8s treated as one interchangeable service — with no prepared query involved. |
| **Consul components** | Consul server DC4, **ESM** health-checking the DC4 VMs, admin **partition** `dc6-k8s`, the **catalog sync** controller mirroring DC6 K8s services into DC4's catalog, a **sameness group** config entry declaring `default` + `dc6-k8s` equivalent, and mesh gateways for cross-partition traffic. |
| **How it's accomplished** | The sameness group makes same-named services across the two partitions one logical service. When DC4's instances go critical, resolution returns DC6's instances automatically — no target list to edit. |
| **Replaces / improves on** | An F5 **GTM** GSLB pool spanning two data centers with manually maintained members and monitors. |
| **Customer benefit** | Equivalence is declared once and is *identity-based*, not address-based; every service added to either partition later is covered with zero extra config; and it unifies completely different runtimes (VM and K8s) behind one policy. |

### Step 1 — Confirm the sameness group is active

```bash
curl -s "http://$DC4_SERVER_PUB:8500/v1/config/sameness-group/dc4-dc6-product-api" | \
  python3 -m json.tool
# Members should show: default partition and dc6-k8s partition
```

### Step 2 — Confirm both partitions have passing product-api instances

```bash
# DC4 default partition (VMs — hashicups namespace)
curl -s "http://$DC4_SERVER_PUB:8500/v1/health/service/product-api?passing&ns=hashicups" | \
  python3 -c "import json,sys; s=json.load(sys.stdin); print('DC4 VMs passing:', len(s))"

# DC6 partition (K8s — hashicups namespace mirrored from K8s)
curl -s "http://$DC4_SERVER_PUB:8500/v1/health/service/product-api?passing&partition=dc6-k8s&ns=hashicups" | \
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
curl -s "http://$DC4_SERVER_PUB:8500/v1/health/service/product-api?passing&ns=hashicups" | \
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

**The story:** DC5 runs the full HashiCups stack in Kubernetes — postgres, product-api,
payments, public-api, frontend, all with Envoy sidecars and Connect mesh. DC5 is an admin
partition of DC3, sharing its control plane. When product-api fails in DC5, a prepared
query registered in the dc5-k8s partition falls back to DC4's VM-based instances via
cluster peering — the same mechanism as Scenario A, but now the primary is K8s rather than VM.

**What this shows:** Consul treats K8s services and VM services as first-class citizens in
the same catalog. A service registered by a K8s pod and a service registered by a VM agent
are indistinguishable to a prepared query. The failover works because the service *name* is
what matters, not the runtime environment.

**At a glance**

| | |
|---|---|
| **What's happening** | DC5's full HashiCups stack runs in Kubernetes with Connect sidecars. When its `product-api` fails, a prepared query registered *inside the K8s admin partition* fails over to DC4's VM instances across a peer. |
| **Consul components** | consul-k8s / consul-dataplane on EKS, admin **partition** `dc5-k8s` of DC3 (shared control plane via `externalServers`), Connect **sidecars**, **mesh gateways**, **cluster peering** DC5↔DC4, and the `product-api-hybrid` **prepared query** scoped to the partition. |
| **How it's accomplished** | The query runs in the `dc5-k8s` partition using the K8s readiness probe as the health signal. On zero passing pods it walks to the `dc4-esm` peer target and returns VM instances — the same failover machinery as Scenario A, now with a K8s primary. |
| **Replaces / improves on** | Two F5 tiers at once — **LTM** balancing inside the cluster *and* **GTM** across data centers — collapsed into a single query. |
| **Customer benefit** | K8s and VM are indistinguishable to the failover logic; the service *name* is the contract, not the runtime; and one construct spans both local load balancing and global failover. |

### Step 1 — Confirm DC5 K8s services are registered and passing

```bash
# K8s services are visible in DC3's Consul UI under the dc5-k8s partition
curl -s "http://$DC3_SERVER_PUB:8500/v1/health/service/product-api?passing&partition=dc5-k8s&ns=hashicups" | \
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
kubectl scale deployment product-api -n hashicups --replicas=0 --context dc5
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
kubectl scale deployment product-api -n hashicups --replicas=3 --context dc5
```

> **Key point for the customer:** DC5 is an admin partition of DC3 — it shares the control
> plane but has its own service registry scope. The prepared query is registered in that
> partition and fails over to a peer. The runtime (K8s vs VM) is invisible to the failover
> logic. Consul sees service names and health checks, not container runtimes.

---

## Scenario E — Cross-Cluster Frontend Failover (Mesh → Non-Mesh)

> **Requires README Phases 10, 11, 13, and 14 (DC5 + DC6 EKS + ESM frontend registration).**

**The story:** DC5 exposes its frontend via the Consul API Gateway NLB. ESM in DC3 monitors
that NLB as an external node. A prepared query `frontend-geo` on DC3 resolves the DC5 NLB
as the primary endpoint. When DC5's frontend goes critical, the query fails over to DC6's
NLB — which runs the same frontend in a non-mesh Kubernetes cluster. DC6's NLB is
registered directly in DC3's Consul catalog (no cross-peer hop), so failover is a local
partition lookup, not a peer traversal. The client never changes its DNS query.

**What this shows:** ESM and prepared queries are runtime-agnostic. DC5 is a full Connect
mesh cluster; DC6 has no mesh at all. To Consul, both are just health-checked external
endpoints. The failover works identically — whether the backend is a mesh pod, a VM, or a
catalog-synced K8s service.

This is the "last mile" scenario: it demonstrates that Consul's geo-failover pattern applies
all the way up the stack, including the frontend tier, across completely different deployment
models.

**At a glance**

| | |
|---|---|
| **What's happening** | DC5's mesh frontend (behind the Consul API Gateway NLB) fails, and the same DNS name fails over to DC6's frontend NLB — a **non-mesh** Kubernetes cluster. |
| **Consul components** | **Consul API Gateway** (DC5 entry point), **ESM** monitoring the NLB HTTP endpoints as external nodes, direct **catalog registration** of the DC6 NLB in DC3's default partition, the `frontend-geo` **prepared query**, and the **terminating gateway** for external egress. |
| **How it's accomplished** | ESM health-checks each NLB's HTTP endpoint. The query resolves the DC5 NLB first and the DC6 NLB on failover; because DC6's NLB is registered directly in DC3's catalog, that failover is a local partition lookup, not a peer hop. |
| **Replaces / improves on** | An F5 **GTM** wide-IP fronting a VIP in each data center, with the LTM VIPs handling entry. |
| **Customer benefit** | The pattern is runtime-agnostic to the very last mile — mesh vs non-mesh, pod vs VM vs raw NLB all look identical to the query — so the front-door tier gets the exact same health-aware geo-failover as the backends, with no bespoke config. |

### Step 1 — Confirm both frontend NLBs are registered and passing

```bash
# DC5 api-gateway NLB — ESM-monitored in DC3 (dc5-k8s partition, hashicups ns)
curl -s "http://$DC3_SERVER_PUB:8500/v1/health/service/frontend?passing&partition=dc5-k8s&ns=hashicups" | \
  python3 -c "import json,sys; s=json.load(sys.stdin); print('DC5 NLB passing:', len(s), '(expect 1+)')"

# DC6 frontend NLB — registered directly in DC3's default partition (hashicups ns)
curl -s "http://$DC3_SERVER_PUB:8500/v1/health/service/frontend?passing&ns=hashicups" | \
  python3 -c "import json,sys; s=json.load(sys.stdin); print('DC6 NLB in DC3 default passing:', len(s), '(expect 1)')"

# Baseline — frontend-geo resolves DC5 NLB (Failovers: 0)
curl -s "http://$DC3_SERVER_PUB:8500/v1/query/frontend-geo/execute" | \
  python3 -c "
import json,sys; r=json.load(sys.stdin)
print('Failovers:', r['Failovers'], ' ← 0 = DC5 NLB serving')
for n in r['Nodes']: print(' ', n['Service']['Address'])
"
```

### Step 2 — Open the HashiCups UI via the DC5 NLB

The prepared query resolves the DC5 NLB address. Open it in a browser — confirm products load.
This is the mesh-backed frontend, running full Connect with nginx as the entry point.

### Step 3 — Take down DC5 frontend

```bash
kubectl scale deployment frontend -n hashicups --replicas=0 --context dc5
```

ESM's health check on the DC5 NLB will flip to critical within 10–30 seconds.

### Step 4 — Observe failover to DC6 (non-mesh)

```bash
# Failovers: 1 — DC6 NLB now returned
curl -s "http://$DC3_SERVER_PUB:8500/v1/query/frontend-geo/execute" | \
  python3 -c "
import json,sys; r=json.load(sys.stdin)
print('Failovers:', r['Failovers'], ' ← 1 = DC6 NLB serving')
for n in r['Nodes']: print(' ', n['Service']['Address'])
"
```

The DNS name is unchanged. The address returned is now DC6's NLB — a completely different
K8s cluster with no service mesh. Open it in a browser; HashiCups loads from DC6.

### Step 5 — Restore DC5

```bash
kubectl scale deployment frontend -n hashicups --replicas=1 --context dc5
```

Within 30 seconds ESM's check passes, the prepared query returns to DC5, and `Failovers`
drops back to `0`.

> **Key point for the customer:** The query `frontend-geo` doesn't know that DC5 is
> mesh-enabled and DC6 is not. ESM monitors an HTTP health endpoint on each NLB — the
> Kubernetes implementation underneath is irrelevant. The same prepared query pattern you
> used for VMs in Scenario A works unchanged for K8s NLBs in Scenario E. Consul's
> geo-failover is infrastructure-agnostic end to end.

---

## DNS Reference

### Prepared query FQDNs

| DNS name | Served by | Behaviour |
|----------|-----------|-----------|
| `product-api-geo.query.consul.` | DC3 (Site 1) | Site 1 first, fails over to dc4-esm peer |
| `product-api-geo.query.consul.` | DC4 (Site 2) | Site 2 first, peers back to dc3-vm |
| `product-api-local.query.consul.` | DC3 only | Site 1 only — returns empty when Site 1 is down |
| `product-api-hybrid.query.consul.` | DC3 (dc5-k8s partition) | DC5 K8s first, fails over to DC4 VM peer |
| `frontend-geo.query.consul.` | DC3 | DC5 api-gateway NLB first (dc5-k8s partition), fails over to DC6 NLB (DC3 default partition) |
| `frontend-geo.query.consul.` | DC4 (dc6-k8s partition) | DC6 NLB first (dc6-k8s), fails over to DC4 VM frontend (default partition) |

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
