#!/usr/bin/env bash
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_root
require_var BENCH_IP_SINK
conf=$BENCH_ROOT/config/dns-stub
zones_conf=/etc/unbound/bench-zones.conf
dnsbl_conf=/etc/unbound/bench-dnsbl.conf

upstream_dns() {
	local f
	for f in /run/systemd/resolve/resolv.conf /etc/resolv.conf; do
		if [[ -r $f ]]; then
			awk '$1 == "nameserver" && $2 !~ /^127\./ {print $2; exit}' "$f"
		fi
	done | head -n 1
}

lab_ip_of() {
	local var
	var="BENCH_IP_$(tr '[:lower:]-' '[:upper:]_' <<<"$1")"
	printf '%s' "${!var:-}"
}

apt_install unbound rbldnsd dnsutils dns-root-data
if systemctl list-unit-files rbldnsd.service >/dev/null 2>&1; then
	systemctl disable --now rbldnsd.service >/dev/null 2>&1 || true
fi

UPSTREAM_DNS=$(upstream_dns)
[[ -n $UPSTREAM_DNS ]] || die "cannot determine the upstream resolver"
export UPSTREAM_DNS BENCH_IP_SINK

tmp=$(mktemp)
{
	printf 'local-zone: "%s." static\n' "$BENCH_DOMAIN" "$BENCH_REMOTE_DOMAIN"
	mx_local=$(lab_ip_of stalwart)
	if [[ -z $mx_local && -n ${BENCH_HOSTS_STALWART:-} ]]; then
		mx_local=$(lab_ip_of "$(tr ' ' '\n' <<<"$BENCH_HOSTS_STALWART" | sort -V | head -n 1)")
	fi
	spf_public=""
	for name in $(compgen -v BENCH_PUBLIC_IP_); do
		spf_public+=" ip4:${!name}"
	done
	printf 'local-data: "%s. 300 IN MX 10 mail.%s."\n' "$BENCH_DOMAIN" "$BENCH_DOMAIN"
	printf 'local-data: "mail.%s. 300 IN A %s"\n' "$BENCH_DOMAIN" "${mx_local:-$BENCH_IP_SINK}"
	printf 'local-data: "%s. 300 IN MX 10 mx.%s."\n' "$BENCH_REMOTE_DOMAIN" "$BENCH_REMOTE_DOMAIN"
	printf 'local-data: "mx.%s. 300 IN A %s"\n' "$BENCH_REMOTE_DOMAIN" "$BENCH_IP_SINK"
	for d in "$BENCH_DOMAIN" "$BENCH_REMOTE_DOMAIN"; do
		printf "local-data: '%s. 300 IN TXT \"v=spf1 ip4:10.0.0.0/8 ip4:172.16.0.0/12 ip4:192.168.0.0/16%s -all\"'\n" "$d" "$spf_public"
		printf "local-data: '_dmarc.%s. 300 IN TXT \"v=DMARC1; p=none\"'\n" "$d"
	done
	for name in $(compgen -v BENCH_IP_); do
		host=$(tr '[:upper:]_' '[:lower:]-' <<<"${name#BENCH_IP_}")
		ip=${!name}
		printf 'local-data: "%s.lab.%s. 300 IN A %s"\n' "$host" "$BENCH_DOMAIN" "$ip"
		printf 'local-data-ptr: "%s %s.lab.%s"\n' "$ip" "$host" "$BENCH_DOMAIN"
	done
	for name in $(compgen -v BENCH_PUBLIC_IP_); do
		host=$(tr '[:upper:]_' '[:lower:]-' <<<"${name#BENCH_PUBLIC_IP_}")-public
		ip=${!name}
		printf 'local-data: "%s.lab.%s. 300 IN A %s"\n' "$host" "$BENCH_DOMAIN" "$ip"
		printf 'local-data-ptr: "%s %s.lab.%s"\n' "$ip" "$host" "$BENCH_DOMAIN"
	done
	if [[ -f /etc/bench/dkim.records ]]; then
		while read -r rr; do
			if [[ -n $rr ]]; then
				printf 'local-data: "%s"\n' "$rr"
			fi
		done </etc/bench/dkim.records
	fi
} >"$tmp"
changed=0
if install_file "$tmp" "$zones_conf"; then
	changed=1
fi

install -d -m 0755 /etc/rbldnsd
rbl_zones=()
: >"$tmp"
while read -r zone type; do
	[[ -z $zone || $zone == \#* ]] && continue
	install -m 0644 "$conf/$type.txt" "/etc/rbldnsd/$zone"
	rbl_zones+=("$zone:$type:$zone")
	printf 'stub-zone:\n  name: "%s."\n  stub-addr: 127.0.0.1@5353\n' "$zone" >>"$tmp"
	printf 'server:\n  domain-insecure: "%s."\n  local-zone: "%s." transparent\n' "$zone" "$zone" >>"$tmp"
done <"$conf/dnsbl-zones.txt"
if install_file "$tmp" "$dnsbl_conf"; then
	changed=1
fi
rm -f "$tmp"

export RBLDNSD_ZONES="${rbl_zones[*]}"
if render "$conf/rbldnsd.service" /etc/systemd/system/bench-rbldnsd.service '${RBLDNSD_ZONES}'; then
	systemctl daemon-reload
	systemctl restart bench-rbldnsd.service
fi
systemctl enable --now bench-rbldnsd.service >/dev/null 2>&1

if render "$conf/unbound.conf" /etc/unbound/unbound.conf.d/bench.conf '${BENCH_IP_SINK} ${UPSTREAM_DNS}'; then
	changed=1
fi
if [[ ! -s /var/lib/unbound/root.key && -s /usr/share/dns/root.key ]]; then
	install -o unbound -g unbound -m 0644 /usr/share/dns/root.key /var/lib/unbound/root.key
fi
unbound-checkconf >/dev/null
systemctl enable unbound.service >/dev/null 2>&1
if [[ $changed -eq 1 ]] || ! systemctl is-active --quiet unbound.service; then
	systemctl restart unbound.service
fi

deadline=$((SECONDS + 60))
until dig +short +time=1 +tries=1 @"$BENCH_IP_SINK" MX "$BENCH_REMOTE_DOMAIN" | grep -q .; do
	((SECONDS < deadline)) || die "unbound does not answer on $BENCH_IP_SINK"
	sleep 1
done
dig +short @"$BENCH_IP_SINK" 2.0.0.127.zen.spamhaus.org A | grep -q '127.0.0.2' || die "rbldnsd zones not answering through unbound"
log "dns stub ready on $BENCH_IP_SINK (upstream $UPSTREAM_DNS)"
