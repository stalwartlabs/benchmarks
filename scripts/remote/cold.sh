#!/usr/bin/env bash
# Cold-cache cycle on a server host (run as root): stop the services under test, flush and drop the page cache,
# start them again and wait until they answer. Identical on every server host.
set -euo pipefail
CTL=/opt/bench/provision/ctl.sh
bash "$CTL" stop
sync
echo 3 > /proc/sys/vm/drop_caches
bash "$CTL" start
for _ in $(seq 1 120); do
  if bash "$CTL" ready; then echo "cold: ready"; exit 0; fi
  sleep 2
done
echo "cold: services not ready after 240 s" >&2
exit 1
