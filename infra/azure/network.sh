#!/usr/bin/env bash
# Resource groups, NSGs, VNets and global VNet peering for a topology.
#
#   network.sh create   TOPOLOGY --run RUN [--location ROLE=LOC]...   resource group, NSG (SSH from the operator only)
#                                                                    and VNet with the region's prefix, per region
#   network.sh renumber TOPOLOGY --run RUN [--rg-prefix P]           move an existing, still empty VNet named "vnet"
#                                                                    (subnet "main") to the topology prefix, for
#                                                                    resource groups created by other tooling
#   network.sh allow-ssh TOPOLOGY --run RUN                          add this machine's public IP to the SSH rule
#   network.sh peer     TOPOLOGY --run RUN                           global peering for every pair in "peerings"
#
# Idempotent: existing resources are kept. --dry-run prints the az commands without running them.

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

create_region() {
  local role="$1" loc rg prefix cidr
  loc=$(region_location "$role"); rg=$(rg_name "$role"); prefix=$(region_prefix "$role")
  if az_read group show -n "$rg" -o none 2> /dev/null; then
    say "resource group $rg exists"
  else
    say "creating resource group $rg in $loc"
    # shellcheck disable=SC2046
    az_do group create -n "$rg" -l "$loc" --tags $(tags) -o none
  fi
  if ! az_read network nsg show -g "$rg" -n nsg -o none 2> /dev/null; then
    # shellcheck disable=SC2046
    az_do network nsg create -g "$rg" -n nsg -l "$loc" --tags $(tags) -o none
  fi
  cidr=$(operator_cidr)
  if ! az_read network nsg rule show -g "$rg" --nsg-name nsg -n ssh-from-operator -o none 2> /dev/null; then
    az_do network nsg rule create -g "$rg" --nsg-name nsg -n ssh-from-operator --priority 100 --access Allow \
      --protocol Tcp --direction Inbound --source-address-prefixes "$cidr" --destination-port-ranges 22 -o none
  fi
  if ! az_read network vnet show -g "$rg" -n vnet -o none 2> /dev/null; then
    # shellcheck disable=SC2046
    az_do network vnet create -g "$rg" -n vnet -l "$loc" --address-prefixes "$prefix" --subnet-name main \
      --subnet-prefixes "$(subnet_prefix "$prefix")" --network-security-group nsg --tags $(tags) -o none
  fi
}

renumber_region() {
  local role="$1" rg prefix subnet current used
  rg=$(rg_name "$role"); prefix=$(region_prefix "$role"); subnet=$(subnet_prefix "$prefix")
  if dry; then
    az_read network vnet show -g "$rg" -n vnet --query addressSpace.addressPrefixes -o tsv || true
    az_do network vnet update -g "$rg" -n vnet --address-prefixes "$prefix" OLD_PREFIX -o none > /dev/null
    az_do network vnet subnet update -g "$rg" --vnet-name vnet -n main --address-prefixes "$subnet" -o none > /dev/null
    az_do network vnet update -g "$rg" -n vnet --address-prefixes "$prefix" -o none > /dev/null
    return
  fi
  current=$(az network vnet show -g "$rg" -n vnet --query 'addressSpace.addressPrefixes' -o tsv | tr '\n' ' ')
  current="${current% }"
  if [ "$current" = "$prefix" ]; then say "$rg: VNet already on $prefix"; return; fi
  used=$(az network vnet subnet show -g "$rg" --vnet-name vnet -n main --query 'length(ipConfigurations || `[]`)' -o tsv)
  [ "$used" = 0 ] || die "$rg: subnet main already has $used NICs; renumber only before the first VM"
  say "$rg: VNet $current -> $prefix"
  # shellcheck disable=SC2086
  az network vnet update -g "$rg" -n vnet --address-prefixes "$prefix" $current -o none
  az network vnet subnet update -g "$rg" --vnet-name vnet -n main --address-prefixes "$subnet" -o none
  az network vnet update -g "$rg" -n vnet --address-prefixes "$prefix" -o none
}

allow_ssh_region() {
  local rg cidr sources
  rg=$(rg_name "$1"); cidr=$(operator_cidr)
  if dry; then
    az_do network nsg rule update -g "$rg" --nsg-name nsg -n ssh-from-operator --source-address-prefixes EXISTING "$cidr" -o none > /dev/null
    return
  fi
  sources=$(az network nsg rule show -g "$rg" --nsg-name nsg -n ssh-from-operator -o json \
    | jq -r '([.sourceAddressPrefix // empty] + (.sourceAddressPrefixes // [])) | map(select(. != "*")) | .[]')
  if printf '%s\n' "$sources" | grep -qxF "$cidr"; then return; fi
  say "$rg: allowing SSH from $cidr"
  # shellcheck disable=SC2046
  az network nsg rule update -g "$rg" --nsg-name nsg -n ssh-from-operator \
    --source-address-prefixes $(printf '%s\n' "$sources" | grep -v '^$' || true) "$cidr" -o none
}

vnet_id() {
  if dry; then echo "/subscriptions/SUB/resourceGroups/$1/providers/Microsoft.Network/virtualNetworks/vnet"; return; fi
  az network vnet show -g "$1" -n vnet --query id -o tsv
}

peer_pair() {
  local a="$1" b="$2" rga rgb
  rga=$(rg_name "$a"); rgb=$(rg_name "$b")
  peer_one "$rga" "$rgb" "peer-$b"
  peer_one "$rgb" "$rga" "peer-$a"
}

peer_one() {
  local rg="$1" remote="$2" name="$3" state
  state=$(az_read network vnet peering show -g "$rg" --vnet-name vnet -n "$name" --query peeringState -o tsv 2> /dev/null || true)
  case "$state" in
    Connected|Initiated) say "$rg: peering $name is $state"; return ;;
    Disconnected) az_do network vnet peering delete -g "$rg" --vnet-name vnet -n "$name" -o none ;;
  esac
  say "$rg: peering to $remote"
  az_do network vnet peering create -g "$rg" --vnet-name vnet -n "$name" --remote-vnet "$(vnet_id "$remote")" \
    --allow-vnet-access -o none
}

main() {
  local cmd="${1:-}" role pair
  [ $# -gt 0 ] && shift
  while [ $# -gt 0 ]; do common_arg "$@"; shift "$SHIFT"; done
  finish_common
  case "$cmd" in
    create) for role in $(region_roles); do create_region "$role"; done ;;
    renumber) for role in $(region_roles); do renumber_region "$role"; done ;;
    allow-ssh) for role in $(region_roles); do allow_ssh_region "$role"; done ;;
    peer)
      for pair in $(topo '.peerings[] | join(":")'); do peer_pair "${pair%%:*}" "${pair#*:}"; done ;;
    *) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 2 ;;
  esac
}

main "$@"
