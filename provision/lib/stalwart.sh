#!/usr/bin/env bash
# shellcheck disable=SC2034

STALWART_BIN=/usr/local/bin/stalwart
STALWART_CLI=/usr/local/bin/stalwart-cli
STALWART_ETC=/etc/stalwart
STALWART_DATA=${BENCH_DATA}/stalwart
STALWART_LOG_DIR=/var/log/stalwart
STALWART_RECOVERY_PORT=8080
STALWART_ADMIN_USER="admin@${BENCH_DOMAIN}"
STALWART_PORTS=(25 465 587 993 443)

stalwart_cli() {
	require_var BENCH_ADMIN_PASSWORD
	STALWART_URL=https://127.0.0.1:443 STALWART_USER=$STALWART_ADMIN_USER \
		STALWART_PASSWORD=$BENCH_ADMIN_PASSWORD "$STALWART_CLI" -k --no-color "$@"
}

stalwart_apply_recovery() {
	local plan=$1 secret pid rc=0 extra_env=()
	secret=$(openssl rand -hex 24)
	if [[ -s $STALWART_ETC/stalwart.env ]]; then
		mapfile -t extra_env < <(grep -E '^[A-Z_][A-Z0-9_]*=' "$STALWART_ETC/stalwart.env")
	fi
	systemctl stop stalwart.service 2>/dev/null || true
	setpriv --reuid=stalwart --regid=stalwart --init-groups -- env "${extra_env[@]}" STALWART_RECOVERY_MODE=1 \
		STALWART_RECOVERY_MODE_PORT=$STALWART_RECOVERY_PORT \
		STALWART_RECOVERY_ADMIN="bench-recovery:$secret" \
		"$STALWART_BIN" --config="$STALWART_ETC/config.json" \
		>"$STALWART_LOG_DIR/recovery.log" 2>&1 &
	pid=$!
	local deadline=$((SECONDS + 120))
	until curl -fs -o /dev/null -u "bench-recovery:$secret" "http://127.0.0.1:$STALWART_RECOVERY_PORT/jmap/session"; do
		if ! kill -0 "$pid" 2>/dev/null; then
			tail -n 20 "$STALWART_LOG_DIR/recovery.log" >&2
			die "stalwart exited during recovery-mode start"
		fi
		((SECONDS < deadline)) || die "stalwart recovery listener did not come up"
		sleep 1
	done
	STALWART_URL=http://127.0.0.1:$STALWART_RECOVERY_PORT STALWART_USER=bench-recovery \
		STALWART_PASSWORD=$secret "$STALWART_CLI" --no-color apply --quiet --file "$plan" || rc=$?
	kill -TERM "$pid"
	deadline=$((SECONDS + 60))
	while kill -0 "$pid" 2>/dev/null && ((SECONDS < deadline)); do
		sleep 1
	done
	kill -KILL "$pid" 2>/dev/null || true
	wait "$pid" 2>/dev/null || true
	[[ $rc -eq 0 ]] || die "stalwart-cli apply failed for $plan (rc $rc)"
}

stalwart_wait_ready() {
	wait_ports "${1:-120}" "${STALWART_PORTS[@]}"
	local deadline=$((SECONDS + ${1:-120}))
	until curl -fsk -o /dev/null https://127.0.0.1:443/healthz/ready; do
		((SECONDS < deadline)) || die "stalwart /healthz/ready not OK"
		sleep 1
	done
}
