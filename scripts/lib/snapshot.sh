# shellcheck shell=bash

SNAP_NAME=""
SNAP_RUN=""
SNAP_HOSTS=""
SNAP_AGAIN=0

snapshot_args() {
  [ $# -gt 0 ] || die "usage: ${0##*/} HOSTS.json --name NAME [--host HOST]... [--from-run RUN] [--again]"
  load_inventory "$1"; shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) SNAP_NAME="${2:?}"; shift 2 ;;
      --host) SNAP_HOSTS="$SNAP_HOSTS ${2:?}"; shift 2 ;;
      --from-run) SNAP_RUN="${2:?}"; shift 2 ;;
      --again) SNAP_AGAIN=1; shift ;;
      *) die "unknown option $1" ;;
    esac
  done
  [[ "$SNAP_NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "--name must match [a-z0-9-]"
  [ -n "${BENCH_BLOB_URL:-}" ] || die "BENCH_BLOB_URL is not set"
  [ -n "${BENCH_BLOB_SAS:-}" ] || die "BENCH_BLOB_SAS is not set"
  SNAP_RUN="${SNAP_RUN:-$RUN}"
  [ -n "$SNAP_HOSTS" ] || SNAP_HOSTS=$(server_hosts | tr '\n' ' ')
}

snapshot_host() {
  local host="$1" mode="$SNAP_MODE" dir sas_file rc=0
  dir="$STATE/snapshots/$SNAP_NAME"; mkdir -p "$dir"
  if [ "$SNAP_AGAIN" = 0 ] && [ -f "$dir/$host.$mode.done" ]; then say "$host: $mode $SNAP_NAME already done"; return 0; fi
  sas_file="$dir/.sas.$host"
  (umask 077; printf '%s' "${BENCH_BLOB_SAS#\?}" > "$sas_file")
  rsync_to "$host" "$sas_file" "/tmp/bench-sas-$SNAP_NAME"
  rm -f "$sas_file"
  job_run "$host" "snapshot-$mode-$SNAP_NAME" --sudo --again -- bash "$REMOTE/scripts/remote/snapshot.sh" "$mode" \
    "$SNAP_NAME" "${BENCH_BLOB_URL%/}/snapshots/$SNAP_RUN/$SNAP_NAME/$host" "/tmp/bench-sas-$SNAP_NAME" || rc=$?
  hssh "$host" "sudo -n rm -f /tmp/bench-sas-$SNAP_NAME" || true
  [ "$rc" = 0 ] || return "$rc"
  hssh "$host" "$JOB log snapshot-$mode-$SNAP_NAME 200" > "$dir/$host.$mode.log"
  date -u +%FT%TZ > "$dir/$host.$mode.done"
}
