#!/usr/bin/env bash
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/stage2.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/stage2.sh"
# shellcheck source=lib/ceph.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/ceph.sh"

require_root
require_var CEPH_VERSION CEPHADM_SHA256 BENCH_HOST BENCH_PRIVATE_IP
cd /
first=$(first_host_of ceph)
[[ "$(hostname -s)" == "$BENCH_HOST" ]] || die "hostname $(hostname -s) differs from the inventory name $BENCH_HOST; cephadm needs them equal"
apt_install ca-certificates curl jq podman catatonit lvm2 chrony python3 rclone gdisk

mkdir -p /var/cache/bench
fetch "https://download.ceph.com/rpm-${CEPH_VERSION}/el9/noarch/cephadm" "/var/cache/bench/cephadm-$CEPH_VERSION" "$CEPHADM_SHA256"
install_file "/var/cache/bench/cephadm-$CEPH_VERSION" "$CEPHADM" 0755 || true

mapfile -t devices < <(ceph_local_devices)
[[ ${#devices[@]} -gt 0 ]] || die "no local NVMe device found (set NVME_DEVICES)"
for dev in "${devices[@]}"; do
	ceph_is_osd_device "$dev" && continue
	while read -r mnt; do
		[[ -n $mnt ]] || continue
		if find "$mnt" -mindepth 1 -maxdepth 1 ! -name .bench-formatted ! -name lost+found | grep -q .; then
			die "$dev is mounted on $mnt and holds data; refusing to hand it to Ceph"
		fi
		umount "$mnt"
		sed -i "\\# $mnt #d" /etc/fstab
	done < <(lsblk -nro MOUNTPOINT "$dev")
	wipefs -a -q "$dev"
	sgdisk --zap-all "$dev" >/dev/null
	log "ceph: $dev wiped for an OSD"
done

key_dir=/var/lib/bench-ceph-key
key_mac() {
	{
		bench_secret ceph-ssh-key
		cat "$1"
	} | sha256sum | cut -d' ' -f1
}

fetch_key() {
	local url=$1 dir=$2
	curl -fsS --max-time 5 -o "$dir/ceph.pub" "$url/ceph.pub" &&
		curl -fsS --max-time 5 -o "$dir/ceph.pub.mac" "$url/ceph.pub.mac" &&
		[[ "$(cat "$dir/ceph.pub.mac")" == "$(key_mac "$dir/ceph.pub")" ]]
}

if [[ $BENCH_HOST != "$first" ]]; then
	first_ip=$(host_ip "$first")
	tmp=$(mktemp -d)
	if [[ ! -f /root/.ssh/.bench-ceph-key ]]; then
		wait_until "$BENCH_DEP_TIMEOUT" "the cephadm SSH key from $first" fetch_key "http://$first_ip:$CEPH_KEY_PORT" "$tmp"
		install -d -m 0700 /root/.ssh
		grep -qxF "$(cat "$tmp/ceph.pub")" /root/.ssh/authorized_keys 2>/dev/null || cat "$tmp/ceph.pub" >>/root/.ssh/authorized_keys
		chmod 0600 /root/.ssh/authorized_keys
		touch /root/.ssh/.bench-ceph-key
	fi
	rm -rf "$tmp"
	wait_until "$BENCH_DEP_TIMEOUT" "the RGW daemon on this host" tcp_open 127.0.0.1 "$CEPH_RGW_PORT"
	wait_until "$BENCH_DEP_TIMEOUT" "bucket $BENCH_S3_BUCKET through the local RGW" \
		s3_bucket_exists "http://127.0.0.1:$CEPH_RGW_PORT" "$(s3_region ceph)"
	add_services "$CEPH_UNIT"
	log "ceph ready on $BENCH_HOST (RGW on :$CEPH_RGW_PORT)"
	exit 0
fi

if [[ ! -s /etc/ceph/ceph.conf ]]; then
	"$CEPHADM" --image "$CEPH_IMAGE" bootstrap --mon-ip "$BENCH_PRIVATE_IP" --skip-dashboard --skip-monitoring-stack \
		--allow-fqdn-hostname --output-dir /etc/ceph
fi
install -d -m 0755 "$key_dir"
cp -f /etc/ceph/ceph.pub "$key_dir/ceph.pub"
key_mac "$key_dir/ceph.pub" >"$key_dir/ceph.pub.mac"
python3 -m http.server "$CEPH_KEY_PORT" --bind "$BENCH_PRIVATE_IP" --directory "$key_dir" >/dev/null 2>&1 &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true' EXIT

for host in $(hosts_of ceph); do
	[[ $host == "$first" ]] && continue
	wait_until "$BENCH_DEP_TIMEOUT" "ceph orch host add $host" ceph_cmd ceph orch host add "$host" "$(host_ip "$host")"
done
kill "$server_pid" 2>/dev/null || true

ceph_cmd ceph config set global osd_pool_default_size 3
ceph_cmd ceph config set global osd_pool_default_min_size 2
ceph_cmd ceph orch apply osd --all-available-devices >/dev/null
want_osds=$(($(hosts_of ceph | wc -l) * ${#devices[@]}))
osds_up() {
	[[ "$(ceph_cmd ceph osd stat --format json | jq -r '.num_up_osds')" -ge $want_osds ]]
}
wait_until 1800 "$want_osds OSDs up" osds_up

if ! ceph_cmd ceph osd pool ls | grep -qx default.rgw.buckets.data; then
	ceph_cmd ceph osd pool create default.rgw.buckets.data --bulk
	ceph_cmd ceph osd pool application enable default.rgw.buckets.data rgw
fi
ceph_cmd ceph orch apply rgw "$CEPH_RGW_SERVICE" --placement='*' --port="$CEPH_RGW_PORT" >/dev/null
wait_until 900 "the RGW daemon on this host" tcp_open 127.0.0.1 "$CEPH_RGW_PORT"

access_key=$(s3_access_key)
if ! ceph_cmd radosgw-admin user info --uid="$CEPH_S3_USER" >/dev/null 2>&1; then
	ceph_cmd radosgw-admin user create --uid="$CEPH_S3_USER" --display-name="$CEPH_S3_USER" \
		--access-key="$access_key" --secret-key="$(s3_secret_key)" --max-buckets=0 >/dev/null
fi
endpoint=http://127.0.0.1:$CEPH_RGW_PORT
garage_lb=${BENCH_LB_S3_GARAGE:-}
if [[ -n $garage_lb ]]; then
	write_rclone_conf Ceph "$endpoint" "$(s3_region ceph)" "http://$garage_lb:3900" "$(s3_region garage)"
else
	write_rclone_conf Ceph "$endpoint" "$(s3_region ceph)"
fi
rclone_mkdir() {
	rclone --config /etc/bench/rclone.conf mkdir "src:$BENCH_S3_BUCKET"
}
wait_until 300 "bucket $BENCH_S3_BUCKET to be created" rclone_mkdir
wait_until 300 "bucket $BENCH_S3_BUCKET through the local RGW" s3_bucket_exists "$endpoint" "$(s3_region ceph)"

rgw_all_up() {
	local host
	for host in $(hosts_of ceph); do
		curl -fsS -o /dev/null --max-time 5 "http://$(host_ip "$host"):$CEPH_RGW_PORT/" || return 1
	done
}
health_ok() {
	local health
	health=$(ceph_cmd ceph health --format json)
	jq -e '.status == "HEALTH_OK"' <<<"$health" >/dev/null && return 0
	jq -e '.status == "HEALTH_WARN" and ((.checks | keys) - ["CEPHADM_FAILED_DAEMON"] | length) == 0' <<<"$health" >/dev/null &&
		rgw_all_up
}
ceph_cmd ceph orch ps --refresh >/dev/null 2>&1 || true
if ! wait_until_soft 300 health_ok; then
	log "WARNING: ceph is not HEALTH_OK: $(ceph_cmd ceph health detail | head -n 20)"
fi
add_services "$CEPH_UNIT"
log "ceph ready on $BENCH_HOST: $CEPH_IMAGE, $want_osds OSDs, RGW on every host"
