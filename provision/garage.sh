#!/usr/bin/env bash
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/stage2.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/stage2.sh"
# shellcheck source=lib/garage.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/garage.sh"

require_root
require_var GARAGE_VERSION GARAGE_SHA256 BENCH_HOST BENCH_PRIVATE_IP
cd /
first=$(first_host_of garage)
cache=/var/cache/bench
mkdir -p "$cache"
apt_install ca-certificates curl jq gettext-base rclone

fetch "https://garagehq.deuxfleurs.fr/_releases/${GARAGE_VERSION}/x86_64-unknown-linux-musl/garage" "$cache/garage-$GARAGE_VERSION" "$GARAGE_SHA256"
changed=0
if install_file "$cache/garage-$GARAGE_VERSION" "$GARAGE_BIN" 0755; then
	changed=1
fi
id garage >/dev/null 2>&1 || useradd -r -U -s /usr/sbin/nologin -M -d "$GARAGE_DATA" garage
install -d -o garage -g garage -m 0750 "$GARAGE_DATA" "$GARAGE_DATA/meta" "$GARAGE_DATA/data"

export GARAGE_DATA BENCH_PRIVATE_IP GARAGE_RPC_SECRET GARAGE_ADMIN_TOKEN
GARAGE_RPC_SECRET=$(bench_secret garage-rpc 64)
GARAGE_ADMIN_TOKEN=$(garage_admin_token)
if render "$BENCH_ROOT/config/garage/garage.toml" "$GARAGE_CONF" \
	'${GARAGE_DATA} ${BENCH_PRIVATE_IP} ${GARAGE_RPC_SECRET} ${GARAGE_ADMIN_TOKEN}' 0640; then
	changed=1
fi
chgrp garage "$GARAGE_CONF"
if install_file "$BENCH_ROOT/config/garage/garage.service" "/etc/systemd/system/$GARAGE_UNIT"; then
	systemctl daemon-reload
	changed=1
fi
systemctl enable "$GARAGE_UNIT" >/dev/null 2>&1
if [[ $changed -eq 1 ]] || ! systemctl is-active --quiet "$GARAGE_UNIT"; then
	systemctl restart "$GARAGE_UNIT"
fi
wait_ports 120 "$GARAGE_S3_PORT" "$GARAGE_RPC_PORT" "$GARAGE_ADMIN_PORT"
add_services "$GARAGE_UNIT"

access_key=$(s3_access_key)
endpoint=http://127.0.0.1:$GARAGE_S3_PORT
if [[ $BENCH_HOST == "$first" ]]; then
	declare -A node_ids=()
	for host in $(hosts_of garage); do
		ip=$(host_ip "$host")
		wait_until "$BENCH_DEP_TIMEOUT" "the Garage admin API on $host" garage_node_id "$ip"
		node_ids[$host]=$(garage_node_id "$ip")
		if [[ $host != "$BENCH_HOST" ]]; then
			garage_cli node connect "${node_ids[$host]}@$ip:$GARAGE_RPC_PORT" >/dev/null
		fi
	done
	version=$(garage_cli json-api GetClusterLayout | jq -r '.version')
	if [[ $version == 0 ]]; then
		capacity=$(df -BG --output=size "$BENCH_DATA" | tail -n 1 | tr -dc '0-9')
		capacity=$((capacity * 9 / 10))
		for host in "${!node_ids[@]}"; do
			garage_cli layout assign -z "$host" -c "${capacity}G" "${node_ids[$host]}" >/dev/null
		done
		garage_cli layout apply --version 1
	fi
	wait_until 600 "the Garage cluster to be healthy" garage_healthy
	garage_cli key info "$access_key" >/dev/null 2>&1 || garage_cli key import --yes -n bench "$access_key" "$(s3_secret_key)" >/dev/null
	garage_cli bucket info "$BENCH_S3_BUCKET" >/dev/null 2>&1 || garage_cli bucket create "$BENCH_S3_BUCKET" >/dev/null
	garage_cli bucket allow --read --write --owner "$BENCH_S3_BUCKET" --key "$access_key" >/dev/null
	write_rclone_conf Other "$endpoint" "$(s3_region garage)"
fi
wait_until "$BENCH_DEP_TIMEOUT" "bucket $BENCH_S3_BUCKET on the local Garage node" s3_bucket_exists "$endpoint" "$(s3_region garage)"
log "garage ready on $BENCH_HOST: $("$GARAGE_BIN" --version | head -n 1), node $(garage_cli node id -q 2>/dev/null)"
