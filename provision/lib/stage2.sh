#!/usr/bin/env bash
# shellcheck disable=SC2034

BENCH_HOST=${BENCH_HOST:-$(hostname -s)}
BENCH_HOSTS_JSON=${BENCH_HOSTS_JSON:-/etc/bench/hosts.json}
BENCH_S3_BUCKET=${BENCH_S3_BUCKET:-stalwart}
BENCH_S3_CLUSTER=${BENCH_S3_CLUSTER:-garage}
BENCH_DEP_TIMEOUT=${BENCH_DEP_TIMEOUT:-5400}
AZURE_PROBE_IP=168.63.129.16

env_key() {
	tr '[:lower:]-' '[:upper:]_' <<<"$1"
}

host_ip() {
	local var
	var="BENCH_IP_$(env_key "$1")"
	[[ -n ${!var:-} ]] || die "no private IP for host $1 ($var)"
	printf '%s\n' "${!var}"
}

hosts_of() {
	local var
	var="BENCH_HOSTS_$(env_key "$1")"
	tr ' ' '\n' <<<"${!var:-}" | grep -v '^$' | sort -V || true
}

first_host_of() {
	hosts_of "$1" | head -n 1
}

hosts_with_script() {
	[[ -r $BENCH_HOSTS_JSON ]] || die "$BENCH_HOSTS_JSON missing"
	jq -r --arg s "$1" '.hosts[] | select(any(.provision[]?; . == $s)) | .name' "$BENCH_HOSTS_JSON" | sort -V
}

bench_secret() {
	local label=$1 len=${2:-40} override
	override="BENCH_SECRET_$(env_key "$label")"
	if [[ -n ${!override:-} ]]; then
		printf '%s\n' "${!override}"
		return 0
	fi
	[[ -r $BENCH_TLS_DIR/key.pem ]] || die "$BENCH_TLS_DIR/key.pem missing: per-run secrets are derived from it"
	{
		printf 'bench-secret:%s:%s\n' "${BENCH_RUN:-}" "$label"
		cat "$BENCH_TLS_DIR/key.pem"
	} | sha256sum | cut -c "1-$len"
}

s3_access_key() {
	printf 'GK%s\n' "$(bench_secret s3-access-key 24)"
}

s3_secret_key() {
	bench_secret s3-secret-key 64
}

add_services() {
	local tmp
	tmp=$(mktemp "$BENCH_SERVICES_FILE.XXXXXX")
	{
		[[ -s $BENCH_SERVICES_FILE ]] && grep -v '^$' "$BENCH_SERVICES_FILE"
		printf '%s\n' "$@"
	} | awk '!seen[$0]++' >"$tmp"
	chmod 0644 "$tmp"
	mv -f "$tmp" "$BENCH_SERVICES_FILE"
}

wait_until() {
	local timeout=$1 what=$2 deadline
	shift 2
	deadline=$((SECONDS + timeout))
	until "$@" >/dev/null 2>&1; do
		((SECONDS < deadline)) || die "timed out after ${timeout}s waiting for $what"
		sleep 3
	done
}

wait_until_soft() {
	local timeout=$1 deadline
	shift
	deadline=$((SECONDS + timeout))
	until "$@" >/dev/null 2>&1; do
		((SECONDS < deadline)) || return 1
		sleep 3
	done
}

tcp_open() {
	timeout 3 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null
}

s3_endpoint() {
	local cluster=${1:-$BENCH_S3_CLUSTER} var port host
	case $cluster in
	garage) port=3900 ;;
	ceph) port=80 ;;
	*) die "unknown S3 cluster '$cluster' (garage or ceph)" ;;
	esac
	for var in "BENCH_LB_S3_$(env_key "$cluster")" BENCH_LB_S3; do
		if [[ -n ${!var:-} ]]; then
			printf 'http://%s:%s\n' "${!var}" "$port"
			return 0
		fi
	done
	host=$(first_host_of "$cluster")
	[[ -n $host ]] || die "no $cluster hosts and no S3 load balancer in $BENCH_ENV"
	printf 'http://%s:%s\n' "$(host_ip "$host")" "$port"
}

s3_region() {
	case ${1:-$BENCH_S3_CLUSTER} in
	garage) echo garage ;;
	*) echo us-east-1 ;;
	esac
}

s3_bucket_exists() {
	local endpoint=$1 region=$2
	curl -fsS -o /dev/null -I --max-time 10 --aws-sigv4 "aws:amz:$region:s3" \
		--user "$(s3_access_key):$(s3_secret_key)" "$endpoint/$BENCH_S3_BUCKET"
}

write_rclone_conf() {
	local tmp
	tmp=$(mktemp)
	{
		printf '[src]\ntype = s3\nprovider = %s\nendpoint = %s\nregion = %s\naccess_key_id = %s\nsecret_access_key = %s\nforce_path_style = true\n' \
			"$1" "$2" "$3" "$(s3_access_key)" "$(s3_secret_key)"
		if [[ $# -ge 5 ]]; then
			printf '\n[garage]\ntype = s3\nprovider = Other\nendpoint = %s\nregion = %s\naccess_key_id = %s\nsecret_access_key = %s\nforce_path_style = true\n' \
				"$4" "$5" "$(s3_access_key)" "$(s3_secret_key)"
		fi
	} >"$tmp"
	install -m 0600 "$tmp" /etc/bench/rclone.conf
	rm -f "$tmp"
}

public_load_ips() {
	local host var
	for host in ${BENCH_HOSTS_LOAD:-}; do
		var="BENCH_PUBLIC_IP_$(env_key "$host")"
		if [[ -n ${!var:-} ]]; then
			printf '%s %s\n' "$host-public" "${!var}"
		fi
	done
	for var in ${BENCH_ALLOWED_IPS:-}; do
		printf 'extra-%s %s\n' "${var//[^0-9a-fA-F]/-}" "$var"
	done
}
