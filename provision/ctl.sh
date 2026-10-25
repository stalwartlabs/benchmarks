#!/usr/bin/env bash
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/stalwart.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/stalwart.sh"
# shellcheck source=lib/postfix.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/postfix.sh"
# shellcheck source=lib/stage2.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/stage2.sh"
# shellcheck source=lib/pg.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/pg.sh"
# shellcheck source=lib/redis.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/redis.sh"
# shellcheck source=lib/fdb.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/fdb.sh"
# shellcheck source=lib/garage.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/garage.sh"
# shellcheck source=lib/ceph.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/ceph.sh"
# shellcheck source=lib/production.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/production.sh"

require_root
cd /
role=${BENCH_ROLE:-}
[[ -n $role ]] || die "BENCH_ROLE not set in $BENCH_ENV"

usage() {
	echo "usage: $0 ready|drain [TIMEOUT_S]|settle|accounts FILE|stop|start|variant NAME|versions|config-dump DIR|datadirs|bucket-copy|fdb-clear" >&2
	exit 2
}

services() {
	if [[ -s $BENCH_SERVICES_FILE ]]; then
		grep -v '^$' "$BENCH_SERVICES_FILE"
	fi
}

services_active() {
	local unit
	while read -r unit; do
		systemctl is-active --quiet "$unit" || return 1
	done < <(services)
}

is_ready() {
	services_active || return 1
	case $role in
	stalwart)
		all_ports_open "${STALWART_PORTS[@]}" && curl -fsk -o /dev/null https://127.0.0.1:443/healthz/ready
		;;
	postfix-dovecot)
		all_ports_open "${POSTFIX_PORTS[@]}" "${DOVECOT_PORTS[@]}" &&
			[[ -S $POSTFIX_QUEUE/private/dovecot-lmtp && -S $POSTFIX_QUEUE/private/auth ]]
		;;
	sink)
		all_ports_open 25 53
		;;
	postgres-primary | postgres-standby)
		pg_is_up
		;;
	redis)
		redis_pong
		;;
	fdb)
		all_ports_open "$FDB_PORT" && fdb_available
		;;
	garage)
		all_ports_open "$GARAGE_S3_PORT" "$GARAGE_RPC_PORT" "$GARAGE_ADMIN_PORT"
		;;
	ceph)
		all_ports_open "$CEPH_RGW_PORT"
		;;
	*)
		return 0
		;;
	esac
}

pending_work() {
	case $role in
	stalwart)
		local queued indexed
		queued=$(stalwart_cli query QueuedMessage --json --fields id | jq -s 'length')
		indexed=$(stalwart_cli query IndexQueueStatus --json --fields queuedUpdates,queuedDeletions |
			jq -s 'map((.queuedUpdates // 0) + (.queuedDeletions // 0)) | add // 0')
		echo $((queued + indexed))
		;;
	postfix-dovecot)
		local queued indexer
		queued=$(postqueue -j | grep -c . || true)
		indexer=$(doveadm indexer list | tail -n +2 | grep -c . || true)
		echo $((queued + indexer))
		;;
	postgres-primary)
		pg_lagging_standbys
		;;
	fdb)
		[[ $BENCH_HOST == "$(first_host_of fdb)" && "$(fdb_moving_bytes)" != 0 ]] && echo 1 || echo 0
		;;
	*)
		echo 0
		;;
	esac
}

do_drain() {
	local timeout=${1:-1800} deadline n
	deadline=$((SECONDS + timeout))
	while true; do
		n=$(pending_work)
		[[ $n -eq 0 ]] && return 0
		if ((SECONDS >= deadline)); then
			log "drain timed out with $n items pending"
			return 1
		fi
		sleep 2
	done
}

do_settle() {
	case $role in
	postfix-dovecot)
		doveadm fts rescan -A
		doveadm index -A '*'
		doveadm fts optimize -A
		;;
	postgres-primary)
		runuser -u postgres -- "$PG_BIN/vacuumdb" -p "$PG_PORT" --all --analyze --jobs "$(nproc)" --quiet
		pg_psql -c CHECKPOINT
		;;
	esac
	do_drain "${1:-7200}"
}

accounts_dovecot() {
	local file=$1 users vmap
	users=$(mktemp "$DOVECOT_USERS.XXXXXX")
	vmap=$(mktemp "$POSTFIX_MAPS/vmailbox.XXXXXX")
	awk -F'\t' -v users="$users" -v vmap="$vmap" -v domain="$BENCH_DOMAIN" '
		NF >= 3 && $1 !~ /^#/ {
			addr = ($1 ~ /@/) ? $1 : $1 "@" domain
			printf "%s:{SHA512-CRYPT}%s::::::\n", addr, $3 > users
			printf "%s OK\n", addr > vmap
		}' "$file"
	chgrp dovecot "$users"
	chmod 0640 "$users"
	chmod 0644 "$vmap"
	mv -f "$users" "$DOVECOT_USERS"
	mv -f "$vmap" "$POSTFIX_MAPS/vmailbox"
	postmap "hash:$POSTFIX_MAPS/vmailbox"
	doveadm reload
	doveadm auth cache flush >/dev/null 2>&1 || true
	local last deadline=$((SECONDS + 30))
	last=$(awk -F: 'END {print $1}' "$DOVECOT_USERS")
	if [[ -n $last ]]; then
		until doveadm user "$last" >/dev/null 2>&1; do
			((SECONDS < deadline)) || die "dovecot does not resolve $last after reload"
			sleep 1
		done
	fi
	log "dovecot/postfix: $(grep -c . "$DOVECOT_USERS") accounts"
}

accounts_stalwart() {
	local file=$1 plan
	plan=$(mktemp)
	{
		jq -cn --arg d "$BENCH_DOMAIN" '{"@type":"upsert","object":"Domain","matchOn":["name"],"value":{"dom":{"name":$d}}}'
		jq -R -c -s --arg d "$BENCH_DOMAIN" '
			split("\n") | map(select(length > 0 and (startswith("#") | not)) | split("\t")) |
			map(select(length >= 3)) | to_entries |
			{"@type":"upsert","object":"Account","matchOn":["name"],
			 "value": (map({key: ("u" + (.key | tostring)),
			                value: {"@type":"User", "name": (.value[0] | split("@")[0]), "domainId":"#dom",
			                        "credentials": {"0": {"@type":"Password","secret": .value[2]}}}}) | from_entries)}' "$file"
	} >"$plan"
	stalwart_cli apply --quiet --file "$plan"
	rm -f "$plan"
	log "stalwart: $(grep -c . "$file") accounts upserted"
}

do_accounts() {
	local file=${1:-}
	[[ -r $file ]] || die "accounts file $file not readable"
	if awk -F'\t' 'NF >= 4 && $4 != "" && $4 != 0 {found=1} END {exit !found}' "$file"; then
		log "WARNING: non-zero quotas in $file are ignored (no quota enforcement in this profile)"
	fi
	case $role in
	stalwart) accounts_stalwart "$file" ;;
	postfix-dovecot) accounts_dovecot "$file" ;;
	*) log "accounts: nothing to do on role $role" ;;
	esac
}

do_stop() {
	local unit
	while read -r unit; do
		systemctl stop "$unit"
	done < <(services | tac)
}

do_start() {
	local unit deadline
	if [[ $role == postgres-primary && -d $PG_DATA ]]; then
		chown -R postgres:postgres "$PG_DATA"
		chmod 0700 "$PG_DATA"
	fi
	while read -r unit; do
		systemctl start "$unit"
	done < <(services)
	deadline=$((SECONDS + 300))
	until is_ready; do
		((SECONDS < deadline)) || die "services not ready after start"
		sleep 1
	done
	if [[ $role == redis && "$(redis_role)" == master ]]; then
		redis_cli FLUSHALL >/dev/null
	fi
}

do_variant() {
	local name=${1:-}
	case "$role:$name" in
	postfix-dovecot:default)
		: >"$DOVECOT_VARIANT"
		;;
	postfix-dovecot:fsync-always)
		printf 'mail_fsync = always\n' >"$DOVECOT_VARIANT"
		;;
	*:default)
		return 0
		;;
	*)
		die "unknown variant '$name' for role $role"
		;;
	esac
	doveconf -n >/dev/null
	systemctl restart dovecot.service
	do_start
	log "variant $name active: mail_fsync = $(doveconf -h mail_fsync)"
}

do_versions() {
	local args=(--arg kernel "$(uname -r)" --arg os "$(awk -F= '/^PRETTY_NAME=/{gsub(/"/, "", $2); print $2}' /etc/os-release)"
		--arg cpu "$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//')"
		--arg openssl "$(openssl version | awk '{print $2}')")
	local filter='{kernel: $kernel, os: $os, cpu: $cpu, openssl: $openssl}'
	case $role in
	stalwart)
		args+=(--arg stalwart "$("$STALWART_BIN" --version 2>/dev/null | head -n 1)"
			--arg sha "$(sha256sum "$STALWART_BIN" | cut -d' ' -f1)"
			--arg cli "$("$STALWART_CLI" --version | awk '{print $2}')")
		filter+=' + {stalwart: $stalwart, stalwart_sha256: $sha, stalwart_cli: $cli}'
		;;
	postfix-dovecot)
		args+=(--arg postfix "$(postconf -h mail_version)" --arg dovecot "$(dovecot --version)")
		filter+=' + {postfix: $postfix, dovecot: $dovecot}'
		;;
	sink)
		args+=(--arg unbound "$(unbound -V | awk '/^Version/{print $2}')"
			--arg rbldnsd "$(dpkg-query -W -f='${Version}' rbldnsd)"
			--arg mailbench "$("$BENCH_ROOT/bin/mailbench" --version 2>/dev/null || true)")
		filter+=' + {unbound: $unbound, rbldnsd: $rbldnsd, mailbench: $mailbench}'
		;;
	load)
		args+=(--arg mailbench "$("$BENCH_ROOT/bin/mailbench" --version 2>/dev/null || true)"
			--arg imaptest "$(sha256sum "$BENCH_ROOT/bin/imaptest" | cut -d' ' -f1)")
		filter+=' + {mailbench: $mailbench, imaptest_sha256: $imaptest}'
		;;
	postgres-primary | postgres-standby)
		args+=(--arg postgres "$("$PG_BIN/postgres" --version | awk '{print $3}')")
		filter+=' + {postgres: $postgres}'
		;;
	redis)
		args+=(--arg redis "$(redis-server --version | awk '{print $3}' | cut -d= -f2)")
		filter+=' + {redis: $redis}'
		;;
	fdb)
		args+=(--arg fdb "$(fdbserver --version | head -n 1)")
		filter+=' + {foundationdb: $fdb}'
		;;
	garage)
		args+=(--arg garage "$("$GARAGE_BIN" --version | head -n 1)")
		filter+=' + {garage: $garage}'
		;;
	ceph)
		args+=(--arg ceph "$(podman ps --format '{{.Image}}' | sort -u | paste -sd' ')")
		filter+=' + {ceph_images: $ceph}'
		;;
	esac
	if [[ $role == stalwart ]] && command -v redis-sentinel >/dev/null; then
		args+=(--arg sentinel "$(redis-sentinel --version | awk '{print $3}' | cut -d= -f2)")
		filter+=' + {redis_sentinel: $sentinel}'
	fi
	if [[ $role == stalwart ]] && command -v fdbcli >/dev/null; then
		args+=(--arg fdbcli "$(fdbcli --version | head -n 1)")
		filter+=' + {fdb_client: $fdbcli}'
	fi
	jq -cn "${args[@]}" "$filter"
}

STALWART_SNAPSHOT_TYPES=(Domain Certificate SystemSettings NetworkListener MtaInboundThrottle MtaOutboundThrottle
	MtaQueueQuota MtaTlsStrategy MtaRoute MtaVirtualQueue MtaConnectionStrategy MtaDeliverySchedule Tracer
	AllowedIp DataStore BlobStore SearchStore InMemoryStore TracingStore MetricsStore Metrics Asn Cache Search
	SpamSettings SenderAuth MtaStageConnect MtaStageEhlo MtaStageMail MtaStageRcpt MtaStageData MtaStageAuth
	MtaInboundSession MtaExtensions MtaOutboundStrategy Security Imap Jmap Http Email CalendarScheduling
	DataRetention DnsResolver Coordinator Enterprise)

do_config_dump() {
	local dir=${1:-}
	[[ -n $dir ]] || usage
	mkdir -p "$dir"
	cp -f /etc/sysctl.d/90-bench.conf "$dir/" 2>/dev/null || true
	{
		echo "kernel $(uname -r)"
		echo "thp $(cat /sys/kernel/mm/transparent_hugepage/enabled)"
		for dev in /sys/block/nvme*n*; do
			[[ -e $dev ]] && echo "scheduler ${dev##*/} $(cat "$dev/queue/scheduler")"
		done
		ethtool -g "$(ip -o route get 1.1.1.1 | awk '{for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1)}')" 2>/dev/null || true
		mount | grep " $BENCH_DATA " || true
	} >"$dir/host.txt"
	case $role in
	stalwart)
		cp -f "$STALWART_ETC/config.json" "$dir/config.json"
		sed -E 's/\$6\$[^"]*/<sha512-crypt hash>/g' "$STALWART_ETC/plan.ndjson" >"$dir/plan.ndjson"
		stalwart_cli snapshot --quiet --allow-unresolved Role,DnsServer,AcmeProvider,Directory,Tenant,Account \
			"${STALWART_SNAPSHOT_TYPES[@]}" >"$dir/snapshot.ndjson"
		if [[ -f $STALWART_ENV_FILE ]]; then
			sed -E 's/=.*/=<set>/' "$STALWART_ENV_FILE" >"$dir/stalwart.env"
		fi
		if [[ -f $SENTINEL_CONF ]]; then
			sed -E 's/^(sentinel auth-pass [^ ]+ ).*/\1<secret>/' "$SENTINEL_CONF" >"$dir/sentinel.conf"
		fi
		[[ ! -f $FDB_CLUSTER_FILE ]] || cp -f "$FDB_CLUSTER_FILE" "$dir/fdb.cluster"
		;;
	postgres-primary | postgres-standby)
		cp -f "$PG_ETC/conf.d/90-bench.conf" "$PG_ETC/pg_hba.conf" "$dir/"
		pg_psql -At -c "SELECT name, setting, unit, source FROM pg_settings WHERE source NOT IN ('default', 'override')" >"$dir/pg_settings.txt"
		;;
	redis)
		sed -E 's/^((requirepass|masterauth) ).*/\1<secret>/' "$REDIS_CONF" >"$dir/redis.conf"
		if [[ -f $SENTINEL_CONF ]]; then
			sed -E 's/^(sentinel auth-pass [^ ]+ ).*/\1<secret>/' "$SENTINEL_CONF" >"$dir/sentinel.conf"
		fi
		;;
	fdb)
		cp -f "$FDB_ETC/foundationdb.conf" "$FDB_CLUSTER_FILE" "$dir/"
		fdb_status | jq '.cluster.configuration' >"$dir/fdb-configuration.json"
		;;
	garage)
		sed -E 's/^((rpc_secret|admin_token) = ).*/\1"<secret>"/' "$GARAGE_CONF" >"$dir/garage.toml"
		garage_cli json-api GetClusterLayout >"$dir/garage-layout.json" 2>/dev/null || true
		;;
	ceph)
		if [[ $BENCH_HOST == "$(first_host_of ceph)" ]]; then
			ceph_cmd ceph config dump >"$dir/ceph-config.txt"
			ceph_cmd ceph osd pool ls detail >"$dir/ceph-pools.txt"
			ceph_cmd ceph orch ls >"$dir/ceph-services.txt"
		fi
		;;
	postfix-dovecot)
		postconf -n >"$dir/postconf-n.txt"
		postconf -M >"$dir/postconf-M.txt"
		cp -f /etc/postfix/main.cf /etc/postfix/master.cf /etc/postfix/openssl.cnf "$dir/"
		doveconf -n >"$dir/doveconf-n.txt"
		cp -f "$DOVECOT_VARIANT" "$dir/dovecot-variant.conf"
		;;
	sink)
		cp -f /etc/unbound/unbound.conf.d/bench.conf /etc/unbound/bench-zones.conf /etc/unbound/bench-dnsbl.conf "$dir/"
		;;
	esac
}

do_datadirs() {
	case $role in
	stalwart)
		if [[ $BENCH_PROFILE != production || $(prod_backend) == rocksdb ]]; then
			echo "dir $STALWART_DATA"
		fi
		;;
	postgres-primary) echo "pg $PG_DATA" ;;
	fdb)
		[[ $BENCH_HOST != "$(first_host_of fdb)" ]] || echo "fdb $FDB_BACKUP_DIR"
		;;
	garage | ceph)
		if [[ $BENCH_HOST == "$(first_host_of "$role")" && $BENCH_S3_CLUSTER == "$role" ]]; then
			echo "bucket $BENCH_S3_BUCKET"
		fi
		;;
	postfix-dovecot)
		echo "dir $DOVECOT_DATA"
		echo "dir $BENCH_DATA/postfix"
		;;
	esac
}

do_bucket_copy() {
	[[ $role == ceph && $BENCH_HOST == "$(first_host_of ceph)" ]] || die "bucket-copy runs on the first ceph host"
	grep -q '^\[garage\]' /etc/bench/rclone.conf || die "no garage remote in /etc/bench/rclone.conf (BENCH_LB_S3_GARAGE unset at provisioning)"
	rclone --config /etc/bench/rclone.conf copy "garage:$BENCH_S3_BUCKET" "src:$BENCH_S3_BUCKET" \
		--fast-list --transfers 64 --checkers 64 --stats 60s --stats-one-line
	rclone --config /etc/bench/rclone.conf check "garage:$BENCH_S3_BUCKET" "src:$BENCH_S3_BUCKET" --size-only --one-way
}

do_fdb_clear() {
	[[ $role == fdb && $BENCH_HOST == "$(first_host_of fdb)" ]] || die "fdb-clear runs on the first fdb host"
	fdbcli -C "$FDB_CLUSTER_FILE" --exec 'writemode on; clearrange "" \xff' --timeout 600
}

action=${1:-}
[[ $# -gt 0 ]] && shift
case $action in
ready) is_ready ;;
drain) do_drain "${1:-1800}" ;;
settle) do_settle "${1:-7200}" ;;
accounts) do_accounts "${1:-}" ;;
stop) do_stop ;;
start) do_start ;;
variant) do_variant "${1:-}" ;;
versions) do_versions ;;
config-dump) do_config_dump "${1:-}" ;;
datadirs) do_datadirs ;;
bucket-copy) do_bucket_copy ;;
fdb-clear) do_fdb_clear ;;
*) usage ;;
esac
