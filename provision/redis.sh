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

redis_install redis-server
[[ -f $REDIS_CONF.dist ]] || cp -p "$REDIS_CONF" "$REDIS_CONF.dist"

export REDIS_PASSWORD BENCH_PRIVATE_IP REDIS_MAXMEMORY
REDIS_PASSWORD=$(redis_password)
REDIS_MAXMEMORY="$(awk '/^MemTotal:/ {print int($2 * 3 / 4 / 1024)}' /proc/meminfo)mb"
overrides=$(mktemp)
envsubst '${REDIS_PASSWORD} ${BENCH_PRIVATE_IP} ${REDIS_MAXMEMORY}' <"$BENCH_ROOT/config/redis/redis.conf" >"$overrides"
if [[ $BENCH_HOST != "$primary" ]]; then
	printf 'save ""\nreplicaof %s %s\n' "$(host_ip "$primary")" "$REDIS_PORT" >>"$overrides"
fi
if redis_merge_conf "$REDIS_CONF.dist" "$overrides" /etc/redis/redis.base || [[ ! -f /etc/redis/.bench-applied ]]; then
	install -o redis -g redis -m 0640 /etc/redis/redis.base "$REDIS_CONF"
	touch /etc/redis/.bench-applied
	systemctl restart "$REDIS_UNIT"
fi
rm -f "$overrides"
systemctl enable "$REDIS_UNIT" >/dev/null 2>&1
systemctl is-active --quiet "$REDIS_UNIT" || systemctl start "$REDIS_UNIT"
wait_until 120 "redis to answer PING" redis_pong

add_services "$REDIS_UNIT"
log "redis ready on $BENCH_HOST ($(redis_role)), $(redis-server --version | awk '{print $3}')"
