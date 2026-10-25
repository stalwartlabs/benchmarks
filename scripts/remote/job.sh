#!/usr/bin/env bash
# Detached jobs on a VM, so no SSH session has to outlive Azure's ~4 minute idle cutoff.
#
#   job.sh start NAME [--sudo] [--again] -- CMD [ARGS...]   start CMD unless NAME is running or already succeeded
#                                                          (--again restarts a succeeded job); prints the status
#   job.sh status NAME                                     "running", "done RC" or "absent"
#   job.sh log NAME [LINES]                                tail of the job's output (default 40 lines)
#   job.sh stop NAME                                       kill the job's process group
#
# State lives in $BENCH_JOBS (default /opt/bench/jobs)/NAME: cmd, log, pid, rc.
set -euo pipefail

JOBS="${BENCH_JOBS:-/opt/bench/jobs}"

die() { echo "job.sh: $*" >&2; exit 2; }

status() {
  local dir="$JOBS/$1" pid
  if [ -f "$dir/rc" ]; then echo "done $(cat "$dir/rc")"; return; fi
  if [ -f "$dir/pid" ]; then
    pid=$(cat "$dir/pid")
    if kill -0 "$pid" 2> /dev/null; then echo running; return; fi
    echo "done 255"; return
  fi
  echo absent
}

start() {
  local name="$1" sudo="" again=0 dir state
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --sudo) sudo="sudo -n"; shift ;;
      --again) again=1; shift ;;
      --) shift; break ;;
      *) die "unknown option $1" ;;
    esac
  done
  [ $# -gt 0 ] || die "start needs a command after --"
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "bad job name $name"
  dir="$JOBS/$name"
  state=$(status "$name")
  case "$state" in
    running) echo running; return ;;
    "done 0") if [ "$again" = 0 ]; then echo "done 0"; return; fi ;;
  esac
  mkdir -p "$dir"
  rm -f "$dir/rc" "$dir/pid"
  printf '%q ' "$@" > "$dir/cmd"
  # shellcheck disable=SC2086
  setsid nohup bash -c 'cd /; '"$sudo"' "$@" > "$0/log" 2>&1 < /dev/null; echo $? > "$0/rc.tmp"; mv "$0/rc.tmp" "$0/rc"' \
    "$dir" "$@" > /dev/null 2>&1 < /dev/null &
  echo $! > "$dir/pid"
  echo running
}

case "${1:-}" in
  start) [ $# -ge 2 ] || die "usage: job.sh start NAME [--sudo] [--again] -- CMD..."; shift; start "$@" ;;
  status) [ $# -eq 2 ] || die "usage: job.sh status NAME"; status "$2" ;;
  log) [ $# -ge 2 ] || die "usage: job.sh log NAME [LINES]"; tail -n "${3:-40}" "$JOBS/$2/log" 2> /dev/null || true ;;
  stop)
    [ $# -eq 2 ] || die "usage: job.sh stop NAME"
    if [ -f "$JOBS/$2/pid" ]; then kill -- "-$(cat "$JOBS/$2/pid")" 2> /dev/null || kill "$(cat "$JOBS/$2/pid")" 2> /dev/null || true; fi ;;
  *) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 2 ;;
esac
