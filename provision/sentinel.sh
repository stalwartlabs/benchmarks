#!/usr/bin/env bash
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/stage2.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/stage2.sh"
# shellcheck source=lib/redis.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/redis.sh"

require_root
require_var BENCH_HOST BENCH_PRIVATE_IP
cd /
primary=$(first_host_of redis)
[[ -n $primary ]] || die "no redis hosts in $BENCH_ENV"
sentinels=$(hosts_with_script sentinel | wc -l)
((sentinels >= 3)) || log "WARNING: only $sentinels sentinel hosts; a quorum needs 3"

redis_install redis-server redis-sentinel
if [[ ${BENCH_ROLE:-} != redis ]]; then
	systemctl disable --now "$REDIS_UNIT" >/dev/null 2>&1 || true
fi
[[ -f $SENTINEL_CONF.dist ]] || cp -p "$SENTINEL_CONF" "$SENTINEL_CONF.dist"

export REDIS_PASSWORD BENCH_PRIVATE_IP REDIS_SERVICE REDIS_PRIMARY_IP SENTINEL_QUORUM
REDIS_PASSWORD=$(redis_password)
REDIS_PRIMARY_IP=$(host_ip "$primary")
SENTINEL_QUORUM=$((sentinels / 2 + 1))
overrides=$(mktemp)
envsubst '${REDIS_PASSWORD} ${BENCH_PRIVATE_IP} ${REDIS_SERVICE} ${REDIS_PRIMARY_IP} ${SENTINEL_QUORUM}' \
	<"$BENCH_ROOT/config/redis/sentinel.conf" >"$overrides"
if redis_merge_conf "$SENTINEL_CONF.dist" "$overrides" /etc/redis/sentinel.base || [[ ! -f /etc/redis/.bench-sentinel-applied ]]; then
	systemctl stop "$SENTINEL_UNIT" 2>/dev/null || true
	install -o redis -g redis -m 0640 /etc/redis/sentinel.base "$SENTINEL_CONF"
	touch /etc/redis/.bench-sentinel-applied
fi
rm -f "$overrides"
systemctl enable "$SENTINEL_UNIT" >/dev/null 2>&1
systemctl is-active --quiet "$SENTINEL_UNIT" || systemctl start "$SENTINEL_UNIT"
master_ok() {
	local ip
	ip=$(sentinel_master_ip)
	[[ -n $ip ]] && [[ "$(redis_cli -h "$ip" PING 2>/dev/null)" == PONG ]]
}
wait_until "$BENCH_DEP_TIMEOUT" "the redis master of $REDIS_SERVICE to answer" master_ok

add_services "$SENTINEL_UNIT"
log "sentinel ready on $BENCH_HOST: master $(sentinel_master_ip), quorum $SENTINEL_QUORUM of $sentinels"
