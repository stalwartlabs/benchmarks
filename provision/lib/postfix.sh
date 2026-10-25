#!/usr/bin/env bash
# shellcheck disable=SC2034

POSTFIX_QUEUE=${BENCH_DATA}/postfix/spool
POSTFIX_DATA=${BENCH_DATA}/postfix/lib
POSTFIX_MAPS=${BENCH_DATA}/postfix
POSTFIX_TLS=/etc/postfix/tls
POSTFIX_PORTS=(25 465 587)

DOVECOT_DATA=${BENCH_DATA}/dovecot
DOVECOT_TLS=/etc/dovecot/tls
DOVECOT_USERS=${DOVECOT_DATA}/users
DOVECOT_VARIANT=/etc/dovecot/variant.conf
DOVECOT_PORTS=(993)

postfix_build_install() {
	require_var POSTFIX_VERSION POSTFIX_URL POSTFIX_SHA256
	if command -v postconf >/dev/null && [[ $(postconf -h mail_version 2>/dev/null) == "$POSTFIX_VERSION" ]] &&
		postconf -a | grep -qx dovecot; then
		return 0
	fi
	apt_install build-essential libssl-dev libdb-dev libicu-dev m4 pkg-config
	local build=/opt/bench/build tarball
	mkdir -p "$build"
	tarball=$build/postfix-${POSTFIX_VERSION}.tar.gz
	fetch "$POSTFIX_URL" "$tarball" "$POSTFIX_SHA256"
	rm -rf "$build/postfix-${POSTFIX_VERSION}"
	tar -xzf "$tarball" -C "$build"
	getent group postdrop >/dev/null || groupadd -r postdrop
	id postfix >/dev/null 2>&1 || useradd -r -U -M -d /nonexistent -s /usr/sbin/nologin postfix
	(
		cd "$build/postfix-${POSTFIX_VERSION}" || exit 1
		make makefiles CCARGS='-DUSE_TLS -DUSE_SASL_AUTH -DDEF_SERVER_SASL_TYPE=\"dovecot\" -DNO_NIS' AUXLIBS='-lssl -lcrypto'
		make -j"$(nproc)"
		sh postfix-install -non-interactive install_root=/
	) >&2
}
