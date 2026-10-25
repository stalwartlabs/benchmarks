# shellcheck shell=bash disable=SC2034

set -euo pipefail

AZ_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$AZ_LIB_DIR/../.." && pwd)"
BENCH_WORK="${BENCH_WORK:-$REPO/work}"
BENCH_IMAGE="${BENCH_IMAGE:-Canonical:ubuntu-24_04-lts:server:latest}"
BENCH_ADMIN="${BENCH_ADMIN:-bench}"
BENCH_RG_PREFIX="${BENCH_RG_PREFIX:-}"
BENCH_SUBNET_BITS="${BENCH_SUBNET_BITS:-20}"
BENCH_LB_IDLE_MINUTES="${BENCH_LB_IDLE_MINUTES:-100}"
BENCH_DRY_RUN="${BENCH_DRY_RUN:-0}"

export AZURE_CORE_ONLY_SHOW_ERRORS=true
export AZURE_CORE_COLLECT_TELEMETRY=false

die() { echo "${0##*/}: $*" >&2; exit 1; }
say() { echo "[$(date -u +%H:%M:%S)] ${0##*/}: $*" >&2; }

dry() { [ "$BENCH_DRY_RUN" = 1 ]; }

show_cmd() { printf '+'; printf ' %q' "$@"; printf '\n'; }

az_do() {
  if dry; then show_cmd az "$@" >&2; return 0; fi
  az "$@"
}

az_read() {
  if dry; then show_cmd az "$@" >&2; return 1; fi
  az "$@"
}

need() {
  local tool
  for tool in "$@"; do command -v "$tool" > /dev/null 2>&1 || die "$tool is required"; done
}

LOCATIONS=""

topo() { jq -r "$@" "$TOPOLOGY"; }

check_topology() {
  [ -f "$TOPOLOGY" ] || die "topology $TOPOLOGY not found"
  jq -e '.track and (.regions | type == "object") and (.vms | type == "array")' "$TOPOLOGY" > /dev/null \
    || die "$TOPOLOGY: needs track, regions and vms"
  jq -e '[.vms[].name] | (length == (unique | length)) and all(test("^[a-z][a-z0-9-]{0,30}$"))' "$TOPOLOGY" > /dev/null \
    || die "$TOPOLOGY: VM names must be unique and match [a-z][a-z0-9-]"
  jq -e '. as $t | all(.vms[]; .region as $r | $t.regions | has($r))' "$TOPOLOGY" > /dev/null \
    || die "$TOPOLOGY: every VM needs a region listed in regions"
}

region_roles() { topo '.regions | keys[]'; }

region_location() {
  local role="$1" pair loc
  for pair in $LOCATIONS; do
    if [ "${pair%%=*}" = "$role" ]; then echo "${pair#*=}"; return; fi
  done
  loc=$(topo --arg r "$role" '.regions[$r].location')
  case "$loc" in
    ''|null|REGION_*) die "region $role has no location yet ($loc); pass --location $role=LOCATION" ;;
  esac
  echo "$loc"
}

region_prefix() { topo --arg r "$1" '.regions[$r].prefix'; }

region_ppg() { topo --arg r "$1" '.regions[$r].ppg // false'; }

rg_name() {
  if [ "$1" = main ]; then echo "$BENCH_RG_PREFIX$RUN"; else echo "$BENCH_RG_PREFIX$RUN-$1"; fi
}

vm_names() {
  if [ -n "${1:-}" ]; then topo --arg r "$1" '.vms[] | select(.region == $r) | .name'; else topo '.vms[].name'; fi
}

vm_field() { topo --arg n "$1" --arg f "$2" '.vms[] | select(.name == $n) | .[$f] // empty'; }

subnet_prefix() {
  local prefix="$1"
  echo "${prefix%/*}/$BENCH_SUBNET_BITS"
}

run_dir() { echo "$BENCH_WORK/$RUN"; }

tags() {
  local t
  t="bench-run=$RUN bench-track=$(topo .track)"
  # shellcheck disable=SC2086
  echo $t ${BENCH_AZ_TAGS:-}
}

operator_cidr() {
  if [ -n "${BENCH_OPERATOR_CIDR:-}" ]; then echo "$BENCH_OPERATOR_CIDR"; return; fi
  if dry; then echo 203.0.113.10/32; return; fi
  local ip
  ip=$(curl -sf --max-time 10 https://api.ipify.org) || die "cannot find this machine's public IP; set BENCH_OPERATOR_CIDR"
  echo "$ip/32"
}

ssh_key() {
  local key="${BENCH_SSH_KEY:-$BENCH_WORK/keys/id_ed25519}"
  if [ ! -f "$key" ]; then
    mkdir -p "$(dirname "$key")"
    ssh-keygen -q -t ed25519 -N "" -C bench -f "$key"
  fi
  echo "$key"
}

RUN=""
TOPOLOGY=""
SHIFT=1

common_arg() {
  SHIFT=1
  case "$1" in
    --run) RUN="${2:?--run needs a value}"; SHIFT=2 ;;
    --location) LOCATIONS="$LOCATIONS ${2:?--location needs ROLE=LOCATION}"; SHIFT=2 ;;
    --rg-prefix) BENCH_RG_PREFIX="${2:?--rg-prefix needs a value}"; SHIFT=2 ;;
    --dry-run) BENCH_DRY_RUN=1 ;;
    -*) die "unknown option $1" ;;
    *) [ -z "$TOPOLOGY" ] || die "unexpected argument $1"; TOPOLOGY="$1" ;;
  esac
}

finish_common() {
  [ -n "$TOPOLOGY" ] || die "usage: ${0##*/} TOPOLOGY.json --run RUN [--location ROLE=LOCATION]... [--rg-prefix P] [--dry-run]"
  [[ "$RUN" =~ ^[a-z0-9][a-z0-9-]{0,38}$ ]] || die "--run must match [a-z0-9-], at most 39 characters"
  check_topology
  if ! dry; then need az jq; fi
  mkdir -p "$(run_dir)"
}
