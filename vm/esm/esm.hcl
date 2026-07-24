# consul-esm configuration for DC4 (dc4-esm).
# Runs on the DC4 consul-server VM alongside the Consul server process.
# Monitors all external nodes registered with NodeMeta "external-node": "true".
#
# NOTE: no token is set here on purpose — it is kept out of git. When the anonymous
# token is restricted, bootstrap-dc4-server.sh (with CONSUL_MGMT_TOKEN set) appends a
# `token = "..."` line here from a dedicated consul-esm ACL policy. Without a token ESM
# relies on anonymous perms, which must allow service:write / node:write.

http_addr   = "http://127.0.0.1:8500"
datacenter  = "dc4-esm"
instance_id = "esm-dc4-1"

# How long ESM waits before assuming a node is gone.
node_reconnect_timeout = "72h"

# Ping probe confirms basic TCP reachability before running service checks.
ping_type = "udp"
