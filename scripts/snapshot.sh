#!/usr/bin/env bash
# Save the datasets of the server hosts to Azure Blob (RocksDB and mail directories as tar, PostgreSQL with
# pg_basebackup, FoundationDB with fdbbackup, S3 bucket contents), so a host event that wipes local NVMe costs a
# restore, not a re-seed. Services with "dir" datasets are stopped during the copy.
#
#   scripts/snapshot.sh HOSTS.json --name NAME [--host HOST]... [--again]
#
# Blobs: $BENCH_BLOB_URL/snapshots/RUN/NAME/HOST/N-KIND.tar.zst (+ .sha256). BENCH_BLOB_SAS holds the SAS token.
# Hosts already saved under NAME are skipped unless --again.

# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
# shellcheck source=lib/snapshot.sh
. "$(dirname "$0")/lib/snapshot.sh"

snapshot_args "$@"
SNAP_MODE=save
# shellcheck disable=SC2086
on_hosts snapshot_host $SNAP_HOSTS
say "snapshot $SNAP_NAME saved for$SNAP_HOSTS"
