#!/usr/bin/env bash
# Bootstrap a DC4 HashiCups service VM — Docker only, NO Consul agent.
# ESM on the DC4 server performs health checks against this VM externally.
#
# Usage: sudo bash bootstrap-dc4-hashicups.sh <ROLE> [additional args...]
#   ROLE: postgres | product-api | payments | public-api | frontend
#
# Before running, SCP from repo root:
#   scp -i $KEY -r vm/ ubuntu@$HC_IP:/tmp/
#   ssh -i $KEY ubuntu@$HC_IP \
#     "sudo bash /tmp/vm/scripts/bootstrap-dc4-hashicups.sh <ROLE> [args]"
#
# Role-specific args (passed through to the on-<role>.sh script):
#   postgres    : (none)
#   product-api : <POSTGRES_PRIVATE_IP>
#   payments    : (none)
#   public-api  : <PRODUCT_API_PRIVATE_IP> <PAYMENTS_PRIVATE_IP>
#   frontend    : <PUBLIC_API_PRIVATE_IP>
set -euo pipefail

ROLE="${1:?Usage: $0 <ROLE> [args]}"
shift

VM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${VM_DIR}/hashicups/dc4/on-${ROLE}.sh"

if [[ ! -f "${SCRIPT}" ]]; then
  echo "ERROR: No script for role '${ROLE}': ${SCRIPT}" >&2
  exit 1
fi

# Docker is pre-installed by user_data — just verify it's up.
systemctl is-active --quiet docker || {
  echo "Waiting for Docker..."
  systemctl start docker
  sleep 3
}

echo "==> bootstrap-dc4-hashicups | role: ${ROLE} (no Consul agent)"
bash "${SCRIPT}" "$@"
echo "==> ${ROLE} started. ESM will health-check this VM once registered."
