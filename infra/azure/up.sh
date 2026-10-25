#!/usr/bin/env bash
# Deploy a topology on Azure: quota check, resource groups + NSGs + VNets, proximity placement groups and VMs,
# load balancers, global peering, inventory. Every step is idempotent, so rerunning resumes after a failure.
#
#   up.sh TOPOLOGY --run RUN [--location ROLE=LOC]... [--rg-prefix P] [--no-network] [--no-vms] [--skip-quota]
#         [--dry-run]
#
# --no-network and --no-vms skip the steps for resource groups and VMs created by other tooling (the VNet must
# then be named "vnet" with subnet "main" and NSG "nsg"; network.sh renumber moves it to the topology prefix).
# Prints the inventory path (work/RUN/hosts.json).

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

main() {
  local network=1 vms=1 quota=1 args=() here
  here="$(dirname "$0")"
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-network) network=0; shift ;;
      --no-vms) vms=0; shift ;;
      --skip-quota) quota=0; shift ;;
      *) common_arg "$@"; args+=("${@:1:$SHIFT}"); shift "$SHIFT" ;;
    esac
  done
  finish_common
  if [ "$quota" = 1 ] && [ "$vms" = 1 ]; then "$here/quota.sh" "${args[@]}"; fi
  if [ "$network" = 1 ]; then "$here/network.sh" create "${args[@]}"; fi
  if [ "$vms" = 1 ]; then "$here/vms.sh" create "${args[@]}"; fi
  if [ "$(topo '.lbs | length')" -gt 0 ]; then "$here/lb.sh" create "${args[@]}"; fi
  if [ "$(topo '.peerings | length')" -gt 0 ]; then "$here/network.sh" peer "${args[@]}"; fi
  "$here/inventory.sh" "${args[@]}"
}

main "$@"
