#!/usr/bin/env bash
# Seed the dataset of a track on every target, settle and verify it.
#
#   scripts/seed.sh HOSTS.json [--step S]... [--again]
#
# Steps (each resumable, recorded in work/RUN/seed/):
#   accounts   mailbench accounts on the first load host; the list goes to /etc/bench/accounts.tsv on every target
#              host, where provision/ctl.sh accounts creates them natively
#   fill       mailbench seed --step mailboxes for every target in parallel, sliced across all load hosts
#              (--shard I/N); the accounts already exist from the previous step
#   settle     provision/ctl.sh settle on every server host (index queues drained, VACUUM ANALYZE, ...)
#   verify     mailbench verify per target; the reports land in results/TRACK/RUN/seed/
# BENCH_DATASET (default: the track) and BENCH_SEED (default: mailbench's) select the dataset; BENCH_SEED_ARGS adds
# arguments to "mailbench seed" (for example the active-set size of tracks M and L); BENCH_VERIFY_ARGS adds
# arguments to "mailbench verify" (for example --skip-large when the fill skipped the large accounts).

# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

STEPS="accounts fill settle verify"
AGAIN=0

dataset_args() {
  printf '%s\n' --dataset "${BENCH_DATASET:-$TRACK}"
  if [ -n "${BENCH_SEED:-}" ]; then printf '%s\n' --seed "$BENCH_SEED"; fi
}

target_seed_host() {
  local host
  host=$(target_host "$1")
  case "$host" in lb:*) host_names stalwart | head -1 ;; *) echo "$host" ;; esac
}

targets() { inv '.targets | keys[]'; }

step_accounts() {
  local load target host a args=()
  load=$(first_load)
  while read -r a; do args+=("$a"); done < <(dataset_args)
  job_run "$load" seed-accounts --again -- "$REMOTE/bin/mailbench" accounts "${args[@]}" --out "$REMOTE/out/accounts.tsv" \
    || die "mailbench accounts failed"
  rsync_from "$load" "$REMOTE/out/accounts.tsv" "$STATE/accounts.tsv"
  say "$(wc -l < "$STATE/accounts.tsv" | tr -d ' ') accounts"
  for target in $(targets); do
    host=$(target_seed_host "$target")
    rsync_to "$host" "$STATE/accounts.tsv" /tmp/accounts.tsv
    hssh "$host" "sudo -n install -m 0640 -o root -g $SSH_USER /tmp/accounts.tsv /etc/bench/accounts.tsv && rm -f /tmp/accounts.tsv"
    job_run "$host" accounts --sudo --again -- bash "$REMOTE/provision/ctl.sh" accounts /etc/bench/accounts.tsv \
      || die "$host: ctl.sh accounts failed"
  done
}

fill_target() {
  local target="$1" host i=0 n pids=() pid failed=0 a args=() extra=()
  n=$(load_hosts | wc -l | tr -d ' ')
  while read -r a; do args+=("$a"); done < <(dataset_args)
  # shellcheck disable=SC2206
  [ -n "${BENCH_SEED_ARGS:-}" ] && extra=(${BENCH_SEED_ARGS})
  for host in $(load_hosts); do
    job_run "$host" "seed-$target" --again -- "$REMOTE/bin/mailbench" seed "${args[@]}" --target "$target" --shard "$i/$n" --step mailboxes \
      ${extra[@]+"${extra[@]}"} &
    pids+=($!)
    i=$((i + 1))
  done
  for pid in "${pids[@]}"; do wait "$pid" || failed=1; done
  return "$failed"
}

step_fill() {
  # shellcheck disable=SC2046
  on_hosts fill_target $(targets)
}

settle_host() { job_run "$1" settle --sudo --again -- bash "$REMOTE/provision/ctl.sh" settle; }

step_settle() {
  # shellcheck disable=SC2046
  on_hosts settle_host $(server_hosts)
}

step_verify() {
  local load target bad="" a args=() extra=()
  load=$(first_load)
  while read -r a; do args+=("$a"); done < <(dataset_args)
  # shellcheck disable=SC2206
  [ -n "${BENCH_VERIFY_ARGS:-}" ] && extra=(${BENCH_VERIFY_ARGS})
  mkdir -p "$OUT/seed"
  for target in $(targets); do
    if ! job_run "$load" "verify-$target" --again -- "$REMOTE/bin/mailbench" verify "${args[@]}" --target "$target" \
        ${extra[@]+"${extra[@]}"} --out "$REMOTE/out/verify-$target.json"; then
      bad="$bad $target"
    fi
    rsync_from "$load" "$REMOTE/out/verify-$target.json" "$OUT/seed/" || true
  done
  [ -z "$bad" ] || die "verification failed for:$bad (reports in $OUT/seed)"
}

main() {
  local selected="" s
  [ $# -gt 0 ] || { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 2; }
  load_inventory "$1"; shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --step) selected="$selected ${2:?}"; shift 2 ;;
      --again) AGAIN=1; shift ;;
      *) die "unknown option $1" ;;
    esac
  done
  mkdir -p "$STATE/seed"
  for s in $STEPS; do
    if [ -n "$selected" ]; then case " $selected " in *" $s "*) ;; *) continue ;; esac; fi
    if [ "$AGAIN" = 0 ] && [ -f "$STATE/seed/$s.done" ]; then say "seed step $s already done"; continue; fi
    say "seed step $s"
    "step_$s"
    date -u +%FT%TZ > "$STATE/seed/$s.done"
  done
}

main "$@"
