#!/usr/bin/env bash
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/postfix.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/postfix.sh"

require_root
require_tls
require_var DOVECOT_REPO DOVECOT_KEY_URL DOVECOT_KEY_FINGERPRINT DOVECOT_PKG_VERSION
conf=$BENCH_ROOT/config/dovecot
keyring=/usr/share/keyrings/dovecot.gpg

apt_install ca-certificates curl gpg ssl-cert
if [[ ! -s $keyring ]]; then
	curl -fsSL "$DOVECOT_KEY_URL" | gpg --dearmor -o "$keyring.tmp"
	fpr=$(gpg --show-keys --with-colons "$keyring.tmp" | awk -F: '/^fpr/{print $10; exit}')
	[[ $fpr == "$DOVECOT_KEY_FINGERPRINT" ]] || die "Dovecot repo key fingerprint $fpr does not match"
	mv -f "$keyring.tmp" "$keyring"
fi
src_line="deb [signed-by=$keyring] $DOVECOT_REPO noble main"
if [[ "$(cat /etc/apt/sources.list.d/dovecot.list 2>/dev/null)" != "$src_line" ]]; then
	printf '%s\n' "$src_line" >/etc/apt/sources.list.d/dovecot.list
	APT_UPDATED=0
fi
pkgs=(dovecot-core dovecot-imapd dovecot-lmtpd dovecot-flatcurve)
want=()
for pkg in "${pkgs[@]}"; do
	if [[ $(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null) != "$DOVECOT_PKG_VERSION" ]]; then
		want+=("$pkg=$DOVECOT_PKG_VERSION")
	fi
done
if [[ ${#want[@]} -gt 0 ]]; then
	apt_update_once
	apt-get install -y --no-install-recommends --allow-downgrades -o Dpkg::Options::=--force-confold "${want[@]}"
	apt-mark hold "${pkgs[@]}" >/dev/null
fi

id vmail >/dev/null 2>&1 || useradd -r -U -M -d /nonexistent -s /usr/sbin/nologin vmail
install -d -m 0755 "$DOVECOT_DATA"
install -d -o vmail -g vmail -m 0750 "$DOVECOT_DATA/mail"
install -d -m 0700 "$DOVECOT_TLS"
install -m 0644 "$BENCH_TLS_DIR/cert.pem" "$DOVECOT_TLS/cert.pem"
install -m 0600 "$BENCH_TLS_DIR/key.pem" "$DOVECOT_TLS/key.pem"
if [[ ! -f $DOVECOT_USERS ]]; then
	install -m 0640 -g dovecot /dev/null "$DOVECOT_USERS"
fi
if [[ ! -f $DOVECOT_VARIANT ]]; then
	: >"$DOVECOT_VARIANT"
fi
[[ -d $POSTFIX_QUEUE/private ]] || die "$POSTFIX_QUEUE/private missing: run postfix.sh first"

export DOVECOT_DATA DOVECOT_TLS POSTFIX_QUEUE
changed=0
if render "$conf/dovecot.conf" /etc/dovecot/dovecot.conf '${DOVECOT_DATA} ${DOVECOT_TLS} ${POSTFIX_QUEUE}'; then
	changed=1
fi
doveconf -n >/dev/null

systemctl enable dovecot.service >/dev/null 2>&1
if [[ $changed -eq 1 ]] || ! systemctl is-active --quiet dovecot.service; then
	systemctl restart dovecot.service
fi
wait_ports 60 "${DOVECOT_PORTS[@]}"
deadline=$((SECONDS + 60))
until [[ -S $POSTFIX_QUEUE/private/dovecot-lmtp && -S $POSTFIX_QUEUE/private/auth ]]; do
	((SECONDS < deadline)) || die "dovecot LMTP/auth sockets not created in $POSTFIX_QUEUE/private"
	sleep 1
done
register_services dovecot.service postfix.service
log "dovecot ready: $(dovecot --version)"
