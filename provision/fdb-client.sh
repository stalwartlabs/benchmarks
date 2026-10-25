#!/usr/bin/env bash
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/stage2.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/stage2.sh"
# shellcheck source=lib/fdb.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/fdb.sh"

require_root
cd /
apt_install jq
fdb_write_cluster_file || true
fdb_install_clients
wait_until "$BENCH_DEP_TIMEOUT" "the FDB database to be available and healthy" fdb_healthy
log "fdb client ready on ${BENCH_HOST:-$(hostname)}: $(cat "$FDB_CLUSTER_FILE")"
