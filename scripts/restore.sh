#!/usr/bin/env bash
# Restore server hosts from a snapshot taken by scripts/snapshot.sh (data directories replaced, services restarted).
#
#   scripts/restore.sh HOSTS.json --name NAME [--host HOST]... [--from-run RUN] [--again]
#
# --from-run restores a snapshot of another run (for example after a redeploy); default: this run. Restored hosts
# are removed from work/RUN/wiped, which blocks the bench phase until every wiped host is restored.

# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
# shellcheck source=lib/snapshot.sh
. "$(dirname "$0")/lib/snapshot.sh"

snapshot_args "$@"
SNAP_MODE=load
# shellcheck disable=SC2086
on_hosts snapshot_host $SNAP_HOSTS
if [ -f "$STATE/wiped" ]; then
  for host in $SNAP_HOSTS; do grep -vx "$host" "$STATE/wiped" > "$STATE/wiped.tmp" || true; mv "$STATE/wiped.tmp" "$STATE/wiped"; done
fi
say "restored $SNAP_NAME on$SNAP_HOSTS"
