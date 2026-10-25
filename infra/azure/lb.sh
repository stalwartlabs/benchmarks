#!/usr/bin/env bash
# Standard Load Balancers of a topology ("lbs"), after the VMs exist.
#
#   lb.sh create TOPOLOGY --run RUN [--location ROLE=LOC]...
#   lb.sh delete TOPOLOGY --run RUN
#
# kind "public": static public frontend; kind "internal": private frontend in the region's subnet (S3 over peering).
# Every port gets a TCP health probe and a rule with 5-tuple distribution, the maximum idle timeout
# (BENCH_LB_IDLE_MINUTES, 100) and TCP reset on idle. Backends join through their NIC IP configuration, so the
# client IP is preserved. For public LBs the NSG admits the ports from the public IPs of the "clients" VMs (and
# from BENCH_CLIENT_CIDRS). Frontend IPs are written to work/RUN/lb/NAME.json for inventory.sh.

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

lb_json() { topo --arg n "$1" '.lbs[] | select(.name == $n)'; }

nic_of() {
  local rg="$1" vm="$2" id
  if dry; then echo "${vm}VMNic ipconfig$vm"; return; fi
  id=$(az vm show -g "$rg" -n "$vm" --query 'networkProfile.networkInterfaces[0].id' -o tsv)
  echo "${id##*/} $(az network nic ip-config list -g "$rg" --nic-name "${id##*/}" --query '[0].name' -o tsv)"
}

vm_public_ip() {
  local vm="$1"
  if dry; then echo 198.51.100.7; return; fi
  az vm show -d -g "$(rg_name "$(vm_field "$vm" region)")" -n "$vm" --query publicIps -o tsv | cut -d, -f1
}

create_lb() {
  local name="$1" kind role rg loc lb port ports backend nic ipc pools sources prio fe_ip
  kind=$(lb_json "$name" | jq -r .kind); role=$(lb_json "$name" | jq -r .region)
  rg=$(rg_name "$role"); loc=$(region_location "$role"); lb="lb-$name"
  ports=$(lb_json "$name" | jq -r '.ports[]')
  if ! az_read network lb show -g "$rg" -n "$lb" -o none 2> /dev/null; then
    say "$rg: creating $kind load balancer $lb"
    if [ "$kind" = public ]; then
      if ! az_read network public-ip show -g "$rg" -n "$lb-ip" -o none 2> /dev/null; then
        # shellcheck disable=SC2046
        az_do network public-ip create -g "$rg" -n "$lb-ip" -l "$loc" --sku Standard --allocation-method Static \
          --tags $(tags) -o none
      fi
      # shellcheck disable=SC2046
      az_do network lb create -g "$rg" -n "$lb" -l "$loc" --sku Standard --public-ip-address "$lb-ip" \
        --frontend-ip-name fe --backend-pool-name be --tags $(tags) -o none
    else
      # shellcheck disable=SC2046
      az_do network lb create -g "$rg" -n "$lb" -l "$loc" --sku Standard --vnet-name vnet --subnet main \
        --frontend-ip-name fe --backend-pool-name be --tags $(tags) -o none
    fi
  fi
  for port in $ports; do
    if ! az_read network lb probe show -g "$rg" --lb-name "$lb" -n "p$port" -o none 2> /dev/null; then
      az_do network lb probe create -g "$rg" --lb-name "$lb" -n "p$port" --protocol Tcp --port "$port" \
        --interval 5 -o none
    fi
    if ! az_read network lb rule show -g "$rg" --lb-name "$lb" -n "r$port" -o none 2> /dev/null; then
      local snat=()
      [ "$kind" = public ] && snat=(--disable-outbound-snat true)
      az_do network lb rule create -g "$rg" --lb-name "$lb" -n "r$port" --protocol Tcp \
        --frontend-port "$port" --backend-port "$port" --frontend-ip-name fe --backend-pool-name be \
        --probe-name "p$port" --idle-timeout "$BENCH_LB_IDLE_MINUTES" --enable-tcp-reset true \
        --load-distribution Default ${snat[@]+"${snat[@]}"} -o none
    fi
  done
  for backend in $(lb_json "$name" | jq -r '.backends[]'); do
    read -r nic ipc <<< "$(nic_of "$rg" "$backend")"
    pools=$(az_read network nic ip-config show -g "$rg" --nic-name "$nic" -n "$ipc" \
      --query 'loadBalancerBackendAddressPools[].id' -o tsv 2> /dev/null || true)
    if printf '%s\n' "$pools" | grep -q "/loadBalancers/$lb/backendAddressPools/be$"; then continue; fi
    say "$lb: adding $backend"
    az_do network nic ip-config address-pool add -g "$rg" --nic-name "$nic" --ip-config-name "$ipc" \
      --lb-name "$lb" --address-pool be -o none
  done
  if [ "$kind" = public ]; then
    sources="${BENCH_CLIENT_CIDRS:-}"
    for backend in $(lb_json "$name" | jq -r '.clients // [] | .[]'); do
      sources="$sources $(vm_public_ip "$backend")/32"
    done
    if [ -n "${sources// /}" ]; then
      prio=$((200 + $(topo --arg n "$name" '[.lbs[].name] | index($n)')))
      # shellcheck disable=SC2086
      az_do network nsg rule create -g "$rg" --nsg-name nsg -n "clients-$name" --priority "$prio" --access Allow \
        --protocol Tcp --direction Inbound --source-address-prefixes $sources \
        --destination-port-ranges $ports -o none
    fi
    fe_ip=$(az_read network public-ip show -g "$rg" -n "$lb-ip" --query ipAddress -o tsv 2> /dev/null || echo 192.0.2.10)
  else
    fe_ip=$(az_read network lb frontend-ip show -g "$rg" --lb-name "$lb" -n fe --query privateIPAddress -o tsv \
      2> /dev/null || echo 10.255.0.10)
  fi
  mkdir -p "$(run_dir)/lb"
  lb_json "$name" | jq --arg ip "$fe_ip" '{name, kind, region, ports, backends, ip: $ip}' > "$(run_dir)/lb/$name.json"
  say "$lb: frontend $fe_ip"
}

delete_lb() {
  local name="$1" role rg lb
  role=$(lb_json "$name" | jq -r .region); rg=$(rg_name "$role"); lb="lb-$name"
  az_do network lb delete -g "$rg" -n "$lb" -o none 2> /dev/null || true
  az_do network public-ip delete -g "$rg" -n "$lb-ip" -o none 2> /dev/null || true
  az_do network nsg rule delete -g "$rg" --nsg-name nsg -n "clients-$name" -o none 2> /dev/null || true
  rm -f "$(run_dir)/lb/$name.json"
}

main() {
  local cmd="${1:-}" name
  [ $# -gt 0 ] && shift
  while [ $# -gt 0 ]; do common_arg "$@"; shift "$SHIFT"; done
  finish_common
  case "$cmd" in
    create) for name in $(topo '.lbs[].name'); do create_lb "$name"; done ;;
    delete) for name in $(topo '.lbs[].name'); do delete_lb "$name"; done ;;
    *) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 2 ;;
  esac
}

main "$@"
