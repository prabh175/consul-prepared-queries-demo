# Consul server for DC4 (us-west-2) — ESM-based datacenter.
# 1) Copy to /etc/consul.d/server.hcl
# 2) Replace REPLACE_WITH_PRIVATE_IP with this host's VPC private IP.

datacenter = "dc4-esm"
data_dir   = "/opt/consul/data"
node_name  = "consul-server-dc4"

server           = true
bootstrap_expect = 1

bind_addr      = "0.0.0.0"
client_addr    = "0.0.0.0"
advertise_addr = "REPLACE_WITH_PRIVATE_IP"

ui_config {
  enabled = true
}

connect {
  enabled = true
}

ports {
  grpc     = 8502
  grpc_tls = 8503
}

telemetry {
  prometheus_retention_time = "60s"
  disable_hostname          = true
}

license_path = "/etc/consul.d/consul.hclic"

# Serve the org sub-zone in addition to the default .consul domain.
# Hosts using the DNS NLB as a nameserver can query either:
#   product-api-geo.query.consul.
#   product-api-geo.query.consul.prabhjit-singh.sbx.hashidemos.io.
alt_domain = "consul.prabhjit-singh.sbx.hashidemos.io"

# Forward non-.consul queries to the VPC DNS resolver so hosts that
# use this NLB as their only nameserver can still resolve internet names.
recursors = ["169.254.169.253"]

log_level = "INFO"

dns_config {
  service_ttl {
    "*" = "10s"
  }
  allow_stale = true
  max_stale   = "10s"
}
