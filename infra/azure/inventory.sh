#!/usr/bin/env bash
# Write the inventory (hosts.json) that every script under scripts/ takes, from the live VMs of a topology.
#
#   inventory.sh TOPOLOGY --run RUN [--rg-prefix P] [--ssh-key KEY] [--known-hosts FILE] [--user U] [--out FILE]
#
# The VMs may come from vms.sh or from any other tooling, as long as they carry the topology's names and live in
# the resource groups that --rg-prefix names (default empty: RUN for region "main", RUN-ROLE for the others;
# "sbench-" for groups that follow that naming). LB frontends come from work/RUN/lb/*.json (lb.sh). Default output: work/RUN/hosts.json.

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

main() {
  local key="" known="" user="$BENCH_ADMIN" out="" role rg vms="[]" lbs="[]" regions="{}" name f
  while [ $# -gt 0 ]; do
    case "$1" in
      --ssh-key) key="${2:?}"; shift 2 ;;
      --known-hosts) known="${2:?}"; shift 2 ;;
      --user) user="${2:?}"; shift 2 ;;
      --out) out="${2:?}"; shift 2 ;;
      *) common_arg "$@"; shift "$SHIFT" ;;
    esac
  done
  finish_common
  key="${key:-$(ssh_key)}"; known="${known:-$(run_dir)/known_hosts}"; out="${out:-$(run_dir)/hosts.json}"
  for role in $(region_roles); do
    rg=$(rg_name "$role")
    regions=$(jq -c --arg r "$role" --arg loc "$(region_location "$role")" --arg rg "$rg" \
      '. + {($r): {location: $loc, resource_group: $rg}}' <<< "$regions")
    if dry; then
      vms=$(jq -c --arg r "$role" --argjson t "$(cat "$TOPOLOGY")" '. + [$t.vms | to_entries[]
        | select(.value.region == $r)
        | {name: .value.name, privateIps: "10.0.0.\(.key + 4)", publicIps: "192.0.2.\(.key + 4)"}]' <<< "$vms")
      continue
    fi
    vms=$(jq -c --argjson add "$(az vm list -d -g "$rg" --query '[].{name: name, privateIps: privateIps, publicIps: publicIps}' -o json)" \
      '. + $add' <<< "$vms")
  done
  for f in "$(run_dir)"/lb/*.json; do
    [ -f "$f" ] && lbs=$(jq -c --slurpfile l "$f" '. + $l' <<< "$lbs")
  done
  for name in $(vm_names); do
    jq -e --arg n "$name" 'any(.[]; .name == $n)' <<< "$vms" > /dev/null || die "VM $name of the topology does not exist"
  done
  jq -n --arg run "$RUN" --argjson regions "$regions" --argjson vms "$vms" --argjson lbs "$lbs" \
    --arg user "$user" --arg key "$key" --arg known "$known" --slurpfile t "$TOPOLOGY" '
    {run: $run, track: $t[0].track, provider: "azure",
     ssh: {user: $user, key: $key, known_hosts: $known},
     regions: $regions,
     targets: ($t[0].targets // {}),
     hosts: [$t[0].vms[] as $v | ($vms[] | select(.name == $v.name)) as $m
       | {name: $v.name, role: $v.role, region: $v.region, size: $v.size, nvme: ($v.nvme // false),
          private_ip: ($m.privateIps | split(",")[0]), public_ip: ($m.publicIps | split(",")[0]),
          provision: ($v.provision // [])}],
     lbs: $lbs}' > "$out.tmp"
  mv "$out.tmp" "$out"
  say "inventory: $out"
  echo "$out"
}

main "$@"
