#!/usr/bin/env bash
# Pre-flight checks for a topology: every size is offered without restriction in its location, and the regional
# and per-family vCPU quotas leave room for the VMs that do not exist yet. Exit 1 when a check fails.
#
#   quota.sh TOPOLOGY --run RUN [--location ROLE=LOC]... [--credits]
#
# --credits also prints the remaining Azure credit (Microsoft.Consumption lots of BENCH_AZ_BILLING_PROFILE, the
# billing profile resource id) and fails below BENCH_CREDIT_FLOOR_USD (default 0).

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

check_location() {
  local loc="$1" need skus usage
  need=$(jq -c --arg loc "$loc" '[.[] | select(.location == $loc)]' <<< "$PLAN")
  if dry; then az_read vm list-skus -l "$loc" --resource-type virtualMachines -o json || true; az_read vm list-usage -l "$loc" -o json || true; return 0; fi
  skus=$(az vm list-skus -l "$loc" --resource-type virtualMachines -o json | jq -c '[.[] | {name,
    family, restricted: ((.restrictions // []) | length > 0),
    vcpus: ([.capabilities[]? | select(.name == "vCPUs") | .value | tonumber][0])}]')
  usage=$(az vm list-usage -l "$loc" -o json)
  jq -nr --argjson need "$need" --argjson skus "$skus" --argjson usage "$usage" --arg loc "$loc" '
    def usage($k): [$usage[] | select((.name.value | ascii_downcase) == ($k | ascii_downcase))][0];
    [$need[] | . as $v | ($skus[] | select(.name == $v.size)) as $s
      | {size: $v.size, name: $v.name, exists: $v.exists, family: $s.family, vcpus: $s.vcpus, restricted: $s.restricted}] as $rows
    | ($need | map(.size) - ($rows | map(.size)) | unique) as $missing
    | (if ($missing | length) > 0 then "FAIL \($loc): sizes not offered: \($missing | join(" "))" else empty end),
      ($rows[] | select(.restricted) | "FAIL \($loc): \(.size) is restricted for this subscription"),
      ([$rows[] | select(.exists | not)] as $new
       | ([$new[].vcpus] | add // 0) as $total
       | usage("cores") as $c
       | "\(if (($c.limit | tonumber) - ($c.currentValue | tonumber)) >= $total then "ok  " else "FAIL" end) \($loc): regional vCPUs \($c.currentValue)/\($c.limit) used, need \($total) more",
         ($new | group_by(.family)[] | (map(.vcpus) | add) as $n | usage(.[0].family) as $f
          | if $f == null then "ok   \($loc): \(.[0].family) has no separate quota"
            else "\(if (($f.limit | tonumber) - ($f.currentValue | tonumber)) >= $n then "ok  " else "FAIL" end) \($loc): \($f.name.localizedValue) \($f.currentValue)/\($f.limit) used, need \($n) more" end))'
}

credits() {
  local scope="${BENCH_AZ_BILLING_PROFILE:-}" floor="${BENCH_CREDIT_FLOOR_USD:-0}" lots
  [ -n "$scope" ] || { echo "skip credits: set BENCH_AZ_BILLING_PROFILE to the billing profile resource id"; return 0; }
  if dry; then az_read rest --method get --url "https://management.azure.com$scope/providers/Microsoft.Consumption/lots?api-version=2023-03-01" || true; return 0; fi
  lots=$(az rest --method get --url "https://management.azure.com$scope/providers/Microsoft.Consumption/lots?api-version=2023-03-01" -o json)
  jq -r --argjson floor "$floor" 'def ts: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
    [.value[].properties | select((.expirationDate | ts) > now and (.startDate | ts) <= now)]
    | (map(.closedBalance.value) | add // 0) as $b | (map(.expirationDate) | min // "none") as $e
    | "\(if $b > $floor then "ok  " else "FAIL" end) credit balance \($b) (as of the last billing close), first lot expires \($e)"' <<< "$lots"
}

main() {
  local with_credits=0 out loc existing name
  while [ $# -gt 0 ]; do
    case "$1" in
      --credits) with_credits=1; shift ;;
      *) common_arg "$@"; shift "$SHIFT" ;;
    esac
  done
  finish_common
  PLAN="[]"
  for name in $(vm_names); do
    existing=false
    if ! dry && az vm show -g "$(rg_name "$(vm_field "$name" region)")" -n "$name" -o none 2> /dev/null; then existing=true; fi
    PLAN=$(jq -c --arg n "$name" --arg s "$(vm_field "$name" size)" --arg loc "$(region_location "$(vm_field "$name" region)")" \
      --argjson e "$existing" '. + [{name: $n, size: $s, location: $loc, exists: $e}]' <<< "$PLAN")
  done
  out=""
  for loc in $(jq -r '[.[].location] | unique[]' <<< "$PLAN"); do
    out="$out$(check_location "$loc")"$'\n'
  done
  [ "$with_credits" = 1 ] && out="$out$(credits)"$'\n'
  printf '%s' "$out"
  if printf '%s' "$out" | grep -q '^FAIL'; then exit 1; fi
}

main "$@"
