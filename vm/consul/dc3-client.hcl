# Consul client for DC3 HashiCups VMs.
# 1) Copy to /etc/consul.d/client.hcl
# 2) Replace REPLACE_WITH_PRIVATE_IP, REPLACE_CONSUL_SERVER_IP, REPLACE_NODE_NAME.

datacenter   = "dc3-vm"
data_dir     = "/opt/consul/data"
node_name    = "REPLACE_NODE_NAME"
license_path = "/etc/consul.d/consul.hclic"

server = false

bind_addr      = "0.0.0.0"
client_addr    = "0.0.0.0"
advertise_addr = "REPLACE_WITH_PRIVATE_IP"

retry_join = ["REPLACE_CONSUL_SERVER_IP"]

connect {
  enabled = true
}

ports {
  grpc = 8502
}

telemetry {
  prometheus_retention_time = "60s"
  disable_hostname          = true
}

log_level = "INFO"
