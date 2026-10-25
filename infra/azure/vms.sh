#!/usr/bin/env bash
# Proximity placement groups and VMs of a topology.
#
#   vms.sh create TOPOLOGY --run RUN [--location ROLE=LOC]... [--only NAME]...   create missing VMs, then wait for them
#   vms.sh wait   TOPOLOGY --run RUN [--only NAME]...                            wait until cloud-init finished
#   vms.sh delete TOPOLOGY --run RUN --only NAME...                              delete VMs (with disks, NIC, public IP)
#
# Every region with "ppg": true gets a proximity placement group "ppg"; its first VM is created alone so that it
# pins the datacenter, the others follow in parallel. A VM that already exists is kept (resumable); one in a failed
# state is deleted and created again. Each VM is tried up to three times. Local NVMe is formatted later, over SSH,
# by scripts/remote/nvme.sh, so the same step works for VMs created by other tooling.

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

ONLY=""

selected() {
  local name="$1" o
  [ -z "$ONLY" ] && return 0
  for o in $ONLY; do [ "$o" = "$name" ] && return 0; done
  return 1
}

cloud_init() {
  printf '#!/bin/bash\ntouch /var/lib/bench-ready\n'
}

vm_state() {
  az_read vm show -g "$1" -n "$2" --query provisioningState -o tsv 2> /dev/null || true
}

ensure_ppg() {
  local role="$1" rg loc
  [ "$(region_ppg "$role")" = true ] || return 0
  rg=$(rg_name "$role"); loc=$(region_location "$role")
  if az_read ppg show -g "$rg" -n ppg -o none 2> /dev/null; then return 0; fi
  say "$rg: creating proximity placement group"
  # shellcheck disable=SC2046
  az_do ppg create -g "$rg" -n ppg -l "$loc" -t Standard --tags $(tags) -o none
}

delete_vm() {
  local rg="$1" name="$2"
  az_do vm delete -g "$rg" -n "$name" --yes -o none || true
  az_do network public-ip delete -g "$rg" -n "${name}PublicIP" -o none 2> /dev/null || true
}

create_vm() {
  local name="$1" role rg size disk ppg_args=() state attempt dir ci key errf
  role=$(vm_field "$name" region); rg=$(rg_name "$role")
  size=$(vm_field "$name" size); disk=$(vm_field "$name" disk); disk="${disk:-64}"
  dir="$(run_dir)/vm"; mkdir -p "$dir"
  [ "$(region_ppg "$role")" = true ] && ppg_args=(--ppg ppg)
  key=$(ssh_key)
  state=$(vm_state "$rg" "$name")
  case "$state" in
    Succeeded) say "$name exists"; return 0 ;;
    '') ;;
    *) say "$name is in state $state, recreating"; delete_vm "$rg" "$name" ;;
  esac
  ci="$dir/$name.cloud-init"; cloud_init > "$ci"
  errf="$dir/$name.err"; dry && errf=/dev/stderr
  for attempt in 1 2 3; do
    say "creating $name ($size) in $rg, attempt $attempt"
    # shellcheck disable=SC2046
    if az_do vm create -g "$rg" -n "$name" --image "$BENCH_IMAGE" --size "$size" \
        --admin-username "$BENCH_ADMIN" --ssh-key-values "$key.pub" \
        --vnet-name vnet --subnet main --nsg "" --public-ip-sku Standard --accelerated-networking true \
        --os-disk-size-gb "$disk" --storage-sku Premium_LRS \
        --os-disk-delete-option Delete --nic-delete-option Delete --data-disk-delete-option Delete \
        ${ppg_args[@]+"${ppg_args[@]}"} --custom-data "$ci" --tags $(tags) bench-role="$(vm_field "$name" role)" \
        -o json > "$dir/$name.create.json" 2> "$errf"; then
      dry && return 0
      state=$(vm_state "$rg" "$name")
      [ "$state" = Succeeded ] && return 0
    fi
    say "$name: attempt $attempt failed: $(tail -2 "$dir/$name.err" | tr '\n' ' ' | cut -c1-300)"
    state=$(vm_state "$rg" "$name")
    [ "$state" = Succeeded ] && return 0
    [ -n "$state" ] && delete_vm "$rg" "$name"
    sleep $((attempt * 10))
  done
  return 1
}

create_all() {
  local role name first pids=() failed=0 pid
  for role in $(region_roles); do ensure_ppg "$role"; done
  for role in $(region_roles); do
    first=""
    for name in $(vm_names "$role"); do
      selected "$name" || continue
      if [ "$(region_ppg "$role")" = true ] && [ -z "$first" ]; then
        first="$name"
        create_vm "$name" || die "VM $name failed after 3 attempts"
        continue
      fi
      create_vm "$name" & pids+=($!)
    done
  done
  for pid in ${pids[@]+"${pids[@]}"}; do wait "$pid" || failed=1; done
  [ "$failed" = 0 ] || die "VM creation failed; see $(run_dir)/vm/*.err"
}

public_ip() {
  az vm show -d -g "$(rg_name "$(vm_field "$1" region)")" -n "$1" --query publicIps -o tsv | cut -d, -f1
}

wait_vm() {
  local name="$1" ip key i state
  key=$(ssh_key); ip=$(public_ip "$name")
  [ -n "$ip" ] || die "$name has no public IP"
  ssh-keygen -R "$ip" -f "$(run_dir)/known_hosts" > /dev/null 2>&1 || true
  for i in $(seq 1 90); do
    state=$(ssh -i "$key" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
      -o UserKnownHostsFile="$(run_dir)/known_hosts" "$BENCH_ADMIN@$ip" \
      'if test -f /var/lib/bench-ready || test -f /var/lib/azb-ready; then echo ready; else cloud-init status 2>/dev/null | sed -n "s/^status: //p"; fi' \
      2> /dev/null || echo unreachable)
    case "$state" in
      ready|done) say "$name ready ($ip)"; return 0 ;;
      error|degraded*) die "$name: cloud-init $state" ;;
    esac
    [ $((i % 6)) = 0 ] && say "$name: $state"
    sleep 10
  done
  die "$name not ready after 15 minutes"
}

wait_all() {
  local name pids=() failed=0 pid
  if dry; then say "dry run: skipping the readiness wait"; return; fi
  for name in $(vm_names); do
    selected "$name" || continue
    wait_vm "$name" & pids+=($!)
  done
  for pid in ${pids[@]+"${pids[@]}"}; do wait "$pid" || failed=1; done
  [ "$failed" = 0 ] || die "some VMs did not become ready"
}

main() {
  local cmd="${1:-}" name
  [ $# -gt 0 ] && shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --only) ONLY="$ONLY ${2:?--only needs a VM name}"; shift 2 ;;
      *) common_arg "$@"; shift "$SHIFT" ;;
    esac
  done
  finish_common
  case "$cmd" in
    create) create_all; wait_all ;;
    wait) wait_all ;;
    delete)
      [ -n "$ONLY" ] || die "delete needs --only NAME"
      for name in $ONLY; do delete_vm "$(rg_name "$(vm_field "$name" region)")" "$name"; done ;;
    *) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 2 ;;
  esac
}

main "$@"
