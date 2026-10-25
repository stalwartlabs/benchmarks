# shellcheck shell=bash disable=SC2034

set -euo pipefail

EC2_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$EC2_LIB_DIR/../.." && pwd)"
BENCH_WORK="${BENCH_WORK:-$REPO/work}"
BENCH_EC2_AMI_PARAM="${BENCH_EC2_AMI_PARAM:-/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id}"
BENCH_EC2_USER="${BENCH_EC2_USER:-ubuntu}"
BENCH_SUBNET_BITS="${BENCH_SUBNET_BITS:-20}"
BENCH_LB_IDLE_SECONDS="${BENCH_LB_IDLE_SECONDS:-6000}"
BENCH_DRY_RUN="${BENCH_DRY_RUN:-0}"
export AWS_PAGER=""

die() { echo "${0##*/}: $*" >&2; exit 1; }
say() { echo "[$(date -u +%H:%M:%S)] ${0##*/}: $*" >&2; }
dry() { [ "$BENCH_DRY_RUN" = 1 ]; }
show_cmd() { printf '+'; printf ' %q' "$@"; printf '\n'; }

aws_do() {
  local region="$1"
  shift
  if dry; then show_cmd aws --region "$region" "$@" >&2; echo "dry-$RANDOM"; return 0; fi
  aws --region "$region" "$@"
}

aws_read() {
  local region="$1"
  shift
  if dry; then show_cmd aws --region "$region" "$@" >&2; return 0; fi
  aws --region "$region" "$@"
}

LOCATIONS=""
RUN=""
TOPOLOGY=""
SHIFT=1

topo() { jq -r "$@" "$TOPOLOGY"; }

check_topology() {
  [ -f "$TOPOLOGY" ] || die "topology $TOPOLOGY not found"
  jq -e '.track and (.regions | type == "object") and (.vms | type == "array")' "$TOPOLOGY" > /dev/null \
    || die "$TOPOLOGY: needs track, regions and vms"
  jq -e '. as $t | all(.vms[]; .region as $r | $t.regions | has($r)) and all(.vms[]; .ec2_type)' "$TOPOLOGY" > /dev/null \
    || die "$TOPOLOGY: every VM needs a known region and an ec2_type"
}

region_roles() { topo '.regions | keys[]'; }

region_of() {
  local role="$1" pair loc
  for pair in $LOCATIONS; do
    if [ "${pair%%=*}" = "$role" ]; then echo "${pair#*=}"; return; fi
  done
  loc=$(topo --arg r "$role" '.regions[$r].ec2_region')
  case "$loc" in ''|null|REGION_*) die "region $role has no EC2 region; pass --location $role=REGION" ;; esac
  echo "$loc"
}

region_prefix() { topo --arg r "$1" '.regions[$r].prefix'; }
region_ppg() { topo --arg r "$1" '.regions[$r].ppg // false'; }
subnet_prefix() { echo "${1%/*}/$BENCH_SUBNET_BITS"; }
vm_names() { if [ -n "${1:-}" ]; then topo --arg r "$1" '.vms[] | select(.region == $r) | .name'; else topo '.vms[].name'; fi; }
vm_field() { topo --arg n "$1" --arg f "$2" '.vms[] | select(.name == $n) | .[$f] // empty'; }

vm_type() {
  local var
  var="BENCH_EC2_TYPE_$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')"
  if [ -n "${!var:-}" ]; then echo "${!var}"; else vm_field "$1" ec2_type; fi
}

run_dir() { if dry; then echo "$BENCH_WORK/$RUN.dry"; else echo "$BENCH_WORK/$RUN"; fi; }
state_file() { echo "$(run_dir)/ec2-$1.json"; }

state_get() { jq -r --arg k "$2" '.[$k] // empty' "$(state_file "$1")" 2> /dev/null || true; }
state_set() {
  local f
  f=$(state_file "$1")
  [ -f "$f" ] || echo '{}' > "$f"
  jq --arg k "$2" --arg v "$3" '.[$k] = $v' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

tag_spec() { echo "ResourceType=$1,Tags=[{Key=bench-run,Value=$RUN},{Key=Name,Value=$RUN-$2}]"; }

operator_cidr() {
  if [ -n "${BENCH_OPERATOR_CIDR:-}" ]; then echo "$BENCH_OPERATOR_CIDR"; return; fi
  if dry; then echo 203.0.113.10/32; return; fi
  echo "$(curl -sf --max-time 10 https://checkip.amazonaws.com | tr -d '[:space:]')/32"
}

ssh_key() {
  local key="${BENCH_SSH_KEY:-$BENCH_WORK/keys/id_ed25519}"
  if [ ! -f "$key" ]; then
    mkdir -p "$(dirname "$key")"
    ssh-keygen -q -t ed25519 -N "" -C bench -f "$key"
  fi
  echo "$key"
}

common_arg() {
  SHIFT=1
  case "$1" in
    --run) RUN="${2:?--run needs a value}"; SHIFT=2 ;;
    --location) LOCATIONS="$LOCATIONS ${2:?--location needs ROLE=REGION}"; SHIFT=2 ;;
    --dry-run) BENCH_DRY_RUN=1 ;;
    -*) die "unknown option $1" ;;
    *) [ -z "$TOPOLOGY" ] || die "unexpected argument $1"; TOPOLOGY="$1" ;;
  esac
}

finish_common() {
  [ -n "$TOPOLOGY" ] || die "usage: ${0##*/} TOPOLOGY.json --run RUN [--location ROLE=REGION]... [--dry-run]"
  [[ "$RUN" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || die "--run must match [a-z0-9-], at most 31 characters"
  check_topology
  if ! dry; then need aws jq; fi
  mkdir -p "$(run_dir)"
}

need() {
  local tool
  for tool in "$@"; do command -v "$tool" > /dev/null 2>&1 || die "$tool is required"; done
}
