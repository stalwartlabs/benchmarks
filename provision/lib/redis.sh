#!/usr/bin/env bash
# shellcheck disable=SC2034

REDIS_SERVICE=mymaster
REDIS_PORT=6379
SENTINEL_PORT=26379
REDIS_UNIT=redis-server.service
SENTINEL_UNIT=redis-sentinel.service
REDIS_CONF=/etc/redis/redis.conf
SENTINEL_CONF=/etc/redis/sentinel.conf

redis_password() {
	bench_secret redis
}

redis_cli() {
	REDISCLI_AUTH=$(redis_password) redis-cli --no-auth-warning -p "$REDIS_PORT" "$@"
}

redis_pong() {
	[[ "$(redis_cli PING 2>/dev/null)" == PONG ]]
}

redis_role() {
	redis_cli ROLE 2>/dev/null | head -n 1
}

sentinel_master_ip() {
	redis-cli -p "$SENTINEL_PORT" SENTINEL get-master-addr-by-name "$REDIS_SERVICE" 2>/dev/null | head -n 1
}

redis_install() {
	require_var REDIS_PKG_VERSION
	apt_install ca-certificates curl gnupg gettext-base
	if [[ ! -s /usr/share/keyrings/redis-archive-keyring.gpg ]]; then
		curl -fsSL https://packages.redis.io/gpg | gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
	fi
	local repo="deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb noble main" pkg pkgs=()
	if [[ "$(cat /etc/apt/sources.list.d/redis.list 2>/dev/null)" != "$repo" ]]; then
		printf '%s\n' "$repo" >/etc/apt/sources.list.d/redis.list
		APT_UPDATED=0
	fi
	for pkg in redis-tools "$@"; do
		pkgs+=("$pkg=$REDIS_PKG_VERSION")
	done
	apt_install "${pkgs[@]}"
	apt-mark hold redis-tools "$@" >/dev/null
	chown redis:redis /etc/redis
}

redis_merge_conf() {
	local dist=$1 overrides=$2 dest=$3 tmp
	tmp=$(mktemp "$dest.XXXXXX")
	awk '
		function key(line,   f) { split(line, f, /[ \t]+/); return f[1] == "sentinel" ? f[1] " " f[2] : f[1] }
		NR == FNR { if ($0 !~ /^[ \t]*(#|$)/) { over[key($0)] = 1; lines[++n] = $0 } next }
		$0 ~ /^[ \t]*(#|$)/ { next }
		!(key($0) in over) { print }
		END { for (i = 1; i <= n; i++) print lines[i] }
	' "$overrides" "$dist" >"$tmp"
	chown redis:redis "$tmp"
	chmod 0640 "$tmp"
	if [[ -f $dest ]] && cmp -s "$tmp" "$dest"; then
		rm -f "$tmp"
		return 1
	fi
	mv -f "$tmp" "$dest"
}
