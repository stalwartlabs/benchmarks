#!/usr/bin/env bash
# shellcheck disable=SC2034

CEPHADM=/usr/local/sbin/cephadm
CEPH_IMAGE=quay.io/ceph/ceph:v${CEPH_VERSION:-20.2.4}
CEPH_RGW_PORT=80
CEPH_RGW_SERVICE=bench
CEPH_UNIT=ceph.target
CEPH_KEY_PORT=8099
CEPH_S3_USER=bench

ceph_cmd() {
	"$CEPHADM" --image "$CEPH_IMAGE" shell -- "$@"
}

ceph_local_devices() {
	local sys model list
	if [[ -n ${NVME_DEVICES:-} ]]; then
		read -r -a list <<<"$NVME_DEVICES"
		printf '%s\n' "${list[@]}"
		return 0
	fi
	for sys in /sys/block/nvme*n*; do
		[[ -e $sys ]] || continue
		model=$(cat "$sys/device/model" 2>/dev/null || true)
		case $model in
		*"NVMe Direct Disk"* | *"Instance Storage"*) printf '/dev/%s\n' "${sys##*/}" ;;
		esac
	done
}

ceph_is_osd_device() {
	pvs --noheadings -o vg_name "$1" 2>/dev/null | grep -q 'ceph-'
}
