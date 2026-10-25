#!/usr/bin/env bash
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/stage2.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/stage2.sh"
# shellcheck source=lib/pg.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/pg.sh"

require_root
require_var POSTGRES_MAJOR POSTGRES_PKG_VERSION BENCH_HOST
conf=$BENCH_ROOT/config/postgres
role=${BENCH_ROLE:-}
case $role in
postgres-primary | postgres-standby) ;;
*) die "postgres.sh runs on postgres-primary or postgres-standby hosts, not $role" ;;
esac
cd /

apt_install ca-certificates curl gnupg gettext-base
if [[ ! -s /usr/share/keyrings/pgdg.gpg ]]; then
	curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/pgdg.gpg
fi
repo="deb [signed-by=/usr/share/keyrings/pgdg.gpg] https://apt.postgresql.org/pub/repos/apt noble-pgdg main"
if [[ "$(cat /etc/apt/sources.list.d/pgdg.list 2>/dev/null)" != "$repo" ]]; then
	printf '%s\n' "$repo" >/etc/apt/sources.list.d/pgdg.list
	APT_UPDATED=0
fi
apt_install postgresql-common
sed -i 's/^#\? *create_main_cluster *=.*/create_main_cluster = false/' /etc/postgresql-common/createcluster.conf
apt_install "postgresql-$PG_MAJOR=$POSTGRES_PKG_VERSION" "postgresql-client-$PG_MAJOR=$POSTGRES_PKG_VERSION"
apt-mark hold "postgresql-$PG_MAJOR" "postgresql-client-$PG_MAJOR" >/dev/null

mem_mb=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)
maintenance_mb=$((mem_mb / 16))
((maintenance_mb > 2048)) && maintenance_mb=2048
export PG_SHARED_BUFFERS="$((mem_mb / 4))MB" PG_EFFECTIVE_CACHE="$((mem_mb * 3 / 4))MB"
export PG_MAINTENANCE_MEM="${maintenance_mb}MB" PG_CPUS
PG_CPUS=$(nproc)
sync_standby=$(first_host_of postgres-standby)
export PG_SYNC_NAMES=""
if [[ -n $sync_standby ]]; then
	PG_SYNC_NAMES="FIRST 1 (\"$sync_standby\")"
fi
stalwart_password=$(bench_secret pg-stalwart)
repl_password=$(bench_secret pg-replicator)

install -d -o postgres -g postgres -m 0700 "$BENCH_DATA/postgres" "$BENCH_DATA/postgres/$PG_MAJOR"
if [[ -d $PG_ETC && ! -s $PG_DATA/PG_VERSION && $role == postgres-primary ]]; then
	systemctl stop "$PG_UNIT" 2>/dev/null || true
	pg_dropcluster "$PG_MAJOR" "$PG_CLUSTER"
fi
if [[ ! -d $PG_ETC ]]; then
	pg_createcluster "$PG_MAJOR" "$PG_CLUSTER" -d "$PG_DATA" --start-conf auto >/dev/null
fi
grep -q "^include_dir = 'conf.d'" "$PG_ETC/postgresql.conf" || die "$PG_ETC/postgresql.conf does not include conf.d"

changed=0
install -d -o postgres -g postgres -m 0755 "$PG_ETC/conf.d"
if render "$conf/bench.conf" "$PG_ETC/conf.d/90-bench.conf" \
	'${PG_SHARED_BUFFERS} ${PG_EFFECTIVE_CACHE} ${PG_MAINTENANCE_MEM} ${PG_CPUS} ${PG_SYNC_NAMES}' 0644; then
	changed=1
fi
if install_file "$conf/pg_hba.conf" "$PG_ETC/pg_hba.conf" 0640; then
	changed=1
fi
chown -R postgres:postgres "$PG_ETC"

start_pg() {
	systemctl enable "$PG_UNIT" >/dev/null 2>&1
	if [[ $changed -eq 1 ]] || ! systemctl is-active --quiet "$PG_UNIT"; then
		systemctl restart "$PG_UNIT"
	fi
	wait_until 300 "PostgreSQL to accept connections" pg_is_up
}

if [[ $role == postgres-primary ]]; then
	rm -f "$PG_ETC/conf.d/91-standby.conf"
	[[ ! -e $PG_DATA/standby.signal ]] || die "$PG_DATA has standby.signal on the primary"
	chown -R postgres:postgres "$PG_DATA"
	chmod 0700 "$PG_DATA"
	start_pg
	export PGOPTIONS='-c synchronous_commit=local'
	pg_psql -d postgres <<-SQL
		SELECT format('CREATE ROLE %I LOGIN', '$PG_USER') WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$PG_USER')
		UNION ALL
		SELECT format('CREATE ROLE %I LOGIN REPLICATION', '$PG_REPL_USER') WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$PG_REPL_USER')
		\gexec
		ALTER ROLE $PG_USER PASSWORD '$stalwart_password';
		ALTER ROLE $PG_REPL_USER PASSWORD '$repl_password';
		SELECT format('CREATE DATABASE %I OWNER %I', '$PG_DB', '$PG_USER') WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$PG_DB')
		\gexec
	SQL
	unset PGOPTIONS
else
	primary=$(pg_primary_host)
	[[ -n $primary ]] || die "no postgres-primary host in $BENCH_ENV"
	export BENCH_HOST PG_PRIMARY_IP PG_REPL_PASSWORD=$repl_password
	PG_PRIMARY_IP=$(host_ip "$primary")
	repl_conn="host=$PG_PRIMARY_IP port=$PG_PORT user=$PG_REPL_USER dbname=replication replication=true"
	primary_sysid() {
		PGPASSWORD=$repl_password psql -X -At -c IDENTIFY_SYSTEM "$repl_conn" 2>/dev/null | cut -d'|' -f1
	}
	wait_until "$BENCH_DEP_TIMEOUT" "the primary $primary to accept replication logins" primary_sysid
	want=$(primary_sysid)
	have=""
	if [[ -s $PG_DATA/global/pg_control ]]; then
		have=$("$PG_BIN/pg_controldata" "$PG_DATA" | awk -F: '/^Database system identifier/ {gsub(/ /, "", $2); print $2}')
	fi
	if [[ $have != "$want" || ! -e $PG_DATA/standby.signal ]]; then
		log "cloning $primary (system id $want, local ${have:-none})"
		systemctl stop "$PG_UNIT" 2>/dev/null || true
		find "$PG_DATA" -mindepth 1 -delete 2>/dev/null || true
		install -d -o postgres -g postgres -m 0700 "$PG_DATA"
		runuser -u postgres -- env PGPASSWORD="$repl_password" "$PG_BIN/pg_basebackup" -h "$PG_PRIMARY_IP" -p "$PG_PORT" \
			-U "$PG_REPL_USER" -D "$PG_DATA" -X stream -c fast --no-password
		runuser -u postgres -- touch "$PG_DATA/standby.signal"
		changed=1
	fi
	if render "$conf/standby.conf" "$PG_ETC/conf.d/91-standby.conf" '${PG_PRIMARY_IP} ${PG_REPL_PASSWORD} ${BENCH_HOST}' 0640; then
		changed=1
	fi
	chown postgres:postgres "$PG_ETC/conf.d/91-standby.conf"
	start_pg
	wait_until 600 "WAL streaming from $primary" pg_streaming
fi

add_services "$PG_UNIT"
log "postgres $role ready: $("$PG_BIN/postgres" --version)"
