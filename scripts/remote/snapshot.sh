#!/usr/bin/env bash
# Save or load this host's datasets to or from Azure Blob storage (run as root, as a detached job).
#
#   snapshot.sh save|load NAME BASE_URL SAS_FILE
#
# BASE_URL is the blob prefix for this host (https://ACCOUNT.blob.core.windows.net/CONTAINER/snapshots/RUN/NAME/HOST),
# SAS_FILE a file holding the container SAS token (deleted after use). The datasets come from
# "provision/ctl.sh datadirs", one "KIND PATH [ARGS]" per line:
#   dir PATH            the directory, services stopped: tar | zstd (RocksDB, mdbox, Postfix queue, ...)
#   pg PATH             pg_basebackup of the local server (tar format); load restores it into PATH, services stopped
#   fdb PATH            fdbbackup to file://PATH on this host, then that directory as for dir; load runs fdbrestore
#   bucket NAME         S3 bucket NAME (rclone remote "src" in /etc/bench/rclone.conf), copied object by object
#                       to and from BASE_URL/N-bucket-NAME/ with rclone (64 parallel transfers, checksummed)
# Each blob gets a .sha256 sidecar; load verifies it. Uses azcopy (installed on first use) with pipes, so no local
# staging space is needed.
set -euo pipefail

CTL=/opt/bench/provision/ctl.sh
mode="${1:?save|load}"; name="${2:?NAME}"; base="${3:?BASE_URL}"; sas_file="${4:?SAS_FILE}"
sas=$(cat "$sas_file"); rm -f "$sas_file"
export AZCOPY_LOG_LOCATION=/var/tmp/azcopy AZCOPY_JOB_PLAN_LOCATION=/var/tmp/azcopy

say() { echo "[$(date -u +%H:%M:%S)] snapshot: $*"; }

ensure_tools() {
  command -v zstd > /dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq zstd > /dev/null
  if ! command -v azcopy > /dev/null; then
    local tmp; tmp=$(mktemp -d)
    curl -fsSL --retry 5 https://aka.ms/downloadazcopy-v10-linux | tar -xz -C "$tmp" --strip-components=1
    install -m 0755 "$tmp/azcopy" /usr/local/bin/azcopy
    rm -rf "$tmp"
  fi
}

put() { azcopy copy "$base/$1?$sas" --from-to PipeBlob --block-size-mb 256 --log-level ERROR > /dev/null; }
get() { azcopy copy "$base/$1?$sas" --from-to BlobPipe --log-level ERROR; }

sum_file=/var/tmp/snapshot.sum

read_sum() {
  local i
  for i in $(seq 1 300); do
    if [ -s "$sum_file" ]; then cat "$sum_file"; return; fi
    sleep 0.2
  done
  echo "snapshot: checksum not available" >&2
  return 1
}

save_stream() {
  local blob="$1" sum
  rm -f "$sum_file"
  tee >(sha256sum | cut -d' ' -f1 > "$sum_file") | put "$blob"
  sum=$(read_sum)
  printf '%s\n' "$sum" | put "$blob.sha256"
  say "saved $blob ($sum)"
}

blob_container_path() {
  local rest="${base#https://*/}"
  echo "$rest"
}

bucket_copy() {
  command -v rclone > /dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq rclone > /dev/null
  RCLONE_AZUREBLOB_SAS_URL="${base%%/snapshots/*}?$sas" \
    rclone --config /etc/bench/rclone.conf copy "$1" "$2" --fast-list --transfers 64 --checkers 64 --stats 60s --stats-one-line
}

save_dir() { tar -C "$1" -cf - . | zstd -T0 -3 -q | save_stream "$2"; }

load_dir() {
  local path="$1" blob="$2" want
  mkdir -p "$path"
  find "$path" -mindepth 1 -delete
  want=$(get "$blob.sha256")
  rm -f "$sum_file"
  get "$blob" | tee >(sha256sum | cut -d' ' -f1 > "$sum_file") | zstd -d -q | tar -C "$path" -xf -
  [ "$(read_sum)" = "$want" ] || { echo "snapshot: $blob checksum mismatch" >&2; return 1; }
  say "loaded $blob into $path"
}

ensure_tools
i=0
stopped=0
while read -r kind path _; do
  [ -n "$kind" ] || continue
  i=$((i + 1)); blob="$i-$kind.tar.zst"
  case "$mode:$kind" in
    save:dir)
      [ "$stopped" = 1 ] || { bash "$CTL" stop; stopped=1; }
      save_dir "$path" "$blob" ;;
    load:dir|load:pg)
      [ "$stopped" = 1 ] || { bash "$CTL" stop; stopped=1; }
      load_dir "$path" "$blob" ;;
    save:pg)
      sudo -u postgres pg_basebackup -D - -Ft -X fetch -c fast | zstd -T0 -3 -q | save_stream "$blob" ;;
    save:fdb)
      rm -rf "$path"; mkdir -p "$path"; chown foundationdb: "$path" 2> /dev/null || true
      fdbbackup start -d "file://$path" -w -z
      save_dir "$path" "$blob"
      rm -rf "$path" ;;
    load:fdb)
      load_dir "$path" "$blob"
      fdbrestore start -r "file://$(find "$path" -maxdepth 1 -name 'backup-*' | head -1)" -w --dest-cluster-file /etc/foundationdb/fdb.cluster ;;
    save:bucket)
      bucket_copy "src:$path" ":azureblob:$(blob_container_path)/$i-bucket-$path"
      say "saved bucket $path" ;;
    load:bucket)
      bucket_copy ":azureblob:$(blob_container_path)/$i-bucket-$path" "src:$path"
      say "loaded bucket $path" ;;
    *) echo "snapshot: unknown kind $kind" >&2; exit 1 ;;
  esac
done < <(bash "$CTL" datadirs)
[ "$stopped" = 0 ] || bash "$CTL" start
say "$mode $name done ($i datasets)"
