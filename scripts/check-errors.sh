#!/usr/bin/env bash
# List every cell run whose result has operation errors.
#
#   scripts/check-errors.sh RESULTS_DIR... [--all-steps]
#
# Scans RESULTS_DIR (for example results/c/bench-c6-1025) for cells/CELL/LABEL/repN/merged.json and prints one line
# per run with errors: cell, target label, repetition, step, then label=errors (error kinds) and the first error sample.
# By default only the reported step is checked (latency cells: their only step; throughput cells: every step up to
# and including best_step, or step 0 when no step met the SLO), because ladder steps past the SLO are expected to
# fail. --all-steps checks every step. Exit status: 0 when no errors were found, 1 when some were, 2 on bad usage.
set -euo pipefail

[ $# -gt 0 ] || { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 2; }
command -v python3 > /dev/null || { echo "check-errors.sh: python3 is required" >&2; exit 2; }
exec python3 -I - "$@" <<'PY'
import json, os, sys

def steps_to_check(result, all_steps):
    steps = result.get("steps") or []
    if all_steps or result.get("mode") != "throughput":
        return steps
    best = result.get("best_step")
    if isinstance(best, int):
        return [s for s in steps if s.get("index", 0) <= best]
    return steps[:1]

def main(argv):
    all_steps = "--all-steps" in argv
    roots = [a for a in argv if a != "--all-steps"]
    if not roots:
        print("usage: check-errors.sh RESULTS_DIR... [--all-steps]", file=sys.stderr)
        return 2
    found = 0
    scanned = 0
    for root in roots:
        for dirpath, _, files in sorted(os.walk(root)):
            if "merged.json" not in files:
                continue
            path = os.path.join(dirpath, "merged.json")
            try:
                with open(path) as f:
                    result = json.load(f)
            except (OSError, ValueError) as err:
                print(f"{path}: unreadable ({err})")
                found += 1
                continue
            scanned += 1
            rel = os.path.relpath(dirpath, root)
            for step in steps_to_check(result, all_steps):
                bad = []
                sample = ""
                for label, op in sorted((step.get("ops") or {}).items()):
                    errors = op.get("errors") or 0
                    if errors <= 0:
                        continue
                    kinds = ",".join(f"{k}:{v}" for k, v in sorted((op.get("error_kinds") or {}).items()))
                    bad.append(f"{label}={errors}/{errors + (op.get('count') or 0)}" + (f" ({kinds})" if kinds else ""))
                    if not sample and op.get("error_samples"):
                        sample = op["error_samples"][0]
                if bad:
                    found += 1
                    rate = step.get("target_rate")
                    where = f"step {step.get('index', 0)}" + (f" rate {rate}/s" if rate else "")
                    print(f"{rel} {where}: {' '.join(bad)}" + (f" | {sample[:200]}" if sample else ""))
    print(f"check-errors: {scanned} results scanned, {found} with errors", file=sys.stderr)
    return 1 if found else 0

sys.exit(main(sys.argv[1:]))
PY
