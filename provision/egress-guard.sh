#!/usr/bin/env bash
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_root
chain=BENCH-EGRESS
mail_ports=25,465,587,2525

allowed_ips() {
	local name
	lab_ips
	for name in $(compgen -v BENCH_LB_); do
		printf '%s\n' "${!name}"
	done
}

iptables -N "$chain" 2>/dev/null || iptables -F "$chain"
iptables -A "$chain" -o lo -j RETURN
while read -r ip; do
	if [[ -n $ip ]]; then
		iptables -A "$chain" -d "$ip" -j RETURN
	fi
done < <(allowed_ips | sort -u)
iptables -A "$chain" -p tcp -m multiport --dports "$mail_ports" -j LOG --log-prefix "bench-egress-drop " --log-level 4 -m limit --limit 6/min
iptables -A "$chain" -p tcp -m multiport --dports "$mail_ports" -j DROP

iptables -C OUTPUT -p tcp -m multiport --dports "$mail_ports" -j "$chain" 2>/dev/null ||
	iptables -I OUTPUT 1 -p tcp -m multiport --dports "$mail_ports" -j "$chain"

log "egress guard: outbound SMTP allowed only to $(allowed_ips | sort -u | wc -l) lab hosts"
