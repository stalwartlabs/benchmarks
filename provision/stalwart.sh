#!/usr/bin/env bash
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/stalwart.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/stalwart.sh"
# shellcheck source=lib/stage2.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/stage2.sh"
# shellcheck source=lib/redis.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/redis.sh"
# shellcheck source=lib/fdb.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/fdb.sh"
# shellcheck source=lib/production.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/production.sh"

require_root
require_var BENCH_ADMIN_PASSWORD STALWART_CLI_VERSION STALWART_CLI_SHA256
require_tls
conf=$BENCH_ROOT/config/stalwart
plan_src=$conf/$BENCH_PROFILE.ndjson
[[ -f $plan_src ]] || die "no Stalwart plan for profile $BENCH_PROFILE ($plan_src)"
cache=/var/cache/bench
mkdir -p "$cache"

apt_install ca-certificates curl jq gettext-base openssl xz-utils libcap2-bin dnsutils

build_from_source() {
	require_var STALWART_REF STALWART_REPO STALWART_FEATURES
	local src=/opt/bench/build/stalwart
	apt_install build-essential pkg-config clang libclang-dev cmake git
	if [[ ! -x /root/.cargo/bin/cargo ]]; then
		curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable
	fi
	if [[ ! -d $src/.git ]]; then
		git clone --filter=blob:none "$STALWART_REPO" "$src"
	fi
	git -C "$src" fetch --tags --force origin
	git -C "$src" checkout --force "$STALWART_REF"
	if [[ $STALWART_FEATURES == *foundationdb* ]]; then
		install_fdb_clients
	fi
	(
		cd "$src" || exit 1
		RUSTFLAGS="-C target-cpu=native" CFLAGS="-march=native" CXXFLAGS="-march=native" \
			CARGO_PROFILE_RELEASE_LTO=fat CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1 \
			/root/.cargo/bin/cargo build --release -p stalwart --no-default-features \
			--features "$STALWART_FEATURES"
	)
}

install_fdb_clients() {
	require_var FDB_VERSION FDB_CLIENTS_SHA256
	dpkg-query -W -f='${Version}' foundationdb-clients 2>/dev/null | grep -q "^${FDB_VERSION}" && return 0
	local deb=$cache/foundationdb-clients_${FDB_VERSION}-1_amd64.deb
	fetch "https://github.com/apple/foundationdb/releases/download/${FDB_VERSION}/foundationdb-clients_${FDB_VERSION}-1_amd64.deb" \
		"$deb" "$FDB_CLIENTS_SHA256"
	dpkg -i "$deb"
}

binary=""
if [[ -n ${STALWART_BINARY:-} && -x ${STALWART_BINARY} ]]; then
	binary=$STALWART_BINARY
elif [[ -n ${STALWART_BINARY_URL:-} ]]; then
	fetch "$STALWART_BINARY_URL" "$cache/stalwart" "${STALWART_BINARY_SHA256:-}"
	chmod 0755 "$cache/stalwart"
	binary=$cache/stalwart
else
	build_from_source >&2
	binary=/opt/bench/build/stalwart/target/release/stalwart
fi
if ! cmp -s "$binary" "$STALWART_BIN"; then
	systemctl stop stalwart.service 2>/dev/null || true
	install -m 0755 "$binary" "$STALWART_BIN"
fi
if ldd "$STALWART_BIN" | grep -q 'libfdb_c'; then
	install_fdb_clients
fi
ldd "$STALWART_BIN" | grep -q 'not found' && die "stalwart has unresolved libraries: $(ldd "$STALWART_BIN" | grep 'not found')"

cli_tar=$cache/stalwart-cli-${STALWART_CLI_VERSION}.tar.xz
fetch "https://github.com/stalwartlabs/cli/releases/download/v${STALWART_CLI_VERSION}/stalwart-cli-x86_64-unknown-linux-gnu.tar.xz" \
	"$cli_tar" "$STALWART_CLI_SHA256"
if [[ ! -x $STALWART_CLI ]] || ! "$STALWART_CLI" --version | grep -q "$STALWART_CLI_VERSION"; then
	tar -xJf "$cli_tar" -C "$cache" --strip-components=1 --wildcards '*/stalwart-cli'
	install -m 0755 "$cache/stalwart-cli" "$STALWART_CLI"
fi

id stalwart >/dev/null 2>&1 || useradd -r -U -s /usr/sbin/nologin -M -d "$STALWART_DATA" stalwart
install -d -o stalwart -g stalwart -m 0750 "$STALWART_DATA" "$STALWART_DATA/db" "$STALWART_LOG_DIR" "$STALWART_ETC/tls"
install -o stalwart -g stalwart -m 0644 "$BENCH_TLS_DIR/cert.pem" "$STALWART_ETC/tls/cert.pem"
install -o stalwart -g stalwart -m 0600 "$BENCH_TLS_DIR/key.pem" "$STALWART_ETC/tls/key.pem"

if [[ $BENCH_PROFILE == production ]]; then
	prod_config_json >"$cache/config.json"
	install_file "$cache/config.json" "$STALWART_ETC/config.json" 0644 || true
	prod_env_file || true
else
	STALWART_DATA=$STALWART_DATA render "$conf/config.json" "$STALWART_ETC/config.json" '${STALWART_DATA}' 0644 || true
fi
if install_file "$conf/stalwart.service" /etc/systemd/system/stalwart.service; then
	systemctl daemon-reload
fi
systemctl enable stalwart.service >/dev/null 2>&1

plan=$STALWART_ETC/plan.ndjson
umask 077
TLS_CERT=$STALWART_ETC/tls/cert.pem TLS_KEY=$STALWART_ETC/tls/key.pem \
	STALWART_HOSTNAME=$BENCH_MAIL_HOSTNAME LOG_DIR=$STALWART_LOG_DIR \
	ADMIN_HASH=$(printf '%s\n' "$BENCH_ADMIN_PASSWORD" | sha512_crypt) BENCH_DOMAIN=$BENCH_DOMAIN \
	envsubst '${TLS_CERT} ${TLS_KEY} ${STALWART_HOSTNAME} ${LOG_DIR} ${ADMIN_HASH} ${BENCH_DOMAIN}' \
	<"$plan_src" >"$plan.tmp"
while read -r host ip; do
	jq -cn --arg ip "$ip" --arg host "$host" \
		'{"@type":"upsert","object":"AllowedIp","matchOn":["address"],"value":{("ip-" + $host):{"address":$ip,"reason":("bench load host " + $host)}}}'
done < <(load_host_ips) >>"$plan.tmp"
if [[ $BENCH_PROFILE == production ]]; then
	prod_plan_lines >>"$plan.tmp"
fi
mv -f "$plan.tmp" "$plan"
umask 022

use_dns_stub

if [[ $BENCH_PROFILE != production ]]; then
	stalwart_apply_recovery "$plan"
	systemctl restart stalwart.service
	stalwart_wait_ready 180
	register_services stalwart.service
else
	prod_wait_dependencies
	first=$(first_host_of stalwart)
	digest=$(prod_plan_digest "$plan")
	if prod_is_cluster && [[ $BENCH_HOST != "$first" ]]; then
		wait_until "$BENCH_DEP_TIMEOUT" "$first to apply and publish this plan" prod_plan_published "$digest"
	else
		stalwart_apply_recovery "$plan"
	fi
	systemctl restart stalwart.service
	stalwart_wait_ready 180
	if prod_is_cluster && [[ $BENCH_HOST == "$first" ]]; then
		prod_redis_cli SET "$STALWART_PLAN_KEY" "$digest" >/dev/null
	fi
	add_services stalwart.service
fi
log "stalwart ready: $("$STALWART_BIN" --version), profile $BENCH_PROFILE"
