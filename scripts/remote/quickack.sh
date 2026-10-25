#!/usr/bin/env bash
# Client-side TCP quickack towards the bench servers, for diagnostic runs only (load hosts, never servers).
#
#   quickack.sh on IP...   save "ip route show" once, then add an IP/32 route with "quickack 1" over the current path
#   quickack.sh off        delete the added routes and check that "ip route show" equals the saved copy; no output
#                          when nothing was applied
#   quickack.sh status     "on" or "off"
#
# State lives in $BENCH_QUICKACK_DIR (default /opt/bench/quickack): before, added, after.
set -euo pipefail

DIR="${BENCH_QUICKACK_DIR:-/opt/bench/quickack}"

die() { echo "quickack.sh: $*" >&2; exit 2; }

on() {
  local ip route dev via
  [ $# -gt 0 ] || die "on needs at least one IP"
  mkdir -p "$DIR"
  [ -f "$DIR/before" ] || ip route show > "$DIR/before"
  for ip in "$@"; do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "bad IP $ip"
    route=$(ip -o route get "$ip")
    dev=$(sed -n 's/.* dev \([^ ]*\).*/\1/p' <<< "$route")
    via=$(sed -n 's/.* via \([^ ]*\).*/\1/p' <<< "$route")
    [ -n "$dev" ] || die "no route to $ip"
    grep -qx "$ip" "$DIR/added" 2> /dev/null || echo "$ip" >> "$DIR/added"
    ip route replace "$ip/32" dev "$dev" ${via:+via "$via"} quickack 1
  done
  ip route show
}

off() {
  local ip
  [ -f "$DIR/before" ] || return 0
  if [ -f "$DIR/added" ]; then
    while read -r ip; do ip route del "$ip/32" 2> /dev/null || true; done < "$DIR/added"
  fi
  ip route show > "$DIR/after"
  if ! cmp -s "$DIR/before" "$DIR/after"; then
    diff "$DIR/before" "$DIR/after" >&2 || true
    die "routes differ from the saved copy in $DIR/before"
  fi
  rm -f "$DIR/before" "$DIR/added"
  cat "$DIR/after"
}

case "${1:-}" in
  on) shift; on "$@" ;;
  off) off ;;
  status) if [ -f "$DIR/before" ]; then echo on; else echo off; fi ;;
  *) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 2 ;;
esac
