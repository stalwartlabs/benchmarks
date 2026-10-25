#!/usr/bin/env bash
# shellcheck disable=SC2034

GARAGE_BIN=/usr/local/bin/garage
GARAGE_CONF=/etc/garage.toml
GARAGE_DATA=${BENCH_DATA}/garage
GARAGE_UNIT=bench-garage.service
GARAGE_S3_PORT=3900
GARAGE_RPC_PORT=3901
GARAGE_ADMIN_PORT=3903

garage_cli() {
	"$GARAGE_BIN" -c "$GARAGE_CONF" "$@"
}

garage_admin_token() {
	bench_secret garage-admin 64
}

garage_node_id() {
	curl -fsS --max-time 5 -H "Authorization: Bearer $(garage_admin_token)" \
		"http://$1:$GARAGE_ADMIN_PORT/v2/GetNodeInfo?node=self" | jq -er '.success | keys[0]'
}

garage_healthy() {
	garage_cli json-api GetClusterHealth 2>/dev/null | jq -e '.status == "healthy"' >/dev/null
}
