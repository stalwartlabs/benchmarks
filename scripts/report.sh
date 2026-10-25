#!/usr/bin/env bash
# Render the result tables of one or more runs as Markdown.
#
#   scripts/report.sh RESULTS_DIR... [--readme README.md] [--out FILE]
#
# RESULTS_DIR is results/TRACK/RUN. For every cell and operation label the table shows, per target, the median over
# the valid repetitions of p50 / p95 / p99 (ms), and for throughput cells the highest rate that met the SLO with
# its p99. Invalid repetitions (load generator bottleneck) are left out and counted; a throughput ladder whose only
# invalid steps lie above the reported step and missed the SLO is server saturation and stays valid; operation errors in the reported
# step are summed over repetitions, flagged in the cell and listed at the end. Also lists hosts, measured RTTs
# and versions. Default output: RESULTS_DIR/report.md for a single directory, stdout otherwise. --readme replaces
# the text between "<!-- report:TRACK:begin -->" and "<!-- report:TRACK:end -->" in that file.
set -euo pipefail

[ $# -gt 0 ] || { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 2; }
command -v python3 > /dev/null || { echo "report.sh: python3 is required" >&2; exit 1; }
exec python3 -I - "$@" <<'PY'
import json, os, re, statistics, sys

def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None

def ms(us):
    return "-" if us is None else f"{us / 1000:.2f}"

def ops_of(result):
    steps = result.get("steps")
    if not steps:
        return result.get("ops", {}), None
    best = result.get("best_step")
    if isinstance(best, int) and 0 <= best < len(steps):
        return steps[best].get("ops", {}), steps[best]
    if result.get("mode") == "throughput":
        return {label: {} for label in steps[0].get("ops", {})}, {"slo_not_met": True}
    return steps[0].get("ops", {}), steps[0]

def result_valid(result, meta):
    steps = result.get("steps") or []
    if result.get("mode") == "throughput" and steps:
        best = result.get("best_step")
        floor = best if isinstance(best, int) else 0
        return all(s.get("valid", True) or (s.get("slo_met") is False and s.get("index", 0) > floor) for s in steps)
    return bool(result.get("valid", meta.get("valid", True)))

def median(values):
    values = [v for v in values if v is not None]
    return statistics.median(values) if values else None

def cell_rows(run_dir):
    cells_meta = {c["id"]: c for c in (load(os.path.join(run_dir, "cells.json")) or [])}
    root = os.path.join(run_dir, "cells")
    rows = {}
    labels = []
    if not os.path.isdir(root):
        return rows, labels, cells_meta
    for cell in sorted(os.listdir(root)):
        cdir = os.path.join(root, cell)
        if not os.path.isdir(cdir):
            continue
        for label in sorted(os.listdir(cdir)):
            ldir = os.path.join(cdir, label)
            if label.startswith("attempt") or not os.path.isdir(ldir):
                continue
            if label not in labels:
                labels.append(label)
            for rep in sorted(os.listdir(ldir)):
                result = load(os.path.join(ldir, rep, "merged.json"))
                meta = load(os.path.join(ldir, rep, "meta.json")) or {}
                if result is None:
                    continue
                valid = result_valid(result, meta)
                ops, step = ops_of(result)
                for op, stats in ops.items():
                    entry = rows.setdefault((cell, op), {}).setdefault(label, {"reps": [], "invalid": 0, "errors": 0})
                    entry["errors"] += stats.get("errors") or 0
                    if not valid:
                        entry["invalid"] += 1
                        continue
                    entry["reps"].append({
                        "p50": stats.get("p50"), "p95": stats.get("p95"), "p99": stats.get("p99"),
                        "throughput": stats.get("throughput"), "count": stats.get("count"),
                        "errors": stats.get("errors"),
                        "best_rate": result.get("best_rate"),
                        "slo_not_met": bool((step or {}).get("slo_not_met")),
                    })
    order = {"stalwart": 0}
    labels.sort(key=lambda l: (order.get(l, 1), l))
    return rows, labels, cells_meta

def render_cells(run_dir):
    rows, labels, cells_meta = cell_rows(run_dir)
    if not rows:
        return "No cell results yet.\n"
    out = []
    flagged = []
    families = {}
    for (cell, op) in rows:
        family = cells_meta.get(cell, {}).get("family", "other")
        families.setdefault(family, []).append((cell, op))
    for family in sorted(families):
        keys = sorted(families[family])
        throughput = any(cells_meta.get(c, {}).get("mode") == "throughput" for c, _ in keys)
        out.append(f"#### {family}\n")
        if throughput:
            header = ["Cell", "Operation"] + [f"{l} ops/s at SLO (p99 ms)" for l in labels]
        else:
            header = ["Cell", "Operation"] + [f"{l} p50 / p95 / p99 ms" for l in labels]
        out.append("| " + " | ".join(header) + " |")
        out.append("|" + "---|" * len(header))
        for cell, op in keys:
            line = [cell, op]
            for label in labels:
                entry = rows[(cell, op)].get(label)
                if not entry:
                    line.append("")
                    continue
                reps = entry["reps"]
                note = f" ({entry['invalid']} invalid)" if entry["invalid"] else ""
                if entry["errors"]:
                    note += f" (**{entry['errors']} errors**)"
                    flagged.append(f"{cell} {op} {label}: {entry['errors']} errors")
                if not reps:
                    line.append("invalid" + note)
                elif throughput and all(r["slo_not_met"] for r in reps):
                    line.append("SLO not met" + note)
                elif throughput:
                    tput = median([r["best_rate"] if r["best_rate"] is not None else r["throughput"] for r in reps])
                    p99 = median([r["p99"] for r in reps])
                    line.append(("-" if tput is None else f"{tput:,.0f}") + f" ({ms(p99)})" + note)
                else:
                    line.append(" / ".join(ms(median([r[k] for r in reps])) for k in ("p50", "p95", "p99")) + note)
            out.append("| " + " | ".join(line) + " |")
        out.append("")
    if flagged:
        out.append("#### Cells with operation errors\n")
        out.extend(f"- {f}" for f in flagged)
        out.append("")
    return "\n".join(out) + "\n"

def render_setup(run_dir):
    out = []
    inventory = load(os.path.join(run_dir, "hosts.json")) or {}
    hosts_dir = os.path.join(run_dir, "hosts")
    if inventory.get("hosts"):
        out += ["| Host | Role | Size | CPU | Physical host |", "|---|---|---|---|---|"]
        for h in inventory["hosts"]:
            facts = load(os.path.join(hosts_dir, h["name"] + ".json")) or {}
            phys = facts.get("physical_host") or ""
            out.append(f"| {h['name']} | {h['role']} | {h.get('size', '')} | {facts.get('cpu_model', '')} | {phys[:5]} |")
        out.append("")
    rtt = load(os.path.join(run_dir, "rtt.json")) or []
    if rtt:
        out += ["| From | To | TCP RTT p50 us | p99 us |", "|---|---|---|---|"]
        for r in sorted(rtt, key=lambda r: (r.get("from", ""), r.get("to", ""))):
            p50 = r.get("p50_us", r.get("error", "-"))
            out.append(f"| {r.get('from')} | {r.get('to')} | {p50} | {r.get('p99_us', '-')} |")
        out.append("")
    versions = load(os.path.join(run_dir, "versions.json")) or {}
    flat = {}
    for host, comps in versions.items():
        if isinstance(comps, dict):
            for k, v in comps.items():
                if isinstance(v, (str, int, float)):
                    flat.setdefault(k, set()).add(str(v))
    if flat:
        out += ["| Component | Version |", "|---|---|"]
        for k in sorted(flat):
            out.append(f"| {k} | {', '.join(sorted(flat[k]))} |")
        out.append("")
    return "\n".join(out) + "\n"

def main(argv):
    dirs, readme, out_path = [], None, None
    it = iter(argv)
    for a in it:
        if a == "--readme":
            readme = next(it)
        elif a == "--out":
            out_path = next(it)
        else:
            dirs.append(a.rstrip("/"))
    if not dirs:
        sys.exit("report.sh: no results directory")
    parts = []
    for d in dirs:
        if not os.path.isdir(d):
            sys.exit(f"report.sh: {d} is not a directory")
        run = os.path.basename(d)
        track = os.path.basename(os.path.dirname(d))
        parts.append((track, f"### Track {track.upper()} ({run})\n\n{render_setup(d)}{render_cells(d)}"))
    text = "\n".join(p for _, p in parts)
    if out_path is None and len(dirs) == 1:
        out_path = os.path.join(dirs[0], "report.md")
    if out_path:
        with open(out_path, "w") as f:
            f.write(text)
        print(f"report.sh: wrote {out_path}", file=sys.stderr)
    else:
        sys.stdout.write(text)
    if readme:
        with open(readme) as f:
            body = f.read()
        for track in sorted({t for t, _ in parts}):
            block = "\n".join(p for t, p in parts if t == track)
            begin, end = f"<!-- report:{track}:begin -->", f"<!-- report:{track}:end -->"
            pattern = re.compile(re.escape(begin) + ".*?" + re.escape(end), re.S)
            if not pattern.search(body):
                print(f"report.sh: no {begin} marker in {readme}; skipped", file=sys.stderr)
                continue
            body = pattern.sub(lambda _: f"{begin}\n{block}\n{end}", body)
        with open(readme, "w") as f:
            f.write(body)
        print(f"report.sh: updated {readme}", file=sys.stderr)

main(sys.argv[1:])
PY
