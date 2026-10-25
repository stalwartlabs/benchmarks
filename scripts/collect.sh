#!/usr/bin/env bash
# Gather everything a result needs besides the per-cell files (which run-track.sh pulls as each cell ends):
# component versions, effective configs, host facts, the Stalwart binary checksum and a sanitized inventory, into
# results/TRACK/RUN/. Also copies each load host's raw output tree to work/RUN/remote-out/ as a safety net.
#
#   scripts/collect.sh HOSTS.json

# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

collect_host() {
  local host="$1" role
  role=$(host_field "$host" role)
  mkdir -p "$OUT/hosts" "$OUT/versions" "$OUT/configs/$host"
  hssh "$host" "bash $REMOTE/scripts/remote/hostinfo.sh" > "$OUT/hosts/$host.json"
  if [ "$role" = load ]; then
    hssh "$host" "$REMOTE/bin/mailbench --version" | jq -Rn '{mailbench: input}' > "$OUT/versions/$host.json"
    mkdir -p "$STATE/remote-out/$host"
    rsync_from "$host" "$REMOTE/out/" "$STATE/remote-out/$host/" || say "$host: could not copy $REMOTE/out"
    return 0
  fi
  ctl "$host" versions > "$OUT/versions/$host.json.tmp" && mv "$OUT/versions/$host.json.tmp" "$OUT/versions/$host.json"
  hssh "$host" "sudo -n rm -rf /tmp/bench-config && sudo -n mkdir -p /tmp/bench-config && sudo -n bash $REMOTE/provision/ctl.sh config-dump /tmp/bench-config && sudo -n chown -R $SSH_USER: /tmp/bench-config"
  rsync_from "$host" /tmp/bench-config/ "$OUT/configs/$host/" --delete
}

main() {
  local host
  [ $# -eq 1 ] || { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 2; }
  load_inventory "$1"
  # shellcheck disable=SC2046
  on_hosts collect_host $(host_names)
  jq 'del(.ssh) | .hosts |= map(del(.public_ip))' "$HOSTS" > "$OUT/hosts.json"
  for host in $(host_names); do
    jq -c --arg h "$host" '{($h): .}' "$OUT/versions/$host.json"
  done | jq -s 'add' > "$OUT/versions.json"
  if [ -f "$STATE/stalwart.sha256" ]; then
    jq --arg sha "$(awk '{print $2; exit}' "$STATE/stalwart.sha256")" \
      --arg src "${STALWART_BINARY_URL:+url}${STALWART_BINARY:+path}" '. + {stalwart_binary: {sha256: $sha, source: $src}}' \
      "$OUT/versions.json" > "$OUT/versions.json.tmp" && mv "$OUT/versions.json.tmp" "$OUT/versions.json"
  fi
  say "collected into $OUT"
}

main "$@"
