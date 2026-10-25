#!/usr/bin/env bash
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/stage2.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/stage2.sh"
# shellcheck source=lib/fdb.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/fdb.sh"

require_root
require_var BENCH_HOST
cd /
first=$(first_host_of fdb)
classes_var="BENCH_FDB_CLASSES_$(env_key "$BENCH_HOST")"
classes=${!classes_var:-${BENCH_FDB_CLASSES:-$FDB_DEFAULT_CLASSES}}
read -r -a class_list <<<"$classes"
nprocs=${#class_list[@]}
((nprocs > 0)) || die "no fdbserver processes configured ($classes_var / BENCH_FDB_CLASSES)"

apt_install jq gettext-base
if ! id foundationdb >/dev/null 2>&1; then
	adduser --system --group --no-create-home --home /var/lib/foundationdb foundationdb >/dev/null
fi
install -d -o foundationdb -g foundationdb -m 0755 "$FDB_DATA" /var/log/foundationdb /var/lib/foundationdb

changed=0
if fdb_write_cluster_file; then
	changed=1
fi
chown foundationdb:foundationdb "$FDB_ETC" "$FDB_CLUSTER_FILE"

export FDB_DATA BENCH_HOST FDB_MEMORY
FDB_MEMORY="$(awk -v n="$nprocs" '/^MemTotal:/ {print int($2 * 0.9 / 1024 / n)}' /proc/meminfo)MiB"
conf=$(mktemp)
envsubst '${FDB_DATA} ${BENCH_HOST} ${FDB_MEMORY}' <"$BENCH_ROOT/config/fdb/foundationdb.conf" >"$conf"
port=$FDB_PORT
for class in "${class_list[@]}"; do
	printf '\n[fdbserver.%s]\nclass = %s\n' "$port" "$class" >>"$conf"
	port=$((port + 1))
done
if [[ $BENCH_HOST == "$first" ]]; then
	printf '\n[backup_agent]\ncommand = /usr/lib/foundationdb/backup_agent/backup_agent\nlogdir = /var/log/foundationdb\n\n[backup_agent.1]\n' >>"$conf"
fi
if install_file "$conf" "$FDB_ETC/foundationdb.conf"; then
	changed=1
fi
rm -f "$conf"

fdb_install_clients
if ! fdb_installed server; then
	dpkg -i --force-confold "$(fdb_deb server)" >/dev/null
	changed=1
fi
chown foundationdb:foundationdb "$FDB_CLUSTER_FILE"
systemctl enable "$FDB_UNIT" >/dev/null 2>&1 || true
if [[ $changed -eq 1 ]] || ! systemctl is-active --quiet "$FDB_UNIT"; then
	systemctl restart "$FDB_UNIT"
fi
wait_ports 120 "$FDB_PORT"

if [[ $BENCH_HOST == "$first" ]]; then
	coordinators_up() {
		local host
		while read -r host; do
			tcp_open "$(host_ip "$host")" "$FDB_PORT" || return 1
		done < <(fdb_coordinators)
	}
	wait_until "$BENCH_DEP_TIMEOUT" "every FDB coordinator to listen" coordinators_up
	if ! fdb_available; then
		out=$(fdbcli -C "$FDB_CLUSTER_FILE" --exec "configure new $FDB_REDUNDANCY" --timeout 120 2>&1) ||
			grep -q 'already exists' <<<"$out" || die "fdbcli configure new failed: $out"
		log "fdb: $out"
	fi
	if [[ -n ${BENCH_FDB_CONFIGURE:-} ]]; then
		fdbcli -C "$FDB_CLUSTER_FILE" --exec "configure $FDB_REDUNDANCY $BENCH_FDB_CONFIGURE" --timeout 120
	fi
fi
wait_until "$BENCH_DEP_TIMEOUT" "the FDB database to be available and healthy" fdb_healthy

add_services "$FDB_UNIT"
log "fdb ready on $BENCH_HOST: $nprocs processes ($classes), memory $FDB_MEMORY each, $(fdbserver --version | head -n 1)"
