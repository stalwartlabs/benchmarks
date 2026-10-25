#!/usr/bin/env bash
# shellcheck disable=SC2034

STALWART_ENV_FILE=$STALWART_ETC/stalwart.env
STALWART_ROCKSDB_CACHE=8589934592
STALWART_CLUSTER_MESSAGE_CACHE=4294967296
STALWART_PLAN_KEY=bench:stalwart:plan

prod_backend() {
	if [[ -n $(first_host_of fdb) ]]; then
		echo foundationdb
	elif [[ -n $(first_host_of postgres-primary) ]]; then
		echo postgresql
	else
		echo rocksdb
	fi
}

prod_is_cluster() {
	[[ -n $(first_host_of redis) ]]
}

prod_config_json() {
	case $(prod_backend) in
	rocksdb)
		jq -cn --arg path "$STALWART_DATA/db" --argjson cache "$STALWART_ROCKSDB_CACHE" \
			'{"@type":"RocksDb","path":$path,"cacheSize":$cache}'
		;;
	postgresql)
		jq -cn --arg host "$(host_ip "$(first_host_of postgres-primary)")" \
			'{"@type":"PostgreSql","host":$host,"port":5432,"database":"stalwart","authUsername":"stalwart",
				"authSecret":{"@type":"EnvironmentVariable","variableName":"STALWART_DB_PASSWORD"}}'
		;;
	foundationdb)
		jq -cn --arg file "$FDB_CLUSTER_FILE" '{"@type":"FoundationDb","clusterFile":$file}'
		;;
	esac
}

prod_env_file() {
	local tmp
	tmp=$(mktemp)
	{
		printf 'STALWART_HOSTNAME=%s\n' "$BENCH_HOST"
		[[ -z ${STALWART_LICENSE_KEY:-} ]] || printf 'STALWART_LICENSE_KEY=%s\n' "$STALWART_LICENSE_KEY"
		[[ $(prod_backend) != postgresql ]] || printf 'STALWART_DB_PASSWORD=%s\n' "$(bench_secret pg-stalwart)"
		if prod_is_cluster; then
			printf 'STALWART_REDIS_PASSWORD=%s\n' "$(redis_password)"
			printf 'STALWART_S3_ACCESS_KEY=%s\nSTALWART_S3_SECRET_KEY=%s\n' "$(s3_access_key)" "$(s3_secret_key)"
		fi
	} >"$tmp"
	if [[ -f $STALWART_ENV_FILE ]] && cmp -s "$tmp" "$STALWART_ENV_FILE"; then
		rm -f "$tmp"
		return 1
	fi
	install -m 0600 "$tmp" "$STALWART_ENV_FILE"
	rm -f "$tmp"
}

prod_plan_lines() {
	local ips=() host ip expr
	while read -r host ip; do
		ips+=("$ip")
		jq -cn --arg ip "$ip" --arg host "$host" \
			'{"@type":"upsert","object":"AllowedIp","matchOn":["address"],"value":{("ip-" + $host):{"address":$ip,"reason":("bench load host " + $host)}}}'
	done < <(public_load_ips)
	while read -r host ip; do
		ips+=("$ip")
	done < <(load_host_ips)
	if [[ -n ${BENCH_LB_PUBLIC:-} ]]; then
		jq -cn --arg ip "$AZURE_PROBE_IP" \
			'{"@type":"upsert","object":"AllowedIp","matchOn":["address"],"value":{"ip-lb-probe":{"address":$ip,"reason":"Azure load balancer health probes"}}}'
	fi
	expr=true
	if [[ ${#ips[@]} -gt 0 ]]; then
		expr="!($(printf "remote_ip == '%s' || " "${ips[@]}" | sed 's/ || $//'))"
	fi
	jq -cn --arg m "$expr" '
		{"@type":"reconcile","object":"MtaInboundThrottle","matchOn":["description"],"value":{
			"thr-ip":{"description":"Sender IP throttle","enable":true,"key":{"remoteIp":true},"rate":{"count":5,"period":1000},
				"match":{"else":$m,"match":{}}},
			"thr-rcpt":{"description":"Sender address to recipient throttle","enable":true,"key":{"senderDomain":true,"rcpt":true},
				"rate":{"count":25,"period":3600000},"match":{"else":$m,"match":{}}}}}'
	[[ -z ${STALWART_LICENSE_KEY:-} ]] ||
		jq -cn '{"@type":"update","object":"Enterprise","value":{"licenseKey":{"@type":"EnvironmentVariable","variableName":"STALWART_LICENSE_KEY"}}}'
	if prod_is_cluster; then
		local urls=()
		while read -r host; do
			urls+=("redis://$(host_ip "$host"):$SENTINEL_PORT")
		done < <(hosts_with_script sentinel)
		jq -cn --arg url "$(s3_endpoint)" --arg region "$(s3_region)" --arg bucket "$BENCH_S3_BUCKET" '
			{"@type":"update","object":"BlobStore","value":{"@type":"S3","bucket":$bucket,
				"region":{"@type":"Custom","url":$url,"region":$region},
				"accessKeyId":{"@type":"EnvironmentVariable","variableName":"STALWART_S3_ACCESS_KEY"},
				"secretKey":{"@type":"EnvironmentVariable","variableName":"STALWART_S3_SECRET_KEY"}}}'
		jq -cn --arg service "$REDIS_SERVICE" --args '
			{"@type":"update","object":"InMemoryStore","value":{"@type":"RedisSentinel",
				"urls":($ARGS.positional | map({key: ., value: true}) | from_entries),"serviceName":$service,
				"authSecret":{"@type":"EnvironmentVariable","variableName":"STALWART_REDIS_PASSWORD"}}}' "${urls[@]}"
		jq -cn '{"@type":"update","object":"Coordinator","value":{"@type":"Default"}}'
		jq -cn --argjson size "$STALWART_CLUSTER_MESSAGE_CACHE" '{"@type":"update","object":"Cache","value":{"messages":$size}}'
	fi
}

prod_redis_cli() {
	local master
	master=$(redis-cli -p "$SENTINEL_PORT" SENTINEL get-master-addr-by-name "$REDIS_SERVICE" 2>/dev/null | head -n 1)
	[[ -n $master ]] || return 1
	redis_cli -h "$master" "$@"
}

prod_redis_ping() {
	[[ "$(prod_redis_cli PING 2>/dev/null)" == PONG ]]
}

prod_pg_login() {
	PGPASSWORD=$(bench_secret pg-stalwart) psql -X -At -h "$(host_ip "$(first_host_of postgres-primary)")" \
		-U stalwart -d stalwart -c 'SELECT 1'
}

prod_wait_dependencies() {
	case $(prod_backend) in
	postgresql)
		command -v psql >/dev/null || apt_install postgresql-client
		wait_until "$BENCH_DEP_TIMEOUT" "a PostgreSQL login on the primary" prod_pg_login
		;;
	foundationdb)
		fdb_write_cluster_file || true
		fdb_install_clients
		wait_until "$BENCH_DEP_TIMEOUT" "the FDB database to be available and healthy" fdb_healthy
		;;
	esac
	if prod_is_cluster; then
		command -v redis-cli >/dev/null || redis_install
		wait_until "$BENCH_DEP_TIMEOUT" "the redis master through the local sentinel" prod_redis_ping
		wait_until "$BENCH_DEP_TIMEOUT" "bucket $BENCH_S3_BUCKET at $(s3_endpoint)" s3_bucket_exists "$(s3_endpoint)" "$(s3_region)"
	fi
}

prod_plan_digest() {
	sed -E 's/\$6\$[^"]*/<hash>/g' "$1" | cat - "$STALWART_ETC/config.json" | sha256sum | cut -d' ' -f1
}

prod_plan_published() {
	[[ "$(prod_redis_cli GET "$STALWART_PLAN_KEY" 2>/dev/null)" == "$1" ]]
}
