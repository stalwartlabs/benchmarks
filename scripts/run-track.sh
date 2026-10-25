#!/usr/bin/env bash
# Run one track end to end on deployed VMs: prepare, binary, provision, seed, snapshot, bench, collect, report.
#
#   scripts/run-track.sh HOSTS.json [--phase P]... [--from P] [--again]
#
# HOSTS.json is the inventory from infra/azure/up.sh, infra/ec2/up.sh or any VMs listed in that format. Phases:
#   prepare    wait for SSH, copy provision/ config/ scenarios/ scripts/remote/ loadgen/ versions.env to /opt/bench,
#              write /etc/bench/bench.env and hosts.json, mount local NVMe, record host facts, check the CPU is
#              Zen 5 (EPYC 9V45; BENCH_CPU_MODEL overrides), measure RTT from every load host to every other host
#   binary     put the Stalwart binary on the Stalwart hosts: STALWART_BINARY (local path, optionally .gz) or
#              STALWART_BINARY_URL (downloaded on the VM); neither: provision builds STALWART_REF from source.
#              MAILBENCH_BINARY (local path) is copied to the load hosts the same way
#   provision  run each host's provision scripts in order (hosts in parallel)
#   seed       scripts/seed.sh
#   snapshot   scripts/snapshot.sh, when BENCH_BLOB_URL is set
#   bench      every cell of scenarios/TRACK in listing order, targets interleaved (A B per repetition), cold cells
#              after a cold-cache cycle on every server host, a cell's server variants right after its main runs
#              (variant applied, runs, reverted); cells whose p50 varies by more
#              than BENCH_CV_MAX (0.10) across repetitions are rerun up to BENCH_CV_RERUNS (1) times.
#              BENCH_SCENARIOS (default scenarios/TRACK, subdirectories included) limits the run to a directory
#              or file of the repo; BENCH_SCENARIO_PROFILE (a repo path, passed to "mailbench scenarios" and to
#              every "mailbench run") and BENCH_SCENARIO_GROUP (passed to the listing) select a reduced set and
#              one cluster's share of it. BENCH_DATASET, BENCH_SEED, BENCH_SAMPLES and BENCH_SMOKE=1 pass --dataset, --seed, --samples and
#              --smoke to mailbench (phase 2 smoke tests: BENCH_DATASET=tiny BENCH_SMOKE=1).
#              BENCH_CLIENT_QUICKACK=1 (diagnostic) adds a "quickack 1" /32 route to every server host on every load
#              host before the cells and removes it afterwards, checking that "ip route show" matches the saved copy
#              (scripts/remote/quickack.sh; route listings in OUT/quickack-HOST-on.txt and -off.txt). A later bench
#              without it removes routes left over by an interrupted diagnostic run first.
#              Quiet windows: no cell (warm-up plus measurement) may overlap Stalwart's daily maintenance
#              (BENCH_QUIET_JOBS, UTC "HH:MM ...", default "00:00 02:00 04:00"; empty disables). A window runs from
#              BENCH_QUIET_BEFORE (300) s before a job to BENCH_QUIET_AFTER (1800) s after it. A cell's length is
#              1.25 x its longest earlier run plus BENCH_QUIET_PAD (120) s, or BENCH_QUIET_CELL_MAX (1920) s before
#              its first run; a cell that would cross a window waits for its end (logged in quiet-waits.tsv)
#   collect    scripts/collect.sh
#   report     scripts/report.sh
#
# Every phase is resumable: finished phases are skipped (work/RUN/phases/), finished cells are skipped (their
# merged.json exists), and remote work runs as detached jobs that survive a dropped SSH session. --again reruns the
# selected phases (and provision scripts) even if they finished.

# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

PHASES="prepare binary provision seed snapshot bench collect report"
CV_MAX="${BENCH_CV_MAX:-0.10}"
CV_RERUNS="${BENCH_CV_RERUNS:-1}"
AGAIN=0
FAILED_CELLS=0

env_line() {
  local v="$2"
  printf "%s='%s'\n" "$1" "${v//\'/\'\\\'\'}"
}

host_env() {
  local host="$1" role name upper profile
  role=$(host_field "$host" role)
  profile=production; [ "$TRACK" = c ] && profile=fairness
  env_line BENCH_RUN "$RUN"
  env_line BENCH_TRACK "$TRACK"
  env_line BENCH_HOST "$host"
  env_line BENCH_ROLE "$role"
  env_line BENCH_PRIVATE_IP "$(host_ip "$host")"
  env_line BENCH_PROFILE "${BENCH_PROFILE:-$profile}"
  env_line BENCH_DOMAIN "${BENCH_DOMAIN:-example.org}"
  env_line BENCH_REMOTE_DOMAIN "${BENCH_REMOTE_DOMAIN:-example.net}"
  env_line BENCH_DATA /mnt/data
  for name in $(host_names); do
    upper=$(printf '%s' "$name" | tr 'a-z-' 'A-Z_')
    env_line "BENCH_IP_$upper" "$(host_ip "$name")"
  done
  for role in $(inv '[.hosts[].role] | unique[]'); do
    upper=$(printf '%s' "$role" | tr 'a-z-' 'A-Z_')
    env_line "BENCH_HOSTS_$upper" "$(host_names "$role" | tr '\n' ' ' | sed 's/ $//')"
  done
  inv '.lbs[]? | "\(.name) \(.ip)"' | while read -r name ip; do
    env_line "BENCH_LB_$(printf '%s' "$name" | tr 'a-z-' 'A-Z_')" "$ip"
  done
  role=$(host_field "$host" role)
  if [ "$role" = stalwart ] || [ "$role" = load ]; then env_line BENCH_ADMIN_PASSWORD "$(admin_password)"; fi
  if [ "$role" = stalwart ]; then
    if [ -n "${STALWART_BINARY:-}" ] || [ -n "${STALWART_BINARY_URL:-}" ]; then env_line STALWART_BINARY "$REMOTE/bin/stalwart"; fi
    if [ -n "${STALWART_REF:-}" ]; then env_line STALWART_REF "$STALWART_REF"; fi
    if [ -n "${STALWART_LICENSE_KEY:-}" ]; then env_line STALWART_LICENSE_KEY "$STALWART_LICENSE_KEY"; fi
  fi
  if { [ "$role" = load ] || [ "$role" = sink ]; } && [ -n "${MAILBENCH_BINARY:-}" ]; then env_line MAILBENCH_BINARY "$REMOTE/bin/mailbench"; fi
  if [ -n "${BENCH_ENV_EXTRA:-}" ] && [ -f "$BENCH_ENV_EXTRA" ]; then grep -E "^[A-Z_][A-Z0-9_]*='" "$BENCH_ENV_EXTRA" || true; fi
}

admin_password() {
  local f="$STATE/admin-password"
  if [ ! -s "$f" ]; then
    (umask 077; LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32 > "$f")
  fi
  cat "$f"
}

tls_material() {
  [ -f "$REPO/provision/tls-gen.sh" ] || { say "provision/tls-gen.sh missing: no TLS material"; return 0; }
  bash "$REPO/provision/tls-gen.sh" "$STATE/tls" > /dev/null || die "provision/tls-gen.sh failed"
  local f
  for f in cert.pem key.pem ca.pem; do [ -s "$STATE/tls/$f" ] || die "tls-gen.sh did not write $STATE/tls/$f"; done
}

prepare_host() {
  local host="$1" i dir state
  for i in $(seq 1 60); do
    hssh "$host" true 2> /dev/null && break
    [ "$i" = 60 ] && die "$host: no SSH after 10 minutes"
    sleep 10
  done
  hssh "$host" "sudo -n mkdir -p $REMOTE /etc/bench && sudo -n chown $SSH_USER: $REMOTE && mkdir -p $REMOTE/bin $REMOTE/out $REMOTE/jobs"
  for dir in provision config scenarios; do
    if [ -d "$REPO/$dir" ]; then rsync_to "$host" "$REPO/$dir/" "$REMOTE/$dir/" --delete; fi
  done
  case "$(host_field "$host" role)" in
    load|sink) if [ -d "$REPO/loadgen" ]; then rsync_to "$host" "$REPO/loadgen/" "$REMOTE/loadgen/" --delete --exclude /target/; fi ;;
  esac
  hssh "$host" "mkdir -p $REMOTE/scripts"
  rsync_to "$host" "$REPO/scripts/remote/" "$REMOTE/scripts/remote/" --delete
  if [ -f "$REPO/versions.env" ]; then rsync_to "$host" "$REPO/versions.env" "$REMOTE/versions.env"; fi
  mkdir -p "$STATE/env"
  host_env "$host" > "$STATE/env/$host.env"
  rsync_to "$host" "$STATE/env/$host.env" "/tmp/bench.env"
  jq 'del(.ssh) | .hosts |= map(del(.public_ip))' "$HOSTS" > "$STATE/env/hosts.json"
  rsync_to "$host" "$STATE/env/hosts.json" "/tmp/hosts.json"
  hssh "$host" "sudo -n install -m 0640 -o root -g $SSH_USER /tmp/bench.env /etc/bench/bench.env && sudo -n install -m 0644 /tmp/hosts.json /etc/bench/hosts.json && rm -f /tmp/bench.env /tmp/hosts.json"
  if [ -s "$STATE/tls/cert.pem" ]; then
    rsync_to "$host" "$STATE/tls/" /tmp/bench-tls/
    hssh "$host" "sudo -n install -d -m 0755 /etc/bench/tls && sudo -n install -m 0644 /tmp/bench-tls/cert.pem /tmp/bench-tls/ca.pem /etc/bench/tls/ && sudo -n install -m 0600 /tmp/bench-tls/key.pem /etc/bench/tls/key.pem && rm -rf /tmp/bench-tls"
  fi
  if [ "$(host_field "$host" nvme)" = true ]; then
    job_run "$host" nvme --sudo --again -- bash "$REMOTE/scripts/remote/nvme.sh"
    state=$(hssh "$host" "$JOB log nvme 1")
    say "$host: $state"
    case "$state" in
      "nvme: formatted"*)
        if phase_done seed; then
          echo "$host" >> "$STATE/wiped"
          say "WARNING: $host lost its local NVMe data after seeding; run scripts/restore.sh before bench"
        fi ;;
    esac
  fi
  mkdir -p "$OUT/hosts"
  hssh "$host" "bash $REMOTE/scripts/remote/hostinfo.sh" > "$OUT/hosts/$host.json"
}

check_cpu() {
  local want="${BENCH_CPU_MODEL:-9V45}" host model bad=""
  for host in $(host_names); do
    model=$(jq -r .cpu_model "$OUT/hosts/$host.json")
    case "$model" in *"$want"*) ;; *) bad="$bad $host($model)" ;; esac
  done
  [ -z "$bad" ] || die "CPU model check failed (want $want):$bad"
}

RTT_PORT="${BENCH_RTT_PORT:-47999}"

rtt_serve() { hssh "$1" "$JOB start rtt-serve --again -- bash $REMOTE/scripts/remote/rtt.sh serve $RTT_PORT 600" > /dev/null; }

rtt_host() {
  local host="$1" targets=() name
  for name in $(host_names); do
    [ "$name" = "$host" ] || targets+=("$name=$(host_ip "$name")")
  done
  job_run "$host" rtt --again -- bash "$REMOTE/scripts/remote/rtt.sh" probe "$RTT_PORT" "${targets[@]}"
  hssh "$host" "cat $REMOTE/jobs/rtt/log" > "$STATE/rtt-$host.jsonl"
}

phase_prepare() {
  tls_material
  # shellcheck disable=SC2046
  on_hosts prepare_host $(host_names)
  check_cpu
  # shellcheck disable=SC2046
  on_hosts rtt_serve $(host_names)
  sleep 2
  rm -f "$STATE"/rtt-*.jsonl
  # shellcheck disable=SC2046
  on_hosts rtt_host $(host_names)
  cat "$STATE"/rtt-*.jsonl | jq -s . > "$OUT/rtt.json"
  for name in $(host_names); do hssh "$name" "$JOB stop rtt-serve" || true; done
}

put_binary() {
  local host="$1" local_path="$2" url="$3" name="$4"
  if [ -n "$local_path" ]; then
    case "$local_path" in
      *.gz) rsync_to "$host" "$local_path" "$REMOTE/bin/$name.gz"
            hssh "$host" "gzip -dc $REMOTE/bin/$name.gz > $REMOTE/bin/$name.new && mv $REMOTE/bin/$name.new $REMOTE/bin/$name && rm -f $REMOTE/bin/$name.gz" ;;
      *) rsync_to "$host" "$local_path" "$REMOTE/bin/$name" ;;
    esac
  else
    (umask 077; printf 'url = "%s"\n' "$url" > "$STATE/.url.$host.$name")
    rsync_to "$host" "$STATE/.url.$host.$name" "$REMOTE/bin/.$name.curl"
    rm -f "$STATE/.url.$host.$name"
    job_run "$host" "fetch-$name" --again -- bash -c \
      'set -euo pipefail; curl -fsS --retry 5 -K "$1" -o "$2.dl"; rm -f "$1"; if gzip -t "$2.dl" 2>/dev/null; then gzip -dc "$2.dl" > "$2"; rm "$2.dl"; else mv "$2.dl" "$2"; fi' \
      fetch "$REMOTE/bin/.$name.curl" "$REMOTE/bin/$name"
  fi
  hssh "$host" "chmod 755 $REMOTE/bin/$name && sha256sum $REMOTE/bin/$name" | awk -v h="$host" '{print h, $1}'
}

stalwart_put() { put_binary "$1" "${STALWART_BINARY:-}" "${STALWART_BINARY_URL:-}" stalwart; }
mailbench_put() { put_binary "$1" "$MAILBENCH_BINARY" "" mailbench; }

phase_binary() {
  if [ -n "${STALWART_BINARY:-}" ] || [ -n "${STALWART_BINARY_URL:-}" ]; then
    [ -z "${STALWART_BINARY:-}" ] || [ -f "$STALWART_BINARY" ] || die "STALWART_BINARY $STALWART_BINARY not found"
    # shellcheck disable=SC2046
    on_hosts stalwart_put $(host_names stalwart) > "$STATE/stalwart.sha256"
    [ "$(awk '{print $2}' "$STATE/stalwart.sha256" | sort -u | wc -l | tr -d ' ')" = 1 ] || die "Stalwart hosts got different binaries"
    say "stalwart sha256 $(awk '{print $2; exit}' "$STATE/stalwart.sha256")"
  else
    say "no STALWART_BINARY or STALWART_BINARY_URL: provision builds STALWART_REF (${STALWART_REF:-from versions.env})"
  fi
  if [ -n "${MAILBENCH_BINARY:-}" ]; then
    # shellcheck disable=SC2046
    on_hosts mailbench_put $(load_hosts) $(host_names sink) > "$STATE/mailbench.sha256"
  fi
}

provision_host() {
  local host="$1" script again=()
  [ "$AGAIN" = 1 ] && again=(--again)
  for script in $(inv --arg n "$host" '.hosts[] | select(.name == $n) | .provision[]'); do
    [ -f "$REPO/provision/$script.sh" ] || die "provision/$script.sh does not exist"
    say "$host: provision $script"
    job_run "$host" "provision-$script" --sudo ${again[@]+"${again[@]}"} -- bash "$REMOTE/provision/$script.sh" \
      || die "$host: provision/$script.sh failed"
  done
}

phase_provision() {
  # shellcheck disable=SC2046
  on_hosts provision_host $(host_names sink)
  # shellcheck disable=SC2046
  on_hosts provision_host $(inv '.hosts[] | select(.role != "sink") | .name')
}

cell_servers() {
  local host
  host=$(target_host "$1")
  case "$host" in
    lb:*) server_hosts ;;
    *) echo "$host" ;;
  esac
}

drain_host() { job_run "$1" drain --sudo --again --timeout 3600 -- bash "$REMOTE/provision/ctl.sh" drain 3600; }
cold_host() { job_run "$1" cold --sudo --again --timeout 900 -- bash "$REMOTE/scripts/remote/cold.sh"; }

run_extra_args() {
  EXTRA=()
  if [ -n "${BENCH_DATASET:-}" ]; then EXTRA+=(--dataset "$BENCH_DATASET"); fi
  if [ -n "${BENCH_SEED:-}" ]; then EXTRA+=(--seed "$BENCH_SEED"); fi
  if [ "${BENCH_SMOKE:-0}" = 1 ]; then EXTRA+=(--smoke); fi
  if [ -n "${BENCH_SAMPLES:-}" ]; then EXTRA+=(--samples "$BENCH_SAMPLES"); fi
  if [ -n "$1" ]; then EXTRA+=(--variant "$1"); fi
  if [ -n "${BENCH_SCENARIO_PROFILE:-}" ]; then EXTRA+=(--profile "$REMOTE/$BENCH_SCENARIO_PROFILE"); fi
}

vmstat_start() { hssh "$1" "bash $REMOTE/scripts/remote/vmstat.sh start $CELL_FLAT"; }

vmstat_stop() {
  hssh "$1" "bash $REMOTE/scripts/remote/vmstat.sh stop $CELL_FLAT" || true
  rsync_from "$1" "$REMOTE/out/vmstat/$CELL_FLAT.log" "$CELL_DIR/vmstat-$1.log"
}

QUIET_JOBS="${BENCH_QUIET_JOBS-00:00 02:00 04:00}"
QUIET_BEFORE="${BENCH_QUIET_BEFORE:-300}"
QUIET_AFTER="${BENCH_QUIET_AFTER:-1800}"
QUIET_CELL_MAX="${BENCH_QUIET_CELL_MAX:-1920}"
QUIET_PAD="${BENCH_QUIET_PAD:-120}"

clock() { echo $(($(date +%s) + ${BENCH_CLOCK_OFFSET:-0})); }

epoch_utc() { jq -rn --argjson t "$1" '$t | todate'; }

quiet_until() {
  local now="$1" end="$2" midnight job h m d start stop until=0
  midnight=$((now - now % 86400))
  for job in $QUIET_JOBS; do
    h="${job%%:*}"; m="${job#*:}"
    for d in -1 0 1 2; do
      start=$((midnight + d * 86400 + 10#$h * 3600 + 10#$m * 60 - QUIET_BEFORE))
      stop=$((start + QUIET_BEFORE + QUIET_AFTER))
      if [ "$now" -lt "$stop" ] && [ "$end" -gt "$start" ] && { [ "$until" = 0 ] || [ "$stop" -lt "$until" ]; }; then
        until="$stop"
      fi
    done
  done
  echo "$until"
}

cell_estimate() {
  local files=() f
  for f in "$OUT/cells/$1"/*/rep*/merged.json "$OUT/cells/$1"/attempt*/*/rep*/merged.json; do
    if [ -f "$f" ]; then files+=("$f"); fi
  done
  if [ "${#files[@]}" = 0 ]; then echo "$QUIET_CELL_MAX"; return 0; fi
  jq -s --argjson pad "$QUIET_PAD" 'map(.finished_at_ms - .started_at_ms) | max / 1000 * 1.25 + $pad | ceil' "${files[@]}"
}

quiet_wait() {
  local key="$1" est="$2" now until
  while :; do
    now=$(clock)
    until=$(quiet_until "$now" $((now + est)))
    [ "$until" = 0 ] && return 0
    say "cell $key: an expected ${est}s run would overlap a maintenance window; waiting until $(epoch_utc "$until")"
    printf '%s\t%s\t%s\t%s\n' "$(epoch_utc "$now")" "$key" "$est" "$(epoch_utc "$until")" >> "$OUT/quiet-waits.tsv"
    sleep $((until - now))
  done
}

run_cell() {
  local cell="$1" target="$2" variant="$3" rep="$4" label key flat dir cache nload loads=() servers host i start_at=-1 rcs rc=0 pids=() shards=() code errs
  local est now
  label="$target"; [ -n "$variant" ] && label="$target+$variant"
  key="$cell/$label/rep$rep"; flat=$(printf '%s' "$key" | tr '/+' '__'); dir="$OUT/cells/$key"
  [ -f "$dir/merged.json" ] && return 0
  cache=$(jq -r --arg c "$cell" '.[] | select(.id == $c) | .cache // "warm"' "$STATE/cells.json")
  nload=$(jq -r --arg c "$cell" '.[] | select(.id == $c) | .load_hosts // 1' "$STATE/cells.json")
  if [ "$nload" = all ]; then
    while read -r host; do loads+=("$host"); done < <(load_hosts)
  else
    while read -r host; do loads+=("$host"); done < <(load_hosts | head -n "$nload")
  fi
  servers=$(server_hosts | tr '\n' ' ')
  CELL_FLAT="$flat"; CELL_DIR="$dir"
  mkdir -p "$dir"
  if [ "$(hssh "${loads[0]}" "$JOB status cell-$flat")" = running ]; then
    say "cell $key: reattaching to the running job"
    start_at=0
  else
    say "cell $key ($cache, ${#loads[@]} load hosts)"
    est=$(cell_estimate "$cell")
    while :; do
      quiet_wait "$key" "$est"
      # shellcheck disable=SC2086
      on_hosts drain_host $servers || { say "drain failed before $key"; return 1; }
      if [ "$cache" = cold ]; then
        # shellcheck disable=SC2086
        on_hosts cold_host $servers || { say "cold-cache cycle failed before $key"; return 1; }
      fi
      now=$(clock)
      [ "$(quiet_until "$now" $((now + est)))" = 0 ] && break
    done
    # shellcheck disable=SC2086
    on_hosts vmstat_start $servers "${loads[@]}" || true
  fi
  [ "$start_at" = 0 ] || start_at=$(( ($(date +%s) + ${BENCH_START_DELAY:-$((3 + 2 * ${#loads[@]}))}) * 1000 ))
  run_extra_args "$variant"
  i=0
  for host in "${loads[@]}"; do
    job_run "$host" "cell-$flat" --again -- "$REMOTE/bin/mailbench" run \
      --scenario "$REMOTE/$(jq -r --arg c "$cell" '.[] | select(.id == $c) | .file' "$STATE/cells.json")" \
      --cell "$cell" --target "$target" --shard "$i/${#loads[@]}" --start-at "$start_at" \
      ${EXTRA[@]+"${EXTRA[@]}"} --out "$REMOTE/out/cells/$key/$host.json" > /dev/null &
    pids+=($!)
    i=$((i + 1))
  done
  rcs=""
  for i in "${pids[@]}"; do
    code=0; wait "$i" || code=$?
    rcs="$rcs $code"
  done
  # shellcheck disable=SC2086
  on_hosts vmstat_stop $servers "${loads[@]}" || true
  for i in $rcs; do
    case "$i" in 0) ;; 3) [ "$rc" = 0 ] && rc=3 ;; *) rc="$i" ;; esac
  done
  for host in "${loads[@]}"; do rsync_from "$host" "$REMOTE/out/cells/$key/$host.json" "$dir/" || rc=1; done
  jq -n --arg cell "$cell" --arg target "$target" --arg variant "$variant" --argjson rep "$rep" --arg cache "$cache" \
    --arg loads "${loads[*]}" --arg servers "$servers" --argjson rc "$rc" --arg at "$start_at" \
    '{cell: $cell, target: $target, variant: $variant, rep: $rep, cache: $cache, rc: $rc, valid: ($rc == 0),
      start_at_ms: (($at | tonumber) as $t | if $t > 0 then $t else null end), reattached: ($at == "0"), load_hosts: ($loads | split(" ")), server_hosts: ($servers | split(" ") | map(select(. != "")))}' \
    > "$dir/meta.json"
  case "$rc" in 0|3) ;; *) say "cell $key failed (rc $rc)"; return 1 ;; esac
  if [ "${#loads[@]}" = 1 ]; then
    cp "$dir/${loads[0]}.json" "$dir/merged.json.tmp"
  else
    shards=()
    for host in "${loads[@]}"; do
      shards+=("$REMOTE/out/cells/$key/$host.json")
      [ "$host" = "${loads[0]}" ] || rsync_to "${loads[0]}" "$dir/$host.json" "$REMOTE/out/cells/$key/"
    done
    code=0
    job_run "${loads[0]}" "merge-$flat" --again -- "$REMOTE/bin/mailbench" merge "${shards[@]}" \
      --out "$REMOTE/out/cells/$key/merged.json" || code=$?
    case "$code" in 0|3) ;; *) return 1 ;; esac
    rsync_from "${loads[0]}" "$REMOTE/out/cells/$key/merged.json" "$dir/merged.json.tmp" || return 1
  fi
  mv "$dir/merged.json.tmp" "$dir/merged.json"
  [ "$rc" = 3 ] && say "cell $key completed but is INVALID (load generator bottleneck)"
  errs=$(jq -r '[(if .steps then (.steps[.best_step // 0] // .steps[0]).ops else .ops end // {}) | to_entries[]
    | select((.value.errors // 0) > 0) | "\(.key)=\(.value.errors)"] | join(" ")' "$dir/merged.json" 2> /dev/null || true)
  [ -z "$errs" ] || say "cell $key has operation errors: $errs (scripts/check-errors.sh $OUT)"
  return 0
}

is_variant_label() { case "$1" in *+*) return 0 ;; *) return 1 ;; esac; }

cell_cv() {
  local cell="$1" mode="$2" f label
  for f in "$OUT/cells/$cell"/*/rep*/merged.json; do
    [ -f "$f" ] || continue
    label=$(basename "$(dirname "$(dirname "$f")")")
    if is_variant_label "$label"; then [ "$mode" = variant ] || continue; else [ "$mode" = main ] || continue; fi
    jq -c --arg t "$label" '{target: $t, ops: (if .steps then (.steps[.best_step // 0] // .steps[0]).ops else .ops end // {} | map_values(.p50))}' "$f"
  done | jq -s '
      group_by(.target) | map({target: .[0].target, n: length,
        cv: ([.[].ops | to_entries[]] | group_by(.key) | map(map(.value) | select(length > 1)
             | (add / length) as $m | if $m > 0 then ((map(. - $m | . * .) | add / length) | sqrt) / $m else 0 end) | max // 0)})'
}

run_cell_matrix() {
  local cell="$1" variant_pairs="$2" reps targets target rep attempt cv pair mode=main label ran
  [ -n "$variant_pairs" ] && mode=variant
  reps=$(jq -r --arg c "$cell" '.[] | select(.id == $c) | .repetitions // 3' "$STATE/cells.json")
  targets=$(jq -r --arg c "$cell" '.[] | select(.id == $c) | .targets[]' "$STATE/cells.json")
  [ -n "$variant_pairs" ] || [ -n "$targets" ] || return 0
  attempt=0
  for label in "$OUT/cells/$cell"/attempt*-"$mode"; do [ -d "$label" ] && attempt=$((attempt + 1)); done
  while :; do
    for rep in $(seq 1 "$reps"); do
      if [ -z "$variant_pairs" ]; then
        for target in $targets; do
          ran=1; [ -f "$OUT/cells/$cell/$target/rep$rep/merged.json" ] && ran=0
          run_cell "$cell" "$target" "" "$rep" || FAILED_CELLS=$((FAILED_CELLS + 1))
          cleanup_after "$cell" "$target" "$target" "$rep" "$ran"
        done
      else
        for pair in $variant_pairs; do
          ran=1; [ -f "$OUT/cells/$cell/$pair/rep$rep/merged.json" ] && ran=0
          run_cell "$cell" "${pair%%+*}" "${pair#*+}" "$rep" || FAILED_CELLS=$((FAILED_CELLS + 1))
          cleanup_after "$cell" "${pair%%+*}" "$pair" "$rep" "$ran"
        done
      fi
    done
    [ "$reps" -gt 1 ] || return 0
    cv=$(cell_cv "$cell" "$mode")
    printf '%s\n' "$cv" > "$OUT/cells/$cell/cv-$mode.json"
    if ! jq -e --argjson max "$CV_MAX" 'any(.[]; .n > 1 and .cv > $max)' <<< "$cv" > /dev/null; then return 0; fi
    if [ "$attempt" -ge "$CV_RERUNS" ]; then
      say "cell $cell: repetition CV above $CV_MAX after $attempt reruns; flagged in cv-$mode.json"
      return 0
    fi
    attempt=$((attempt + 1))
    say "cell $cell: repetition CV above $CV_MAX, rerun $attempt"
    for target in "$OUT/cells/$cell"/*/; do
      label=$(basename "$target")
      case "$label" in attempt*) continue ;; esac
      if is_variant_label "$label"; then [ "$mode" = variant ] || continue; else [ "$mode" = main ] || continue; fi
      mkdir -p "$OUT/cells/$cell/attempt$attempt-$mode"
      mv "$target" "$OUT/cells/$cell/attempt$attempt-$mode/"
    done
  done
}

live_cell_jobs() {
  local host
  for host in $(load_hosts); do
    hssh "$host" "for d in \${BENCH_JOBS:-/opt/bench/jobs}/cell-*; do [ -d \"\$d\" ] || continue; [ \"\$($JOB status \"\${d##*/}\")\" = running ] && printf '%s ' \"$host:\${d##*/}\"; done; true" \
      || printf '%s ' "$host:unreachable"
  done
}

cleanup_after() {
  local cell="$1" target="$2" label="$3" rep="$4" ran="$5" host dataset attempt live f clean=1 waited=0 args=()
  case "$cell" in
    c01-1m-*|c02-1m-*|c03|c03-ext|c03-mpc10-ext|c15-*) ;;
    *) return 0 ;;
  esac
  [ -f "$OUT/cells/$cell/$label/rep$rep/cleaned" ] && return 0
  while live=$(live_cell_jobs); [ -n "$live" ]; do
    if [ "$ran" = 0 ]; then
      say "cell $cell: cleanup on $target deferred, cell jobs running: $live"
      return 0
    fi
    if [ "$waited" -ge "${BENCH_CLEANUP_WAIT:-3600}" ]; then
      say "WARNING: cleanup after $cell on $target skipped, cell jobs still running after ${waited}s: $live"
      return 0
    fi
    sleep "$BENCH_POLL"
    waited=$((waited + BENCH_POLL))
  done
  dataset="${BENCH_DATASET:-$(jq -r --arg c "$cell" '.[] | select(.id == $c) | .dataset' "$STATE/cells.json")}"
  args=(--dataset "$dataset")
  if [ -n "${BENCH_SEED:-}" ]; then args+=(--seed "$BENCH_SEED"); fi
  say "cell $cell: cleanup of load-test messages on $target"
  for attempt in 1 2 3; do
    for host in $(cell_servers "$target"); do drain_host "$host" || say "$host: drain before cleanup did not finish"; done
    if job_run "$(first_load)" "cleanup-$target" --again --timeout 7200 -- "$REMOTE/bin/mailbench" cleanup "${args[@]}" \
        --target "$target" --skip-large; then
      break
    fi
    if [ "$attempt" = 3 ]; then
      say "WARNING: cleanup after $cell on $target failed 3 times (see the cleanup-$target job log)"
      clean=0
    else
      sleep 10
    fi
  done
  case "$target" in
    dovecot|postfix-dovecot)
      for host in $(cell_servers "$target"); do
        job_run "$host" purge --sudo --again --timeout 7200 -- doveadm purge -A \
          || { say "WARNING: doveadm purge -A on $host failed"; clean=0; }
      done ;;
  esac
  [ "$clean" = 1 ] || return 0
  for f in "$OUT"/cells/*/"$target"/rep*/merged.json "$OUT"/cells/*/"$target"+*/rep*/merged.json; do
    [ -f "$f" ] && : > "${f%/merged.json}/cleaned"
  done
  return 0
}

cell_complete() {
  local cell="$1" label="$2" reps rep
  reps=$(jq -r --arg c "$cell" '.[] | select(.id == $c) | .repetitions // 3' "$STATE/cells.json")
  for rep in $(seq 1 "$reps"); do [ -f "$OUT/cells/$cell/$label/rep$rep/merged.json" ] || return 1; done
}

set_variant() {
  local target="$1" variant="$2" host
  for host in $(cell_servers "$target"); do
    say "$host: variant $variant"
    job_run "$host" "variant-$variant" --sudo --again --timeout 1800 -- bash "$REMOTE/provision/ctl.sh" variant "$variant" \
      || die "$host: variant $variant failed"
  done
}

client_quickack() {
  local mode="$1" host name out ips=()
  for name in $(server_hosts); do ips+=("$(host_field "$name" private_ip)"); done
  for host in $(load_hosts); do
    rsync_to "$host" "$REPO/scripts/remote/quickack.sh" "$REMOTE/scripts/remote/quickack.sh" \
      || die "$host: copying quickack.sh failed"
    if [ "$mode" = on ]; then
      out=$(hssh "$host" "sudo -n bash $REMOTE/scripts/remote/quickack.sh on $(quote "${ips[@]}")") \
        || die "$host: quickack routes failed"
    else
      out=$(hssh "$host" "sudo -n bash $REMOTE/scripts/remote/quickack.sh off") \
        || die "$host: quickack routes not restored (see /opt/bench/quickack on the host)"
    fi
    if [ -n "$out" ]; then printf '%s\n' "$out" > "$OUT/quickack-$host-$mode.txt"; fi
    say "$host: client quickack $mode"
  done
}

quickack_restore() {
  client_quickack off
  rm -f "$STATE/quickack"
}

phase_bench() {
  local cell v live listing=()
  if [ "${BENCH_CLIENT_QUICKACK:-0}" = 1 ]; then
    case "$OUT" in *quickack*) ;; *) die "BENCH_CLIENT_QUICKACK=1 needs BENCH_OUT under results/c-quickack/, not $OUT" ;; esac
    printf '%s
' "Diagnostic run: load hosts used client-side TCP quickack (route quickack 1 to every server host)."       "Servers untouched. Not part of the main results; see quickack-*-on.txt and quickack-*-off.txt." > "$OUT/DIAGNOSTIC.txt"
    : > "$STATE/quickack"
    trap quickack_restore EXIT
    client_quickack on
  elif [ -f "$STATE/quickack" ]; then
    quickack_restore
  fi
  listing=(scenarios "$REMOTE/${BENCH_SCENARIOS:-scenarios/$TRACK}" --json)
  if [ -n "${BENCH_SCENARIO_PROFILE:-}" ]; then listing+=(--profile "$REMOTE/$BENCH_SCENARIO_PROFILE"); fi
  if [ -n "${BENCH_SCENARIO_GROUP:-}" ]; then listing+=(--group "$BENCH_SCENARIO_GROUP"); fi
  hssh "$(first_load)" "$REMOTE/bin/mailbench $(quote "${listing[@]}")" > "$STATE/cells.json.tmp" \
    || die "mailbench scenarios failed"
  mv "$STATE/cells.json.tmp" "$STATE/cells.json"
  if [ -f "$OUT/cells.json" ]; then
    jq -s '(.[0] + .[1]) | group_by(.id) | map(.[-1])' "$OUT/cells.json" "$STATE/cells.json" > "$OUT/cells.json.tmp"
    mv "$OUT/cells.json.tmp" "$OUT/cells.json"
  else
    cp "$STATE/cells.json" "$OUT/cells.json"
  fi
  for cell in $(jq -r '.[].id' "$STATE/cells.json"); do
    run_cell_matrix "$cell" ""
    for v in $(jq -r --arg c "$cell" '.[] | select(.id == $c) | .variants[]? | "\(.target)+\(.name)"' "$STATE/cells.json"); do
      cell_complete "$cell" "$v" && continue
      live=$(live_cell_jobs)
      case "$live" in *:unreachable*) die "cannot check for live cell jobs before variant ${v#*+}: $live" ;; esac
      if [ -n "$live" ]; then
        say "cell $cell: variant ${v#*+} left as applied, cell jobs running: $live"
      else
        set_variant "${v%%+*}" "${v#*+}"
      fi
      run_cell_matrix "$cell" "$v"
      set_variant "${v%%+*}" default
    done
  done
  if [ "${BENCH_CLIENT_QUICKACK:-0}" = 1 ]; then
    trap - EXIT
    quickack_restore
  fi
  [ "$FAILED_CELLS" = 0 ] || die "$FAILED_CELLS cell runs failed; rerun the bench phase to retry them"
}

run_phase() {
  local p="$1"
  if [ "$AGAIN" = 0 ] && phase_done "$p"; then say "phase $p already done"; return 0; fi
  say "phase $p"
  case "$p" in
    prepare) phase_prepare ;;
    binary) phase_binary ;;
    provision) phase_provision ;;
    seed)
      if [ "$AGAIN" = 1 ]; then "$REPO/scripts/seed.sh" "$HOSTS" --again; else "$REPO/scripts/seed.sh" "$HOSTS"; fi ;;
    snapshot)
      if [ -z "${BENCH_BLOB_URL:-}" ]; then say "BENCH_BLOB_URL not set: no snapshot"; return 0; fi
      "$REPO/scripts/snapshot.sh" "$HOSTS" --name seeded ;;
    bench)
      [ ! -s "$STATE/wiped" ] || die "hosts lost their data ($(tr '\n' ' ' < "$STATE/wiped")); run scripts/restore.sh, then delete $STATE/wiped"
      phase_bench ;;
    collect) "$REPO/scripts/collect.sh" "$HOSTS" ;;
    report) "$REPO/scripts/report.sh" "$OUT" ;;
    *) die "unknown phase $p" ;;
  esac
  if [ "$p" = bench ] && [ -n "${BENCH_SCENARIOS:-}${BENCH_SCENARIO_GROUP:-}" ]; then return 0; fi
  mark_done "$p"
}

main() {
  local selected="" from="" p started=0
  [ $# -gt 0 ] || { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 2; }
  load_inventory "$1"; shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --phase) selected="$selected ${2:?}"; shift 2 ;;
      --from) from="${2:?}"; shift 2 ;;
      --again) AGAIN=1; shift ;;
      *) die "unknown option $1" ;;
    esac
  done
  need_tools
  for p in $PHASES; do
    if [ -n "$selected" ]; then
      case " $selected " in *" $p "*) run_phase "$p" ;; esac
      continue
    fi
    if [ -n "$from" ] && [ "$started" = 0 ]; then
      [ "$p" = "$from" ] || continue
      started=1
    fi
    run_phase "$p"
  done
  say "done: results in $OUT"
}

need_tools() {
  local t
  for t in jq ssh rsync; do command -v "$t" > /dev/null || die "$t is required"; done
}

main "$@"
