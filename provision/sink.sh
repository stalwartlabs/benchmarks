#!/usr/bin/env bash
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_root
mailbench=$BENCH_ROOT/bin/mailbench
[[ -x $mailbench ]] || die "$mailbench missing: upload the mailbench binary to the sink host"

for unit in postfix.service exim4.service; do
	if systemctl list-unit-files "$unit" >/dev/null 2>&1; then
		systemctl disable --now "$unit" >/dev/null 2>&1 || true
	fi
done

changed=0
if install_file "$BENCH_ROOT/config/sink/bench-sink.service" /etc/systemd/system/bench-sink.service; then
	systemctl daemon-reload
	changed=1
fi
systemctl enable bench-sink.service >/dev/null 2>&1
if [[ $changed -eq 1 ]] || ! systemctl is-active --quiet bench-sink.service; then
	systemctl restart bench-sink.service
fi
wait_ports 30 25
register_services unbound.service bench-rbldnsd.service bench-sink.service
log "sink MTA ready on port 25"
