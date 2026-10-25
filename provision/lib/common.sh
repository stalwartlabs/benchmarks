#!/usr/bin/env bash
# shellcheck disable=SC2034

set -euo pipefail

BENCH_ROOT=${BENCH_ROOT:-/opt/bench}
BENCH_ENV=${BENCH_ENV:-/etc/bench/bench.env}
BENCH_TLS_DIR=${BENCH_TLS_DIR:-/etc/bench/tls}
BENCH_SERVICES_FILE=/etc/bench/services

if [[ -r "$BENCH_ENV" ]]; then
	# shellcheck source=/dev/null
	source "$BENCH_ENV"
fi
if [[ -r "$BENCH_ROOT/versions.env" ]]; then
	# shellcheck source=/dev/null
	source "$BENCH_ROOT/versions.env"
fi

BENCH_DOMAIN=${BENCH_DOMAIN:-example.org}
BENCH_REMOTE_DOMAIN=${BENCH_REMOTE_DOMAIN:-example.net}
BENCH_DATA=${BENCH_DATA:-/mnt/data}
BENCH_PROFILE=${BENCH_PROFILE:-fairness}
BENCH_MAIL_HOSTNAME="mail.${BENCH_DOMAIN}"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

log() {
	printf '%s [%s] %s\n' "$(date -u +%FT%TZ)" "${0##*/}" "$*" >&2
}

die() {
	log "ERROR: $*"
	exit 1
}

require_root() {
	[[ $EUID -eq 0 ]] || die "must run as root"
}

require_var() {
	local name
	for name in "$@"; do
		[[ -n ${!name:-} ]] || die "$name is not set (bench.env or versions.env)"
	done
}

apt_install() {
	local missing=() pkg
	for pkg in "$@"; do
		dpkg-query -W -f='${Status}' "${pkg%%=*}" 2>/dev/null | grep -q 'install ok installed' || missing+=("$pkg")
	done
	[[ ${#missing[@]} -eq 0 ]] && return 0
	apt_update_once
	apt-get install -y --no-install-recommends -o Dpkg::Options::=--force-confold "${missing[@]}"
}

APT_UPDATED=0
apt_update_once() {
	if [[ $APT_UPDATED -eq 0 ]]; then
		apt-get update -q
		APT_UPDATED=1
	fi
}

fetch() {
	local url=$1 dest=$2 sha=${3:-}
	if [[ -s "$dest" && -n "$sha" ]] && echo "$sha  $dest" | sha256sum -c --status; then
		return 0
	fi
	curl -fsSL --retry 5 --retry-delay 2 -o "$dest.part" "$url"
	if [[ -n "$sha" ]]; then
		echo "$sha  $dest.part" | sha256sum -c --status || die "checksum mismatch for $url"
	fi
	mv -f "$dest.part" "$dest"
}

render() {
	local src=$1 dest=$2 vars=$3 mode=${4:-0644} tmp
	tmp=$(mktemp "${dest}.XXXXXX")
	envsubst "$vars" <"$src" >"$tmp"
	chmod "$mode" "$tmp"
	if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
		rm -f "$tmp"
		return 1
	fi
	mv -f "$tmp" "$dest"
	return 0
}

install_file() {
	local src=$1 dest=$2 mode=${3:-0644}
	if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
		return 1
	fi
	install -D -m "$mode" "$src" "$dest"
	return 0
}

port_open() {
	ss -Hltn "sport = :$1" | grep -q .
}

wait_ports() {
	local timeout=$1 port deadline
	shift
	deadline=$((SECONDS + timeout))
	for port in "$@"; do
		until port_open "$port"; do
			((SECONDS < deadline)) || die "port $port not listening after ${timeout}s"
			sleep 1
		done
	done
}

all_ports_open() {
	local port
	for port in "$@"; do
		port_open "$port" || return 1
	done
}

register_services() {
	if [[ $# -eq 0 ]]; then
		: >"$BENCH_SERVICES_FILE.tmp"
	else
		printf '%s\n' "$@" >"$BENCH_SERVICES_FILE.tmp"
	fi
	mv -f "$BENCH_SERVICES_FILE.tmp" "$BENCH_SERVICES_FILE"
}

lab_ips() {
	local name
	for name in $(compgen -v BENCH_IP_); do
		printf '%s\n' "${!name}"
	done
}

load_host_ips() {
	local host var
	for host in ${BENCH_HOSTS_LOAD:-}; do
		var="BENCH_IP_$(tr '[:lower:]-' '[:upper:]_' <<<"$host")"
		if [[ -n ${!var:-} ]]; then
			printf '%s %s\n' "$host" "${!var}"
		fi
	done
}

use_dns_stub() {
	require_var BENCH_IP_SINK
	local conf
	conf=$(printf 'nameserver %s\noptions timeout:1 attempts:2\n' "$BENCH_IP_SINK")
	if systemctl is-enabled --quiet systemd-resolved 2>/dev/null; then
		systemctl disable --now systemd-resolved
	fi
	if [[ -L /etc/resolv.conf ]]; then
		rm -f /etc/resolv.conf
	fi
	if [[ "$(cat /etc/resolv.conf 2>/dev/null)" != "$conf" ]]; then
		printf "%s\n" "$conf" >/etc/resolv.conf
	fi
	local deadline=$((SECONDS + 300))
	until dig +short +time=1 +tries=1 MX "$BENCH_REMOTE_DOMAIN" | grep -q .; do
		((SECONDS < deadline)) || die "DNS stub at $BENCH_IP_SINK does not answer MX $BENCH_REMOTE_DOMAIN"
		sleep 2
	done
}

require_tls() {
	[[ -s $BENCH_TLS_DIR/cert.pem && -s $BENCH_TLS_DIR/key.pem ]] ||
		die "TLS material missing in $BENCH_TLS_DIR (provision/tls-gen.sh, uploaded by infra)"
}

sha512_crypt() {
	openssl passwd -6 -stdin
}
