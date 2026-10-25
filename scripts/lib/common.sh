# shellcheck shell=bash

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BENCH_WORK="${BENCH_WORK:-$REPO/work}"
BENCH_RESULTS="${BENCH_RESULTS:-$REPO/results}"
BENCH_POLL="${BENCH_POLL:-15}"
REMOTE=/opt/bench
JOB="$REMOTE/scripts/remote/job.sh"

die() { echo "${0##*/}: $*" >&2; exit 1; }
say() { echo "[$(date -u +%H:%M:%S)] ${0##*/}: $*" >&2; }

load_inventory() {
  mkdir -p "$HOME/.ssh"
  HOSTS="${1:?inventory (hosts.json) required}"
  [ -f "$HOSTS" ] || die "inventory $HOSTS not found"
  HOSTS="$(cd "$(dirname "$HOSTS")" && pwd)/$(basename "$HOSTS")"
  jq -e '.run and .track and (.hosts | length > 0)' "$HOSTS" > /dev/null || die "$HOSTS is not an inventory"
  RUN=$(jq -r .run "$HOSTS"); TRACK=$(jq -r .track "$HOSTS")
  SSH_USER=$(jq -r '.ssh.user // "bench"' "$HOSTS")
  SSH_KEY=$(jq -r '.ssh.key // empty' "$HOSTS")
  KNOWN_HOSTS=$(jq -r '.ssh.known_hosts // empty' "$HOSTS")
  KNOWN_HOSTS="${KNOWN_HOSTS:-$BENCH_WORK/$RUN/known_hosts}"
  STATE="$BENCH_WORK/$RUN"
  OUT="${BENCH_OUT:-$BENCH_RESULTS/$TRACK/$RUN}"
  mkdir -p "$STATE" "$OUT"
}

inv() { jq -r "$@" "$HOSTS"; }

host_names() {
  if [ -n "${1:-}" ]; then inv --arg r "$1" '.hosts[] | select(.role == $r) | .name'; else inv '.hosts[].name'; fi
}

server_hosts() { inv '.hosts[] | select(.role != "load" and .role != "sink") | .name'; }

host_field() { inv --arg n "$1" --arg f "$2" '.hosts[] | select(.name == $n) | .[$f] // empty'; }

host_ip() { host_field "$1" private_ip; }

load_hosts() { host_names load; }

first_load() { load_hosts | head -1; }

target_host() {
  local t
  t=$(inv --arg t "$1" '.targets[$t] // empty')
  [ -n "$t" ] || die "target $1 is not in the inventory's targets"
  echo "$t"
}

ssh_opts() {
  SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=4
    -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$KNOWN_HOSTS" -o LogLevel=ERROR
    -o ControlMaster=auto -o "ControlPath=$HOME/.ssh/cm-bench-%C" -o ControlPersist=120)
  if [ -n "$SSH_KEY" ]; then SSH_OPTS+=(-i "$SSH_KEY"); fi
}

hssh() {
  local name="$1" addr attempt rc
  shift
  addr="$SSH_USER@$(host_field "$name" public_ip)"
  ssh_opts
  for attempt in 1 2 3; do
    rc=0
    # shellcheck disable=SC2029
    ssh "${SSH_OPTS[@]}" "$addr" "$@" || rc=$?
    [ "$rc" = 255 ] || return "$rc"
    say "$name: ssh failed (attempt $attempt)"
    sleep $((attempt * 5))
  done
  return 255
}

rsync_to() {
  local name="$1" src="$2" dest="$3"
  shift 3
  ssh_opts
  rsync -az "$@" -e "ssh $(printf '%q ' "${SSH_OPTS[@]}")" "$src" "$SSH_USER@$(host_field "$name" public_ip):$dest"
}

rsync_from() {
  local name="$1" src="$2" dest="$3"
  shift 3
  ssh_opts
  rsync -az "$@" -e "ssh $(printf '%q ' "${SSH_OPTS[@]}")" "$SSH_USER@$(host_field "$name" public_ip):$src" "$dest"
}

quote() { if [ $# -gt 0 ]; then printf '%q ' "$@"; fi; }

job_run() {
  local host="$1" name="$2" opts=() timeout="${BENCH_JOB_TIMEOUT:-86400}" start status delay=1
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --sudo|--again) opts+=("$1"); shift ;;
      --timeout) timeout="$2"; shift 2 ;;
      --) shift; break ;;
      *) die "job_run: unknown option $1" ;;
    esac
  done
  start=$(date +%s)
  status=$(hssh "$host" "$JOB start $(quote "$name") $(quote ${opts[@]+"${opts[@]}"}) -- $(quote "$@")")
  while [ "$status" = running ]; do
    if [ $(($(date +%s) - start)) -gt "$timeout" ]; then
      hssh "$host" "$JOB stop $(quote "$name")" || true
      say "$host: job $name timed out after ${timeout}s"
      return 124
    fi
    sleep "$delay"
    delay=$((delay * 2)); [ "$delay" -le "$BENCH_POLL" ] || delay="$BENCH_POLL"
    status=$(hssh "$host" "$JOB status $(quote "$name")" || echo running)
  done
  case "$status" in
    "done 0") return 0 ;;
    "done "*)
      say "$host: job $name failed ($status); last lines:"
      hssh "$host" "$JOB log $(quote "$name") 30" >&2 || true
      return "${status#done }" ;;
    *) say "$host: job $name: unexpected status '$status'"; return 1 ;;
  esac
}

on_hosts() {
  local fn="$1" host pids=() hosts=() failed="" i=0 pid
  shift
  for host in "$@"; do "$fn" "$host" & pids+=($!); hosts+=("$host"); done
  for pid in ${pids[@]+"${pids[@]}"}; do
    wait "$pid" || failed="$failed ${hosts[$i]}"
    i=$((i + 1))
  done
  [ -z "$failed" ] || { say "$fn failed on:$failed"; return 1; }
}

phase_done() { [ -f "$STATE/phases/$1.done" ]; }

mark_done() { mkdir -p "$STATE/phases"; date -u +%FT%TZ > "$STATE/phases/$1.done"; }

ctl() {
  local host="$1"
  shift
  hssh "$host" "sudo -n bash $REMOTE/provision/ctl.sh $(quote "$@")"
}
