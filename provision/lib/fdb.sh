#!/usr/bin/env bash
# shellcheck disable=SC2034

FDB_ETC=/etc/foundationdb
FDB_CLUSTER_FILE=$FDB_ETC/fdb.cluster
FDB_DATA=${BENCH_DATA}/foundationdb
FDB_BACKUP_DIR=${BENCH_DATA}/fdb-backup
FDB_UNIT=foundationdb.service
FDB_PORT=4500
FDB_DEFAULT_CLASSES='transaction stateless storage storage storage storage'
FDB_REDUNDANCY='double ssd-redwood-1'
FDB_CACHE=/var/cache/bench

fdb_deb() {
	local kind=$1 sha_var
	sha_var="FDB_$(env_key "$kind")_SHA256"
	require_var FDB_VERSION "$sha_var"
	mkdir -p "$FDB_CACHE"
	fetch "https://github.com/apple/foundationdb/releases/download/${FDB_VERSION}/foundationdb-${kind}_${FDB_VERSION}-1_amd64.deb" \
		"$FDB_CACHE/foundationdb-${kind}_${FDB_VERSION}-1_amd64.deb" "${!sha_var}"
	printf '%s\n' "$FDB_CACHE/foundationdb-${kind}_${FDB_VERSION}-1_amd64.deb"
}

fdb_installed() {
	dpkg-query -W -f='${Status} ${Version}' "foundationdb-$1" 2>/dev/null | grep -q "install ok installed ${FDB_VERSION}"
}

fdb_coordinators() {
	hosts_of fdb | head -n 3
}

fdb_cluster_string() {
	local host addrs=()
	while read -r host; do
		addrs+=("$(host_ip "$host"):$FDB_PORT")
	done < <(fdb_coordinators)
	[[ ${#addrs[@]} -gt 0 ]] || die "no fdb hosts in $BENCH_ENV"
	local IFS=,
	printf 'bench:%s@%s\n' "$(bench_secret fdb-cluster 16)" "${addrs[*]}"
}

fdb_write_cluster_file() {
	local want
	want=$(fdb_cluster_string)
	mkdir -p "$FDB_ETC"
	if [[ -s $FDB_CLUSTER_FILE ]] && [[ "$(cat "$FDB_CLUSTER_FILE")" == "$want" ]]; then
		return 1
	fi
	printf '%s\n' "$want" >"$FDB_CLUSTER_FILE"
	chmod 0664 "$FDB_CLUSTER_FILE"
	return 0
}

fdb_install_clients() {
	fdb_installed clients && return 0
	dpkg -i "$(fdb_deb clients)" >/dev/null
}

fdb_status() {
	fdbcli -C "$FDB_CLUSTER_FILE" --exec 'status json' --timeout 20 2>/dev/null
}

fdb_available() {
	fdb_status | jq -e '.client.database_status.available == true' >/dev/null
}

fdb_healthy() {
	fdb_status | jq -e '.client.database_status.available == true and .client.database_status.healthy == true
		and .cluster.recovery_state.name == "fully_recovered"' >/dev/null
}

fdb_moving_bytes() {
	fdb_status | jq -r '(.cluster.data.moving_data.in_flight_bytes // 0) + (.cluster.data.moving_data.in_queue_bytes // 0)'
}
