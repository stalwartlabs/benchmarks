#!/usr/bin/env bash
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_root
conf=$BENCH_ROOT/config/os

runtime_tuning() {
	local f dev iface max
	for f in /sys/kernel/mm/transparent_hugepage/enabled /sys/kernel/mm/transparent_hugepage/defrag; do
		if [[ -w $f ]]; then
			echo never >"$f"
		fi
	done
	for dev in /sys/block/nvme*n*; do
		if [[ -w $dev/queue/scheduler ]]; then
			echo none >"$dev/queue/scheduler"
		fi
	done
	for iface in /sys/class/net/*; do
		iface=${iface##*/}
		[[ -e /sys/class/net/$iface/device ]] || continue
		max=$(ethtool -g "$iface" 2>/dev/null | awk '/^Pre-set maximums/{p=1} p && /^RX:/{print $2; exit}' || true)
		if [[ $max =~ ^[0-9]+$ ]]; then
			ethtool -G "$iface" rx "$max" 2>/dev/null || log "NIC $iface: rx ring $max not settable"
		fi
	done
	bash "$BENCH_ROOT/provision/egress-guard.sh"
}

if [[ ${1:-} == --boot ]]; then
	runtime_tuning
	exit 0
fi

apt_install jq gettext-base dnsutils ethtool iptables sysstat curl ca-certificates xfsprogs numactl

for unit in unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer man-db.timer \
	fstrim.timer motd-news.timer update-notifier-download.timer update-notifier-motd.timer \
	logrotate.timer dpkg-db-backup.timer e2scrub_all.timer fwupd-refresh.timer \
	sysstat.service sysstat-collect.timer sysstat-summary.timer cron.service; do
	if systemctl list-unit-files "$unit" >/dev/null 2>&1; then
		systemctl disable --now "$unit" >/dev/null 2>&1 || true
	fi
done
for unit in systemd-tmpfiles-clean.timer mdcheck_start.timer mdcheck_continue.timer mdmonitor-oneshot.timer; do
	if systemctl list-unit-files "$unit" >/dev/null 2>&1; then
		systemctl mask --now "$unit" >/dev/null 2>&1 || true
	fi
done
if [[ -f /etc/waagent.conf ]] && grep -q '^Logs.Collect=y' /etc/waagent.conf; then
	sed -i 's/^Logs.Collect=y/Logs.Collect=n/' /etc/waagent.conf
	systemctl try-restart walinuxagent.service >/dev/null 2>&1 || true
fi
if [[ "$(timedatectl show -p Timezone --value 2>/dev/null)" != Etc/UTC ]]; then
	timedatectl set-timezone Etc/UTC
fi
if systemctl list-unit-files snapd.service >/dev/null 2>&1; then
	systemctl disable --now snapd.service snapd.socket >/dev/null 2>&1 || true
fi

if install_file "$conf/sysctl.conf" /etc/sysctl.d/90-bench.conf; then
	sysctl -q --system
fi
install_file "$conf/limits.conf" /etc/security/limits.d/90-bench.conf || true
if install_file "$conf/systemd-limits.conf" /etc/systemd/system.conf.d/90-bench.conf; then
	systemctl daemon-reexec
fi
if install_file "$conf/60-bench-nvme.rules" /etc/udev/rules.d/60-bench-nvme.rules; then
	udevadm control --reload
fi
if install_file "$conf/bench-host-tuning.service" /etc/systemd/system/bench-host-tuning.service; then
	systemctl daemon-reload
fi
systemctl enable bench-host-tuning.service >/dev/null 2>&1

if ! grep -qw "$(hostname)" /etc/hosts; then
	printf "127.0.1.1 %s\n" "$(hostname)" >>/etc/hosts
fi

runtime_tuning

grep -q 'EPYC 9V45' /proc/cpuinfo || log "WARNING: CPU is not an AMD EPYC 9V45: $(grep -m1 'model name' /proc/cpuinfo)"
log "os tuning applied: kernel $(uname -r), THP $(cat /sys/kernel/mm/transparent_hugepage/enabled)"
