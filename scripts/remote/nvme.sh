#!/usr/bin/env bash
# Format and mount the local NVMe disks of the VM on $BENCH_DATA (default /mnt/data): XFS, noatime, mdadm RAID0
# when there are several. Run as root. Idempotent; prints one status line:
#   "nvme: mounted DEV"     the filesystem was already mounted
#   "nvme: remounted DEV"   an existing filesystem was mounted again (reboot)
#   "nvme: formatted DEV"   a new, empty filesystem was created (first boot, or the disks were wiped by a
#                           deallocation or host event: restore the snapshot)
# Local disks are recognised by model (Azure "NVMe Direct Disk", EC2 "Instance Storage"); NVME_DEVICES overrides.
set -euo pipefail

DATA="${BENCH_DATA:-/mnt/data}"
MD=/dev/md/benchdata

die() { echo "nvme: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root"

if mountpoint -q "$DATA"; then
  echo "nvme: mounted $(findmnt -n -o SOURCE "$DATA")"
  exit 0
fi

devices="${NVME_DEVICES:-}"
if [ -z "$devices" ]; then
  for sys in /sys/block/nvme*n*; do
    [ -e "$sys" ] || continue
    model=$(cat "$sys/device/model" 2> /dev/null || true)
    case "$model" in
      *"NVMe Direct Disk"*|*"Instance Storage"*) devices="$devices /dev/${sys##*/}" ;;
    esac
  done
fi
devices="${devices# }"
[ -n "$devices" ] || die "no local NVMe disk found (set NVME_DEVICES)"

for dev in $devices; do
  for mnt in $(lsblk -nro MOUNTPOINT "$dev" | grep -v '^$' || true); do
    umount "$mnt"
  done
done

# shellcheck disable=SC2086
set -- $devices
if [ $# -gt 1 ]; then
  command -v mdadm > /dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq mdadm > /dev/null
  if [ ! -e "$MD" ]; then
    mdadm --assemble "$MD" "$@" > /dev/null 2>&1 \
      || mdadm --create "$MD" --run --level=0 --raid-devices=$# --homehost=any "$@" > /dev/null
  fi
  dev="$MD"
else
  dev="$1"
fi

state=remounted
if [ "$(blkid -o value -s TYPE "$dev" 2> /dev/null || true)" != xfs ]; then
  mkfs.xfs -q -f "$dev"
  state=formatted
fi
mkdir -p "$DATA"
uuid=$(blkid -o value -s UUID "$dev")
sed -i "\\# $DATA #d" /etc/fstab
echo "UUID=$uuid $DATA xfs noatime,nofail,x-systemd.device-timeout=10s 0 2" >> /etc/fstab
systemctl daemon-reload
mount "$DATA"
[ "$state" = formatted ] && date -u +%FT%TZ > "$DATA/.bench-formatted"
echo "nvme: $state $dev $devices"
