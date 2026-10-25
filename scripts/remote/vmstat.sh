#!/usr/bin/env bash
# Record vmstat (1 s, with timestamps) during a measurement window.
#   vmstat.sh start KEY   |   vmstat.sh stop KEY      output: /opt/bench/out/vmstat/KEY.log
set -euo pipefail
dir=/opt/bench/out/vmstat
key="${2:?usage: vmstat.sh start|stop KEY}"
case "$1" in
  start)
    mkdir -p "$dir"
    [ -f "$dir/$key.pid" ] && kill "$(cat "$dir/$key.pid")" 2> /dev/null || true
    setsid nohup vmstat -n -t 1 > "$dir/$key.log" 2>&1 < /dev/null &
    echo $! > "$dir/$key.pid" ;;
  stop)
    [ -f "$dir/$key.pid" ] && { kill "$(cat "$dir/$key.pid")" 2> /dev/null || true; rm -f "$dir/$key.pid"; }
    true ;;
  *) echo "usage: vmstat.sh start|stop KEY" >&2; exit 2 ;;
esac
