# Sourced by DC3 on-*.sh scripts.
# Docker containers use host.docker.internal to reach Connect upstream local_bind ports.

_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
CONNECT_ENVOY_UNIT_SRC="${_LIB_DIR}/../systemd/connect-envoy@.service"

host_ip() {
  curl -fsS --connect-timeout 2 http://169.254.169.254/latest/meta-data/local-ipv4 2>/dev/null \
    || hostname -I | awk '{print $1}'
}

DNS_FLAGS=(--dns "$(host_ip)")
DOCKER_HOST_GATEWAY_FLAGS=(--add-host=host.docker.internal:host-gateway)

ensure_connect_envoy_unit_installed() {
  [[ -f /etc/systemd/system/connect-envoy@.service ]] && return 0
  [[ -f "${CONNECT_ENVOY_UNIT_SRC}" ]] || { echo "Missing ${CONNECT_ENVOY_UNIT_SRC}" >&2; return 1; }
  cp "${CONNECT_ENVOY_UNIT_SRC}" /etc/systemd/system/connect-envoy@.service
  systemctl daemon-reload
}

stop_connect_sidecar() {
  systemctl stop "connect-envoy@${1}.service" 2>/dev/null || true
}

restart_connect_sidecar() {
  ensure_connect_envoy_unit_installed || return 1
  systemctl enable "connect-envoy@${1}.service"
  systemctl restart "connect-envoy@${1}.service"
}

reregister_connect_service() {
  local name="$1" hcl_file="$2"
  stop_connect_sidecar "${name}"
  consul services deregister "${name}" 2>/dev/null || true
  consul services register "${hcl_file}" || { rm -f "${hcl_file}"; return 1; }
  rm -f "${hcl_file}"
  restart_connect_sidecar "${name}"
}
