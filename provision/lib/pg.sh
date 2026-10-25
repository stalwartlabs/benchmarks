#!/usr/bin/env bash
# shellcheck disable=SC2034

PG_MAJOR=${POSTGRES_MAJOR:-18}
PG_CLUSTER=main
PG_DATA=${BENCH_DATA}/postgres/${PG_MAJOR}/${PG_CLUSTER}
PG_ETC=/etc/postgresql/${PG_MAJOR}/${PG_CLUSTER}
PG_BIN=/usr/lib/postgresql/${PG_MAJOR}/bin
PG_UNIT=postgresql@${PG_MAJOR}-${PG_CLUSTER}.service
PG_PORT=5432
PG_DB=stalwart
PG_USER=stalwart
PG_REPL_USER=replicator
PG_LAG_BYTES=1048576

pg_psql() {
	runuser -u postgres -- psql -X -q -v ON_ERROR_STOP=1 -p "$PG_PORT" "$@"
}

pg_primary_host() {
	first_host_of postgres-primary
}

pg_is_up() {
	runuser -u postgres -- "$PG_BIN/pg_isready" -q -p "$PG_PORT"
}

pg_lagging_standbys() {
	pg_psql -At -c "SELECT count(*) FROM pg_stat_replication WHERE replay_lsn IS NULL OR pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) > $PG_LAG_BYTES"
}

pg_streaming() {
	[[ "$(pg_psql -At -c "SELECT count(*) FROM pg_stat_wal_receiver WHERE status = 'streaming'")" == 1 ]]
}
