#!/usr/bin/env bash
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/postfix.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/postfix.sh"

require_root
require_tls
conf=$BENCH_ROOT/config/postfix
vars='${POSTFIX_QUEUE} ${POSTFIX_DATA} ${POSTFIX_MAPS} ${BENCH_MAIL_HOSTNAME} ${BENCH_DOMAIN} ${TLS_CERT} ${TLS_KEY}'

if dpkg-query -W -f='${Status}' postfix 2>/dev/null | grep -q 'install ok installed'; then
	apt-get purge -y postfix
fi
apt_install ca-certificates curl dnsutils
postfix_build_install

install -d -m 0755 /etc/postfix "$POSTFIX_MAPS"
install -d -o root -g root -m 0755 "$POSTFIX_QUEUE"
install -d -o postfix -g postfix -m 0700 "$POSTFIX_DATA"
install -d -m 0700 "$POSTFIX_TLS"
install -m 0644 "$BENCH_TLS_DIR/cert.pem" "$POSTFIX_TLS/cert.pem"
install -m 0600 "$BENCH_TLS_DIR/key.pem" "$POSTFIX_TLS/key.pem"

export POSTFIX_QUEUE POSTFIX_DATA POSTFIX_MAPS BENCH_MAIL_HOSTNAME BENCH_DOMAIN
export TLS_CERT=$POSTFIX_TLS/cert.pem TLS_KEY=$POSTFIX_TLS/key.pem
changed=0
if render "$conf/main.cf" /etc/postfix/main.cf "$vars"; then
	changed=1
fi
for f in master.cf openssl.cnf; do
	if install_file "$conf/$f" "/etc/postfix/$f"; then
		changed=1
	fi
done
install_file "$conf/sender_login.regexp" /etc/postfix/sender_login.regexp || true
if render "$conf/postfix.service" /etc/systemd/system/postfix.service "$vars"; then
	systemctl daemon-reload
fi

if [[ ! -f $POSTFIX_MAPS/vmailbox ]]; then
	: >"$POSTFIX_MAPS/vmailbox"
fi
postmap "hash:$POSTFIX_MAPS/vmailbox"
touch /var/log/postfix.log
postfix set-permissions >/dev/null
postfix check

use_dns_stub

systemctl enable postfix.service >/dev/null 2>&1
if [[ $changed -eq 1 ]] || ! systemctl is-active --quiet postfix.service; then
	systemctl restart postfix.service
else
	systemctl reload postfix.service
fi
wait_ports 60 "${POSTFIX_PORTS[@]}"
register_services postfix.service
log "postfix ready: $(postconf -h mail_version)"
