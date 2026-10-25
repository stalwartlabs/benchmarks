#!/usr/bin/env bash
# Render the track C tables, charts and headline summary from the result JSON of every cluster.
#
#   scripts/readme-tables.sh [--results results/c] [--probe results/c-probe-check]
#                            [--profile scenarios/profiles/c-reduced.yaml] [--readme README.md] [--report report]
#                            [--stdout] [--final]
#
# Reads results/c/bench-c*/ and results/c-ext/bench-c*/ when present (cells.json, cells/CELL/LABEL/repN/merged.json,
# cv-*.json, rtt.json, hosts/) and replaces the text between "<!-- readme:NAME:begin -->" and
# "<!-- readme:NAME:end -->" in README.md and in every report/*.md for each block NAME found there: summary (one
# sentence per comparison: who is faster and by how many times), headline, charts, clusters, rtt, flags, probe,
# supplementary (c03-mpc10 connection setup) and one family:KEY block per test family.
# Ladder cells: a repetition whose top planned step met the SLO is a lower bound and prints as ">=". A CELL-ext
# result (scenarios/c-ext/) continues the ladder of CELL for the systems it ran; its best rate replaces CELL's when
# CELL's median was capped. merged.pre-fix.json is never read; multi-host throughput reps that were not re-merged yet
# (.ignore/tools/remerge.sh) are reported on stderr.
# Latency cells: median over the valid repetitions of p50 / p95 / p99, samples summed over valid repetitions,
# errors summed over all repetitions, CV of the per-repetition p50 (as scripts/run-track.sh computes it).
# Cold cells (one sample per repetition): median, p90 and max of imap.select_cold (l09) or imap.cold_op (l10 to l13).
# Throughput cells: median of the highest ladder rate that met the SLO. Summary factors: P+D p50 / Stalwart p50
# (cold: medians; ladders: rate ratio), with the p99 (cold: max) factor added when it is on the other side or
# differs by 2x or more. Earlier attempts (attempt*/) and discarded/ are ignored. A cell with results on more than
# one cluster uses the cluster with the most valid repetitions. Cells without results show "pending". Family tables
# list the cluster of every cell and say so when a family spans clusters.
# SMTP latency tables get a column with the factor measured by diagnostic runs with a quickack client
# (results/c-quickack/bench-*/, same layout); it stays empty without them. README blocks: tally, one cat:KEY block per
# category (bold headline and a small table), wins (where Postfix or Dovecot is faster). Charts are written as SVG to
# report/charts/ (factors.svg, latency-250k.svg) unless --stdout is given.
# --stdout prints the blocks instead of writing files. --final prints "reported later" instead of "pending".
set -euo pipefail

[ "${1:-}" != "-h" ] && [ "${1:-}" != "--help" ] || { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0; }
command -v python3 > /dev/null || { echo "readme-tables.sh: python3 is required" >&2; exit 1; }
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 -I - "$REPO" "$@" <<'PY'
import copy, fnmatch, glob, html, json, math, os, re, statistics, sys

REGIONS = {
    "c1": "westus3", "c2": "eastasia", "c3": "brazilsouth", "c4": "southafricanorth", "c5": "southcentralus",
    "c6": "koreacentral", "c7": "australiaeast", "c8": "swedencentral", "c9": "germanywestcentral",
    "c10": "spaincentral", "c11": "italynorth", "c12": "westeurope", "c13": "francecentral", "c14": "northeurope",
    "c15": "northcentralus", "c16": "japaneast", "c18": "southeastasia", "c19": "uaenorth", "c20": "eastus2",
    "c23": "westus2", "c26": "eastus",
}
EXT_SUFFIX = "-ext"
SUPERSEDED = [("c03", "c10"), ("c15-*", "c8")]
ATTEMPT_AS_MAIN = {("c17", "c6"), ("c03-ext", "c18")}
MISSING_TEXT = "pending"
REPORTED_LATER = {("c15-sessions1-10p-uid_false", "stalwart"), ("c15-sessions1-10p-uid_false", "dovecot"),
                  ("c01-sessions1-recipients10-64k", "stalwart"), ("c01-sessions1-recipients10-64k", "dovecot"),
                  ("c01-sessions1-recipients10-64k", "dovecot+fsync-always"),
                  ("c05-sessions16-mix", "stalwart"), ("c05-sessions16-mix", "dovecot"),
                  ("c05-sessions16-mix", "dovecot+fsync-always")}
PUBLISHED_REPS = {("c14-sessions1-move-range100", "dovecot+fsync-always")}
DRIFT_CELLS = {"l14-copy-move-large100k-move-10p", "l14-copy-move-large250k-move-10p", "l15-expunge-large10k-10p-uid_true",
               "l15-expunge-large250k-10p-uid_true"}
DRIFT_LABELS = {}
DRIFT_DETECT_PREFIX = "c15-"
DRIFT_MIN_RISE = 0.10
RATE_DRIFT_CELLS = {"c03"}
HISTORY = {}
QUICKACK_FAMILIES = {"smtp-in", "delivery", "relay"}
QUICKACK_OPS = {"smtp", "smtp.delivery", "smtp.relay"}
QUICKACK_COLUMN = "P+D / Stalwart p50, quickack client"
QUICKACK = {}
QUICKACK_CELLS = ("c01-", "c02-", "c04-", "c05-")
QUICKACK_LATER = {"c01-1m-sessions1-recipients1", "c01-1m-sessions16-recipients1", "c02-sessions1-recipients1-4k"}
STALL_LINK = "report/RESULTS.md#postfixs-40-ms-stall-after-the-tls-handshake"
DRIFT_NOTE = ("In these tests Dovecot's result changes from one repetition to the next, because state accumulates on "
              "the Dovecot side between repetitions. The factor shown comes from the repetition least favourable to "
              "Stalwart; the median over the reported repetitions follows in brackets. Details: "
              "[report/CAVEATS.md](report/CAVEATS.md#6-state-accumulation-in-dovecots-mdbox).")
SETUP_LIMIT_US = 1_000_000
SETUP_CELLS = ["c03-mpc10"]
STEP_TABLE_CELLS = {"c03-mpc10"}
CONNECTION_MAX_ERROR_RATE = 0.001
TARGET_NAMES = {"stalwart": "Stalwart", "dovecot": "P+D", "dovecot+fsync-always": "P+D fsync=always"}
LABEL_ORDER = ["stalwart", "dovecot", "dovecot+fsync-always"]
MAIN_LABELS = ["stalwart", "dovecot"]
RTT_TARGET_US = 10.0
CV_MAX = 0.10

FAMILIES = [
    ("smtp-in", "C1 SMTP inbound", ["c01-"]),
    ("delivery", "C2 SMTP to INBOX delivery", ["c02-"]),
    ("smtp-in-throughput", "C3 SMTP inbound throughput", ["c03"]),
    ("relay", "C4 and C5 SMTP relay", ["c04-", "c05-"]),
    ("relay-throughput", "C6 SMTP relay throughput", ["c06"]),
    ("imap-session", "C7 to C9 IMAP login, LIST/STATUS, SELECT", ["c07-", "c08-", "c09-"]),
    ("imap-fetch", "C10 IMAP FETCH", ["c10-"]),
    ("imap-search", "C11 IMAP SEARCH", ["c11-"]),
    ("imap-sort", "C12 IMAP SORT and THREAD", ["c12-"]),
    ("imap-write", "C13 to C16 IMAP STORE, COPY/MOVE, EXPUNGE, APPEND", ["c13-", "c14-", "c15-", "c16-"]),
    ("imap-mixed", "C17 mixed IMAP workload", ["c17"]),
    ("large-warm", "Large mailboxes, warm cache", ["l"]),
    ("large-cold", "Large mailboxes, cold cache", ["l"]),
]

HEADLINE = [
    ("c01-sessions1-recipients1-4k", "smtp", "C1 SMTP inbound, 4 KB, 1 session, 1 recipient (connect to 250)"),
    ("c01-sessions16-recipients10-mix", "smtp", "C1 SMTP inbound, corpus mix, 16 sessions, 10 recipients"),
    ("c02-sessions1-recipients1-4k", "smtp.delivery", "C2 connect to visible in INBOX, 4 KB, 1 session"),
    ("c02-sessions16-recipients10-mix", "smtp.delivery", "C2 connect to visible in INBOX, mix, 16 sessions, 10 rcpts"),
    ("c04-sessions1-4k", "smtp", "C4 submission on 465 with AUTH, 4 KB, 1 session"),
    ("c05-sessions1-4k", "smtp.relay", "C5 submission to accepted by the sink, 4 KB, 1 session"),
    ("c07-sessions1", "imap.login", "C7 IMAP connect, TLS, LOGIN, LOGOUT, 1 session"),
    ("c10-sessions1-flags_all", "imap.fetch", "C10 FETCH 1:* (UID FLAGS), 1 session"),
    ("c11-body-common-sessions1", "imap.search.body-common", "C11 SEARCH BODY common term, 1 session"),
    ("c12-sessions1-date", "imap.sort", "C12 SORT (DATE), 1 session"),
    ("c16-sessions1-4k", "imap.append", "C16 APPEND 4 KB, 1 session"),
    ("c16-sessions16-64k", "imap.append", "C16 APPEND 64 KB, 16 sessions"),
    ("l10-fetch-large250k-flags_all", "imap.fetch", "FETCH 1:* (UID FLAGS) on 250k messages, warm"),
    ("l11-search-body-common-large250k", "imap.search.body-common", "SEARCH BODY common term on 250k messages, warm"),
    ("l12-sort-large250k-date", "imap.sort", "SORT (DATE) on 250k messages, warm"),
    ("l13-store-large250k-all", "imap.store", "STORE +FLAGS 1:* on 250k messages, warm"),
    ("l10-fetch-cold-large250k-flags_all", "imap.fetch", "FETCH 1:* (UID FLAGS) on 250k messages, cold"),
    ("l12-sort-cold-large250k-date", "imap.sort", "SORT (DATE) on 250k messages, cold"),
    ("l13-store-cold-large250k-all", "imap.store", "STORE +FLAGS 1:* on 250k messages, cold"),
]
HEADLINE_THROUGHPUT = [
    ("c03", "C3 SMTP inbound, open loop, corpus mix (messages/s)"),
    ("c06", "C6 SMTP relay, open loop, corpus mix (messages/s)"),
    ("c17", "C17 mixed IMAP sessions (session arrivals/s)"),
]
CATEGORIES = [
    ("imap", "IMAP", "Dovecot"),
    ("smtp", "Receiving and relaying mail (SMTP)", "Postfix"),
    ("delivery", "From SMTP to the mailbox", "Postfix + Dovecot"),
    ("throughput", "Sustained load", None),
    ("large", "Very large mailboxes (250,000 messages)", "Dovecot"),
    ("cold", "Cold cache (first access after a restart)", "Dovecot"),
]
SUMMARY = [
    ("imap", "c07-sessions16", "imap.login", "Log in with a full TLS handshake (16 sessions)", "Dovecot"),
    ("imap", "c08-sessions1", "imap.status_all", "STATUS of every folder", "Dovecot"),
    ("imap", "c09-sessions1-qresync_changes0", "imap.select", "Open the INBOX (SELECT)", "Dovecot"),
    ("imap", "c09-sessions1-qresync_changes100", "imap.select_qresync", "Resync after 100 flag changes (SELECT QRESYNC)", "Dovecot"),
    ("imap", "c10-sessions1-flags_all", "imap.fetch", "Fetch the flags of the whole INBOX", "Dovecot"),
    ("imap", "c10-body-sessions1-1m", "imap.fetch", "Fetch a 1 MB message", "Dovecot"),
    ("imap", "c11-body-common-sessions1", "imap.search.body-common", "Search message bodies for a common word", "Dovecot"),
    ("imap", "c11-from-sessions1", "imap.search.from", "Search by sender (SEARCH FROM)", "Dovecot"),
    ("imap", "c12-sessions1-date", "imap.sort", "Sort the INBOX by date", "Dovecot"),
    ("imap", "c12-thread-sessions1", "imap.thread", "Thread the INBOX (THREAD REFERENCES)", "Dovecot"),
    ("imap", "c13-sessions1-_seen-all", "imap.store", "Mark the whole INBOX as read", "Dovecot"),
    ("imap", "c14-sessions1-copy-range100", "imap.copy", "Copy 100 messages", "Dovecot"),
    ("imap", "c14-sessions1-move-range100", "imap.move", "Move 100 messages", "Dovecot"),
    ("imap", "c15-sessions1-range100-uid_true", "imap.uid_expunge", "Delete 100 messages (UID EXPUNGE)", "Dovecot"),
    ("imap", "c16-sessions1-4k", "imap.append", "Upload a 4 KB message (APPEND)", "Dovecot"),
    ("smtp", "c01-sessions1-recipients1-4k", "smtp", "Receive a 4 KB message (1 connection)", "Postfix"),
    ("smtp", "c01-sessions16-recipients10-mix", "smtp", "Receive typical messages for 10 recipients (16 connections)", "Postfix"),
    ("smtp", "c01-1m-sessions16-recipients1", "smtp", "Receive 1 MB messages (16 connections)", "Postfix"),
    ("smtp", "c04-sessions1-4k", "smtp", "Accept an authenticated submission (4 KB)", "Postfix"),
    ("smtp", "c05-sessions16-mix", "smtp.relay", "Relay a submitted message to a remote server (16 connections)", "Postfix"),
    ("delivery", "c02-sessions1-recipients1-4k", "smtp.delivery", "4 KB message visible in the INBOX (1 connection)", "Postfix + Dovecot"),
    ("delivery", "c02-sessions16-recipients10-mix", "smtp.delivery", "Typical messages visible in 10 INBOXes (16 connections)", "Postfix + Dovecot"),
    ("delivery", "c02-idle-sessions1-recipients1-4k", "smtp.delivery", "New message pushed to an IDLE client", "Postfix + Dovecot"),
    ("throughput", "c03", "messages/s", "Inbound messages per second", "Postfix"),
    ("throughput", "c06", "messages/s", "Relayed messages per second", "Postfix"),
    ("throughput", "c17", "sessions/s", "Mail-client sessions per second (mixed IMAP)", "Dovecot"),
    ("large", "l09-select-large250k", "imap.select", "Open the mailbox (SELECT)", "Dovecot"),
    ("large", "l10-fetch-large250k-flags_all", "imap.fetch", "Fetch the flags of all messages", "Dovecot"),
    ("large", "l11-search-body-common-large250k", "imap.search.body-common", "Search all bodies for a common word", "Dovecot"),
    ("large", "l12-sort-large250k-date", "imap.sort", "Sort all messages by date", "Dovecot"),
    ("large", "l13-store-large250k-all", "imap.store", "Mark all messages as read", "Dovecot"),
    ("large", "l14-copy-move-large250k-move-10p", "imap.move", "Move 25,000 messages", "Dovecot"),
    ("large", "l15-expunge-large250k-10p-uid_true", "imap.uid_expunge", "Delete 25,000 messages (UID EXPUNGE)", "Dovecot"),
    ("cold", "l09-select-cold-large250k", None, "Open the mailbox (SELECT)", "Dovecot"),
    ("cold", "l10-fetch-cold-large250k-flags_all", None, "Fetch the flags of all messages", "Dovecot"),
    ("cold", "l11-search-body-common-cold-large250k", None, "Search all bodies for a common word", "Dovecot"),
    ("cold", "l12-sort-cold-large250k-date", None, "Sort all messages by date", "Dovecot"),
    ("cold", "l13-store-cold-large250k-all", None, "Mark all messages as read", "Dovecot"),
]
UNITS = {"messages/s", "connections/s", "sessions/s"}
EQUAL_BELOW = 1.10
TAIL_GAP = 2.0
CHARTS = [
    ("l10-fetch{cold}-{size}-flags_all", "imap.fetch", "FETCH 1:* (UID FLAGS)"),
    ("l11-search-body-common{cold}-{size}", "imap.search.body-common", "SEARCH BODY, common term"),
    ("l12-sort{cold}-{size}-date", "imap.sort", "SORT (DATE)"),
    ("l13-store{cold}-{size}-all", "imap.store", "STORE +FLAGS 1:*"),
    ("l09-select{cold}-{size}", "imap.select", "SELECT"),
]
SIZES = ["large10k", "large100k", "large250k"]


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def ms(us):
    if us is None:
        return "-"
    v = us / 1000
    if v < 1:
        return f"{v:.3f}"
    if v < 10:
        return f"{v:.2f}"
    if v < 100:
        return f"{v:.1f}"
    return f"{v:,.0f}"


def median(values):
    values = [v for v in values if v is not None]
    return statistics.median(values) if values else None


def cv(values):
    values = [v for v in values if v is not None]
    if len(values) < 2:
        return None
    mean = sum(values) / len(values)
    if mean <= 0:
        return 0.0
    return statistics.pstdev(values) / mean


def cluster_of(run_dir):
    m = re.match(r"bench-(c\d+)-", os.path.basename(run_dir))
    return m.group(1) if m else os.path.basename(run_dir)


def result_valid(result, meta):
    steps = result.get("steps") or []
    if result.get("mode") == "throughput" and steps:
        best = result.get("best_step")
        floor = best if isinstance(best, int) else 0
        return all(s.get("valid", True) or (s.get("slo_met") is False and s.get("index", 0) > floor) for s in steps)
    return bool(result.get("valid", meta.get("valid", True)))

def reported_steps(result):
    steps = result.get("steps") or []
    if result.get("mode") != "throughput":
        return steps[:1], (steps[0] if steps else None)
    best = result.get("best_step")
    if isinstance(best, int) and 0 <= best < len(steps):
        return [s for s in steps if s.get("index", 0) <= best], steps[best]
    return steps[:1], None


def duration_seconds(text):
    m = re.fullmatch(r"(\d+(?:\.\d+)?)(ms|s|m)", text or "")
    if not m:
        return None
    return float(m.group(1)) * {"ms": 0.001, "s": 1, "m": 60}[m.group(2)]


class Rep:
    def __init__(self, result, meta):
        self.valid = result_valid(result, meta)
        self.mode = result.get("mode")
        self.best_rate = result.get("best_rate")
        self.slo_labels = (result.get("slo") or {}).get("labels") or []
        steps, best = reported_steps(result)
        self.best = best
        all_steps = result.get("steps") or []
        self.steps = all_steps if self.mode == "throughput" else []
        self.step_seconds = duration_seconds(((result.get("load") or {}).get("step_duration")))
        self.capped = best is not None and bool(all_steps) and best is all_steps[-1]
        self.ops = (best or {}).get("ops", {}) if best else ((steps[0].get("ops", {}) if steps else {}))
        self.errors = {}
        for step in steps:
            for label, op in (step.get("ops") or {}).items():
                self.errors[label] = self.errors.get(label, 0) + (op.get("errors") or 0)


def not_remerged(rdir, result):
    if result.get("mode") != "throughput" or os.path.exists(os.path.join(rdir, "merged.pre-fix.json")):
        return False
    shards = sorted(glob.glob(os.path.join(rdir, "load*.json")))
    if len(shards) < 2 or not result.get("steps"):
        return False
    shard = load(shards[0]) or {}
    shard_top = ((shard.get("steps") or [{}])[-1]).get("target_rate")
    merged_top = result["steps"][-1].get("target_rate")
    return bool(shard_top and merged_top) and abs(merged_top - 2 * shard_top) < 0.01 * merged_top


STALE = []


def scan_reps(ldir):
    reps = []
    for rdir in sorted(glob.glob(os.path.join(ldir, "rep*")), key=natural):
        result = load(os.path.join(rdir, "merged.json"))
        if result is None:
            continue
        if not_remerged(rdir, result):
            STALE.append(rdir)
        rep = Rep(result, load(os.path.join(rdir, "meta.json")) or {})
        rep.cluster = next((cluster_of(part) for part in reversed(os.path.abspath(ldir).split(os.sep))
                            if part.startswith("bench-")), "-")
        reps.append(rep)
    return reps


def scan_cell(cdir):
    labels = {}
    for ldir in sorted(glob.glob(os.path.join(cdir, "*"))):
        label = os.path.basename(ldir)
        if label.startswith("attempt") or not os.path.isdir(ldir):
            continue
        reps = scan_reps(ldir)
        if reps:
            labels[label] = reps
    return labels


def scan_history(cdir, labels):
    attempts = sorted(glob.glob(os.path.join(cdir, "attempt*-main")), key=natural)
    return {label: [r for a in attempts for r in scan_reps(os.path.join(a, label))] + reps
            for label, reps in labels.items()}


def profile_groups(path):
    groups = []
    try:
        with open(path) as f:
            for line in f:
                m = re.match(r"\s*-\s*\{name:\s*([\w-]+),\s*match:\s*\[(.*)\]\}", line)
                if m:
                    groups.append((m.group(1), re.findall(r'"([^"]+)"', m.group(2))))
    except OSError:
        pass
    return groups


def collect(results_root, profile):
    roots = [results_root, os.path.join(os.path.dirname(os.path.abspath(results_root)), "c-ext")]
    runs = sorted((d for root in roots for d in glob.glob(os.path.join(root, "bench-c*")) if os.path.isdir(d)),
                  key=lambda d: int(re.sub(r"\D", "", cluster_of(d)) or 0))
    groups = profile_groups(profile)
    meta, candidates, cvs = {}, {}, {}
    for run in runs:
        for c in load(os.path.join(run, "cells.json")) or []:
            meta.setdefault(c["id"], c)
    for cell_id, m in meta.items():
        group = next((name for name, patterns in groups if any(fnmatch.fnmatchcase(cell_id, p) for p in patterns)), None)
        if group:
            m["group"] = group
    for run in runs:
        for cdir in sorted(glob.glob(os.path.join(run, "cells", "*"))):
            published = os.path.join(cdir, "attempt1-main")
            use_attempt = (os.path.basename(cdir), cluster_of(run)) in ATTEMPT_AS_MAIN and os.path.isdir(published)
            labels = scan_cell(published if use_attempt else cdir)
            if labels:
                candidates.setdefault(os.path.basename(cdir), []).append((cluster_of(run), labels))
                drifting = rises(labels) if os.path.basename(cdir).startswith(DRIFT_DETECT_PREFIX) else []
                if drifting:
                    DRIFT_CELLS.add(os.path.basename(cdir))
                    DRIFT_LABELS[(os.path.basename(cdir), cluster_of(run))] = drifting
                if os.path.basename(cdir) in DRIFT_CELLS:
                    HISTORY[(os.path.basename(cdir), cluster_of(run))] = scan_history(cdir, labels)
                cvs[(os.path.basename(cdir), cluster_of(run))] = (load(os.path.join(cdir, "cv-main.json")) or []) + (
                    load(os.path.join(cdir, "cv-variant.json")) or [])
    chosen, duplicates = {}, []
    for cell, cands in candidates.items():
        excluded = {cl for pattern, cl in SUPERSEDED if fnmatch.fnmatchcase(cell, pattern)}
        cands = [c for c in cands if c[0] not in excluded] or cands
        cands.sort(key=lambda c: sum(1 for label in MAIN_LABELS for r in c[1].get(label, []) if r.valid), reverse=True)
        cluster, labels = cands[0]
        labels, borrowed = dict(labels), []
        for label in sorted({l for _, other in cands[1:] for l in other} - set(labels)):
            donor = max((c for c in cands[1:] if label in c[1]), key=lambda c: sum(1 for r in c[1][label] if r.valid))
            labels[label] = donor[1][label]
            borrowed.append(donor[0])
        if borrowed:
            combined = "+".join([cluster] + sorted(set(borrowed), key=natural))
            cvs[(cell, combined)] = [e for c in [cluster] + borrowed for e in cvs.get((cell, c), [])]
            cluster = combined
        chosen[cell] = (cluster, labels)
        if len(cands) > 1:
            duplicates.append((cell, [c[0] for c in cands]))
    for directory, _, cells in FIX_SETS:
        apply_fix_runs(os.path.join(os.path.dirname(os.path.abspath(results_root)), directory), cells, chosen)
    return runs, meta, chosen, duplicates, cvs


def apply_fix_runs(root, cells, chosen):
    for cell, run in cells.items():
        if cell not in chosen:
            continue
        cluster, labels = chosen[cell]
        fixed = dict(labels)
        for label in MAIN_LABELS:
            reps = []
            for path in sorted(glob.glob(os.path.join(root, run, "*", f"{cell}-{label}.json")), key=natural):
                result = load(path)
                if result is not None:
                    rep = Rep(result, {})
                    rep.cluster = cluster_of(run)
                    reps.append(rep)
            if not reps:
                break
            fixed[label] = reps
        else:
            others = set(fixed) - set(MAIN_LABELS)
            main_cluster = cluster_of(run)
            chosen[cell] = (main_cluster if not others or cluster == main_cluster else f"{main_cluster}+{cluster}", fixed)


def rises(labels):
    drifting = []
    for label, reps in labels.items():
        p50s = [next((op.get("p50") for name, op in sorted(r.ops.items()) if "expunge" in name), None) for r in reps]
        if (len(p50s) >= 2 and all(p50s) and all(b > a for a, b in zip(p50s, p50s[1:]))
                and p50s[-1] >= p50s[0] * (1 + DRIFT_MIN_RISE)):
            drifting.append(label)
    return drifting


def expected_labels(cell_meta):
    labels = list(cell_meta.get("targets") or ["stalwart", "dovecot"])
    labels += [f"{v['target']}+{v['name']}" for v in cell_meta.get("variants") or []]
    return labels


def latency_stats(reps, op):
    valid = [r for r in reps if r.valid and op in r.ops]
    p50s = [r.ops[op].get("p50") for r in valid]
    return {
        "p50": median(p50s), "p95": median([r.ops[op].get("p95") for r in valid]),
        "p99": median([r.ops[op].get("p99") for r in valid]),
        "n": sum(r.ops[op].get("count") or 0 for r in valid),
        "errors": sum(r.errors.get(op, 0) for r in reps),
        "cv": cv(p50s), "reps": len(valid), "invalid": sum(1 for r in reps if not r.valid),
    }


def cold_label(cell_id):
    return "imap.select_cold" if cell_id.startswith("l09") else "imap.cold_op"


def nearest_rank(values, q):
    ordered = sorted(values)
    return ordered[max(0, min(len(ordered) - 1, -(-len(ordered) * q // 100) - 1))] if ordered else None


def cold_stats(reps, cell_id):
    label = cold_label(cell_id)
    fresh = [r for r in reps if "imap.select_cold" in r.ops]
    values = [r.ops[label].get("max") for r in fresh if r.valid and label in r.ops]
    values = [v for v in values if v is not None]
    return {
        "p50": median(values), "p90": nearest_rank(values, 90), "max": max(values) if values else None,
        "n": len(values), "errors": sum(r.errors.get(label, 0) for r in fresh),
        "invalid": sum(1 for r in fresh if not r.valid), "label": label,
    }


def capped_median(points):
    if not points:
        return None, False
    ordered = sorted(points, key=lambda p: p[0])
    middle = ordered[(len(ordered) - 1) // 2: len(ordered) // 2 + 1]
    return statistics.median(p[0] for p in ordered), any(p[1] for p in middle)


def worst_slo_p99(r):
    labels = r.slo_labels or list(r.ops)
    values = [r.ops[l].get("p99") for l in labels if l in r.ops and r.ops[l].get("p99") is not None]
    return max(values) if values else None


def throughput_stats(reps, ext_reps=None):
    valid = [r for r in reps if r.valid]
    points = [(r.best_rate, r.capped, r) for r in valid if r.best is not None]
    rate, capped = capped_median(points)
    errors = sum(sum(r.errors.values()) for r in reps)
    invalid = sum(1 for r in reps if not r.valid)
    ext_valid = [r for r in ext_reps or [] if r.valid]
    extended = bool(capped and ext_valid)
    if extended:
        points = [(r.best_rate, r.capped, r) if r.best is not None else (rate, False, r) for r in ext_valid]
        rate, capped = capped_median(points)
        valid = ext_valid
        errors += sum(sum(r.errors.values()) for r in ext_reps)
        invalid += sum(1 for r in ext_reps if not r.valid)
    met = [p for p in points if p[2].best is not None]
    return {
        "rate": rate, "capped": capped, "rates": [(p[0], p[1]) for p in points], "cv": cv([p[0] for p in points]),
        "p99": median([worst_slo_p99(p[2]) for p in met]), "errors": errors, "reps": len(valid), "met": len(met),
        "invalid": invalid, "extended": extended,
    }


def fmt_rate(rate, capped, suffix=""):
    return f"{'>= ' if capped else ''}{rate:,.0f}{suffix}" if rate >= 1000 else f"{'>= ' if capped else ''}{rate:,.1f}{suffix}"


def rate_bound(s, d):
    if s["capped"] and d["capped"]:
        return "unknown"
    if s["capped"]:
        return "atleast" if s["rate"] >= d["rate"] else "unknown"
    if d["capped"]:
        return "atleast" if d["rate"] >= s["rate"] else "unknown"
    return "exact"


def ext_reps(chosen, cell, label):
    return chosen.get(cell + EXT_SUFFIX, (None, {}))[1].get(label)


def connection_error_rate(step):
    op = (step.get("ops") or {}).get("smtp") or {}
    arrivals = (step.get("generator") or {}).get("arrivals")
    if arrivals:
        return (op.get("errors") or 0) / arrivals
    if op.get("error_rate") is not None:
        return op["error_rate"]
    total = (op.get("count") or 0) + (op.get("errors") or 0)
    return (op.get("errors") or 0) / total if total else 0.0


def setup_point(r):
    best, capped = None, True
    for step in r.steps:
        phases = ((step.get("ops") or {}).get("smtp") or {}).get("phases") or {}
        connect, greeting = (phases.get("connect") or {}).get("p99"), (phases.get("greeting") or {}).get("p99")
        if (connect is None or greeting is None or connect + greeting >= SETUP_LIMIT_US
                or connection_error_rate(step) > CONNECTION_MAX_ERROR_RATE):
            capped = False
            break
        best = step.get("target_rate")
    return None if best is None else (best, capped, r)


def setup_stats(reps, ext):
    points = [p for p in (setup_point(r) for r in reps if r.valid) if p]
    rate, capped = capped_median(points)
    ext_points = [p for p in (setup_point(r) for r in ext or [] if r.valid) if p]
    if capped and ext_points:
        points = ext_points
        rate, capped = capped_median(points)
    return rate, capped, points


def natural(text):
    return [int(t) if t.isdigit() else t for t in re.split(r"(\d+)", text)]


def family_of(cell_id, cell_meta):
    cold = cell_meta.get("cache") == "cold"
    if cell_id.startswith("l"):
        return "large-cold" if cold else "large-warm"
    for key, _, prefixes in FAMILIES:
        if key.startswith("large"):
            continue
        for p in prefixes:
            if cell_id == p or (p.endswith("-") and cell_id.startswith(p)) or cell_id.startswith(p + "-"):
                return key
    return None


def op_order(op):
    order = ["smtp", "smtp.message", "smtp.delivery", "smtp.probe_rtt", "smtp.relay"]
    return (order.index(op) if op in order else len(order), op)


def ratio(s, d):
    if s is None or d is None or s <= 0:
        return "-"
    r = d / s
    return f"{r:.1f}x" if r >= 1 else f"{r:.2f}x"


def fmt_cv(value):
    if value is None:
        return "-"
    text = f"{value:.2f}"
    return f"**{text}**" if value > CV_MAX else text


def span_note(cells, chosen):
    clusters = sorted({chosen[c][0] for c in cells if c in chosen}, key=natural)
    if len(clusters) < 2:
        return ""
    listed = ", ".join(clusters[:-1]) + f" and {clusters[-1]}"
    return (f"\nThe cells of this family ran on clusters {listed} (column Pair). Within a cell, both systems and all "
            "repetitions share one VM pair.\n")


def render_family(key, meta, chosen):
    return render_family_table(key, meta, chosen) + span_note(
        [c for c, m in meta.items() if family_of(c, m) == key], chosen)


FSYNC_WAIT_US = (950_000, 1_100_000)
STORE_MARK, APPEND_MARK, QRESYNC_MARK = "\u2021", "\u00a7", "\u00b6"
FIX_SETS = [
    ("c-store-build", STORE_MARK, {
        **{f"l13-store-large{size}-{rng}": "bench-c6-1025" for size in ("10k", "100k", "250k")
           for rng in ("one", "range100", "all")},
        **{cell: "bench-c3-1025" for cell in ("c13-sessions1-_seen-range100", "c13-sessions1-_flagged-range100",
                                              "c13-sessions1-_seen-all", "c13-sessions1-_flagged-all",
                                              "c13-sessions16-_seen-range100")},
    }),
    ("c-append-build", APPEND_MARK, {cell: "bench-c8-1025" for cell in ("c16-sessions1-64k", "c16-sessions16-64k",
                                                                         "c16-sessions16-4k")}),
    ("c-qresync-build", QRESYNC_MARK, {cell: "bench-c3-1025" for cell in (
        "c09-sessions1-qresync_changes100", "c09-sessions16-qresync_changes100", "c09-sessions1-qresync_changes0")}),
]
FIX_CELLS = {cell: mark for _, mark, cells in FIX_SETS for cell in cells}
STORE_NOTE = ("\u2021 Stalwart build 2d80f00b, measured in one session with Postfix + Dovecot on the same cluster: 2 "
              "Stalwart and 4 Postfix + Dovecot runs on the large mailboxes, 1 run each on the regular mailboxes; "
              "unmarked rows use build f976519d "
              "([CAVEATS.md, section 10](CAVEATS.md#10-build-and-configuration-differences)).")
APPEND_NOTE = ("\u00a7 Stalwart build 8b3d762a, measured on cluster c8 in one session with Postfix + Dovecot: 2 runs per "
               "system for 64 KB messages, 1 for the 16-session 4 KB test; the fsync=always column is from cluster c6; "
               "unmarked rows use build f976519d "
               "([CAVEATS.md, section 10](CAVEATS.md#10-build-and-configuration-differences)).")
QRESYNC_NOTE = ("\u00b6 Stalwart build a665cdfa, measured on cluster c3 in one session with Postfix + Dovecot: 3 runs per "
                "system, interleaved; unmarked rows use build f976519d "
                "([CAVEATS.md, section 10](CAVEATS.md#10-build-and-configuration-differences)).")
FIX_NOTES = {STORE_MARK: STORE_NOTE, APPEND_MARK: APPEND_NOTE, QRESYNC_MARK: QRESYNC_NOTE}
FIX_CAPTIONS = {
    STORE_MARK: "\u2021 Stalwart build 2d80f00b; see the table footnotes.",
    APPEND_MARK: "\u00a7 Stalwart build 8b3d762a; see the table footnotes.",
    QRESYNC_MARK: "\u00b6 Stalwart build a665cdfa; see the table footnotes.",
}


def fix_captions(cells, grid, height):
    for mark in sorted({FIX_CELLS[c] for c in cells if c in FIX_CELLS}):
        grid.append(f'<text class="t2" x="16" y="{height + 6}">{html.escape(FIX_CAPTIONS[mark])}</text>')
        height += 22
    return height
WAIT_MARKED = {("c14-sessions1-move-10p", "dovecot")}
FSYNC_NOTE = ("\u2020 Dovecot p50 of about 1 s whatever the operation size: a fixed 1 s retry while its full-text indexer "
              "holds the index lock after a preceding COPY or MOVE "
              "([CAVEATS.md, section 3](CAVEATS.md#3-durability-is-not-identical)).")


def fsync_mark(label, p50, cell=None):
    low, high = FSYNC_WAIT_US
    if p50 is None or not low <= p50 <= high:
        return ""
    return " \u2020" if label == "dovecot+fsync-always" or (cell, label) in WAIT_MARKED else ""


def missing_text(cell, label):
    return "reported later" if (cell, label) in REPORTED_LATER else MISSING_TEXT


def render_family_table(key, meta, chosen):
    cells = sorted((c for c, m in meta.items() if family_of(c, m) == key), key=natural)
    if not cells:
        return "No cells in this family.\n"
    throughput = any(meta[c].get("mode") == "throughput" for c in cells)
    labels = [l for l in LABEL_ORDER if any(l in expected_labels(meta[c]) for c in cells)]
    names = [TARGET_NAMES.get(l, l) for l in labels]
    out = []
    if key == "large-cold":
        head = ["Cell", "Pair", "Cold operation"] + [f"{n} median / p90 / max ms" for n in names] + ["P+D / Stalwart median"]
        head += ["Cold samples " + " / ".join(names), "Errors " + " / ".join(names)]
        out.append("| " + " | ".join(head) + " |")
        out.append("|" + "---|" * len(head))
        for cell in cells:
            cluster, data = chosen.get(cell, ("-", {}))
            need = meta[cell].get("repetitions") or 10
            stats = {l: cold_stats(data[l], cell) for l in labels if l in data}
            stats = {l: st for l, st in stats.items() if st["n"]}
            row = [cell, cluster if stats else "-", cold_label(cell)]
            for l in labels:
                st = stats.get(l)
                if not st:
                    row.append(MISSING_TEXT)
                    continue
                text = f"{ms(st['p50'])} / {ms(st['p90'])} / {ms(st['max'])}"
                if st["n"] < need:
                    text += f" ({st['n']}/{need} samples)"
                row.append(text)
            row.append(ratio(stats.get("stalwart", {}).get("p50"), stats.get("dovecot", {}).get("p50")))
            row.append(" / ".join(str(stats[l]["n"]) if l in stats else "-" for l in labels))
            row.append(" / ".join(
                (f"**{stats[l]['errors']}**" if stats[l]["errors"] else "0") if l in stats else "-" for l in labels))
            out.append("| " + " | ".join(row) + " |")
        return "\n".join(out) + "\n"
    if throughput:
        out.append("| Cell | Pair | System | Rate at SLO (median) | Per repetition | CV | p99 at that rate, ms | Errors | Reps (met SLO / valid) |")
        out.append("|---|---|---|---|---|---|---|---|---|")
        for cell in cells:
            cluster, data = chosen.get(cell, ("-", {}))
            for label in labels:
                if label not in expected_labels(meta[cell]):
                    continue
                reps = data.get(label)
                name = TARGET_NAMES.get(label, label)
                if not reps:
                    out.append(f"| {cell} | {cluster} | {name} | {MISSING_TEXT} | | | | | |")
                    continue
                if cell.removesuffix(EXT_SUFFIX) in STEP_TABLE_CELLS:
                    out.append(f"| {cell} | {cluster} | {name} | see the per-step table below | | | | | |")
                    continue
                ext = None if cell.endswith(EXT_SUFFIX) else ext_reps(chosen, cell, label)
                t = throughput_stats(reps, ext)
                rate = "invalid" if not t["reps"] else ("SLO not met" if t["rate"] is None else fmt_rate(t["rate"], t["capped"]))
                if t["extended"]:
                    rate += f" (extended on {chosen[cell + EXT_SUFFIX][0]})"
                per = ", ".join(fmt_rate(r, c) for r, c in t["rates"]) or "-"
                out.append(f"| {cell} | {cluster} | {name} | {rate} | {per} | {fmt_cv(t['cv'])} | {ms(t['p99'])} | {t['errors']} | {t['met']} / {t['reps']} |")
        return "\n".join(out) + "\n"
    quick_col = key in QUICKACK_FAMILIES
    head = ["Cell", "Pair", "Operation"] + [f"{n} p50 / p95 / p99 ms" for n in names] + ["P+D / Stalwart p50"]
    head += [QUICKACK_COLUMN] if quick_col else []
    head += ["Samples " + " / ".join(names), "Errors " + " / ".join(names), "CV " + " / ".join(names)]
    out.append("| " + " | ".join(head) + " |")
    out.append("|" + "---|" * len(head))
    marked, fix_marks = False, set()
    for cell in cells:
        cluster, data = chosen.get(cell, ("-", {}))
        cell_labels = expected_labels(meta[cell])
        ops = sorted({op for reps in data.values() for r in reps for op in r.ops}, key=op_order)
        if not ops:
            out.append(f"| {cell} | {cluster} | | " + " | ".join(missing_text(cell, l) for l in labels) + " |"
                       + " |" * (len(head) - 3 - len(labels)))
            continue
        reps_needed = meta[cell].get("repetitions") or 3
        for op in ops:
            stats = {l: latency_stats(data[l], op) for l in labels if l in data}
            row = [cell, cluster, op]
            for l in labels:
                if l not in cell_labels:
                    row.append("n/a")
                elif l not in stats:
                    row.append(missing_text(cell, l))
                else:
                    s = stats[l]
                    text = f"{ms(s['p50'])} / {ms(s['p95'])} / {ms(s['p99'])}" + fsync_mark(l, s["p50"], cell)
                    marked = marked or bool(fsync_mark(l, s["p50"], cell))
                    if cell in FIX_CELLS and l in MAIN_LABELS:
                        text += " " + FIX_CELLS[cell]
                        fix_marks.add(FIX_CELLS[cell])
                    elif (cell, l) in PUBLISHED_REPS:
                        text += f" ({s['reps']} repetitions)"
                    elif s["reps"] < reps_needed:
                        text += f" ({s['reps']}/{reps_needed} reps)"
                    row.append(text)
            s_p50 = stats.get("stalwart", {}).get("p50")
            d_p50 = stats.get("dovecot", {}).get("p50")
            row.append(ratio(s_p50, d_p50))
            if quick_col:
                row.append(quickack_factor(cell, op))
            row.append(" / ".join(str(stats[l]["n"]) if l in stats else "-" for l in labels))
            row.append(" / ".join(
                (f"**{stats[l]['errors']}**" if stats[l]["errors"] else "0") if l in stats else "-" for l in labels))
            row.append(" / ".join(fmt_cv(stats[l]["cv"]) if l in stats else "-" for l in labels))
            out.append("| " + " | ".join(row) + " |")
    if marked:
        out += ["", FSYNC_NOTE]
    for mark in sorted(fix_marks):
        out += ["", FIX_NOTES[mark]]
    return "\n".join(out) + "\n"


def render_headline(meta, chosen):
    out = ["| Test | Pair | Stalwart p50 / p99 ms | P+D p50 / p99 ms | P+D fsync=always p50 / p99 ms | P+D / Stalwart p50 | "
           f"{QUICKACK_COLUMN} |", "|---|---|---|---|---|---|---|"]
    fsync_seen = []
    for cell, op, title in HEADLINE:
        cluster, data = chosen.get(cell, ("-", {}))
        cols = []
        p50 = {}
        for label in LABEL_ORDER:
            if cell in meta and label not in expected_labels(meta[cell]):
                cols.append("n/a")
                continue
            reps = data.get(label)
            cold = (meta.get(cell) or {}).get("cache") == "cold"
            if not reps:
                s = None
            elif cold:
                s = cold_stats(reps, cell)
                s["p99"] = s["max"]
            else:
                s = latency_stats(reps, op)
            if not s or s["p50"] is None:
                cols.append(MISSING_TEXT)
                continue
            p50[label] = s["p50"]
            cols.append(f"{ms(s['p50'])} / {ms(s['p99'])}" + fsync_mark(label, s["p50"]))
        fsync_seen.append(p50.get("dovecot+fsync-always"))
        out.append(f"| {title} | {cluster if p50 else '-'} | " + " | ".join(cols) + f" | {ratio(p50.get('stalwart'), p50.get('dovecot'))} | {quickack_factor(cell, op)} |")
    if any(fsync_mark("dovecot+fsync-always", v) for v in fsync_seen):
        out += ["", FSYNC_NOTE]
    out += ["", "| Test | Pair | Stalwart rate at SLO | P+D rate at SLO | P+D fsync=always rate at SLO | Stalwart / P+D |",
            "|---|---|---|---|---|---|"]
    for cell, title in HEADLINE_THROUGHPUT:
        cluster, data = chosen.get(cell, ("-", {}))
        if cell + EXT_SUFFIX in chosen:
            cluster += f" + {chosen[cell + EXT_SUFFIX][0]}"
        cols, stats = [], {}
        for label in LABEL_ORDER:
            if cell in meta and label not in expected_labels(meta[cell]):
                cols.append("n/a")
                continue
            reps = data.get(label)
            if not reps:
                cols.append(MISSING_TEXT)
                continue
            t = throughput_stats(reps, ext_reps(chosen, cell, label))
            if t["rate"] is not None:
                stats[label] = t
            text = "invalid" if not t["reps"] else ("SLO not met" if t["rate"] is None else fmt_rate(t["rate"], t["capped"], "/s"))
            first = max((r for r in reps if r.valid and r.best is not None), key=lambda r: r.best_rate, default=None)
            if cell in RATE_DRIFT_CELLS and label == "dovecot" and first and t["rate"] is not None and not t["capped"]:
                text = f"{fmt_rate(first.best_rate, first.capped, '/s')} (repetition least favourable to Stalwart; median {text})"
                t = dict(t, median_rate=t["rate"], rate=first.best_rate)
                stats[label] = t
            cols.append(text)
        factor = "-"
        if "stalwart" in stats and "dovecot" in stats:
            bound = rate_bound(stats["stalwart"], stats["dovecot"])
            prefix = ">= " if bound == "atleast" and stats["stalwart"]["capped"] else "<= " if bound == "atleast" else ""
            factor = "unknown (both capped)" if bound == "unknown" else prefix + ratio(stats["dovecot"]["rate"], stats["stalwart"]["rate"])
            if bound != "unknown" and stats["dovecot"].get("median_rate"):
                factor += f" (median {prefix}{ratio(stats['dovecot']['median_rate'], stats['stalwart']['rate'])})"
        out.append(f"| {title} | {cluster} | " + " | ".join(cols) + f" | {factor} |")
    return "\n".join(out) + "\n"


def quickack_factor(cell, op):
    if op not in QUICKACK_OPS or not cell.startswith(QUICKACK_CELLS):
        return ""
    data = QUICKACK.get(cell) or {}
    s_reps, d_reps = data.get("stalwart"), data.get("dovecot")
    if not s_reps or not d_reps:
        return quickack_missing(cell) if QUICKACK else ""
    return ratio(latency_stats(s_reps, op)["p50"], latency_stats(d_reps, op)["p50"])


def quickack_missing(cell):
    return "reported later" if cell in QUICKACK_LATER else "not measured"


def quickack_verdict(cell, op, competitor):
    if op not in QUICKACK_OPS or not cell.startswith(QUICKACK_CELLS):
        return ""
    data = QUICKACK.get(cell) or {}
    s_reps, d_reps = data.get("stalwart"), data.get("dovecot")
    if not s_reps or not d_reps:
        return quickack_missing(cell)
    s, d = latency_stats(s_reps, op)["p50"], latency_stats(d_reps, op)["p50"]
    if not s or not d:
        return quickack_missing(cell)
    r = d / s
    if max(r, 1 / r) < EQUAL_BELOW:
        return "about equal"
    return f"**Stalwart**, {factor_text(r)}" if r >= 1 else f"**{competitor}**, {factor_text(1 / r)}"


def factor_text(f):
    return f"{f:.0f}x" if f >= 10 else f"{f:.1f}x"


def summary_row(cell, op, meta, chosen):
    m = meta.get(cell) or {}
    data = chosen.get(cell, (None, {}))[1]
    s_reps, d_reps = data.get("stalwart"), data.get("dovecot")
    if not s_reps or not d_reps:
        return None
    if m.get("mode") == "throughput":
        s = throughput_stats(s_reps, ext_reps(chosen, cell, "stalwart"))
        d = throughput_stats(d_reps, ext_reps(chosen, cell, "dovecot"))
        if not s["rate"] or not d["rate"]:
            return None
        need = m.get("repetitions") or 3
        row = {"ratio": s["rate"] / d["rate"], "tail": None, "s": s["rate"], "d": d["rate"],
               "s_cap": s["capped"], "d_cap": d["capped"], "bound": rate_bound(s, d), "kind": "rate",
               "s_met": s["met"], "d_met": d["met"], "need": need}
        first = max((r for r in d_reps if r.valid and r.best is not None), key=lambda r: r.best_rate, default=None)
        if cell in RATE_DRIFT_CELLS and first and not d["capped"]:
            row.update(median=row["ratio"], ratio=s["rate"] / first.best_rate, d=first.best_rate, drift=True)
        return row
    if m.get("cache") == "cold":
        s, d = cold_stats(s_reps, cell), cold_stats(d_reps, cell)
        kind, tail = "cold", "max"
    else:
        s, d = latency_stats(s_reps, op), latency_stats(d_reps, op)
        kind, tail = "p50", "p99"
    if not s["p50"] or not d["p50"]:
        return None
    history = HISTORY.get((cell, chosen[cell][0].split("+")[0]))
    if kind == "p50" and history:
        drift = drift_row(history, op, d["p50"] / s["p50"])
        if drift:
            return drift
    s_tail, d_tail = s.get(tail), d.get(tail)
    row = {"ratio": d["p50"] / s["p50"], "tail": d_tail / s_tail if s_tail and d_tail else None,
           "s": s["p50"], "d": d["p50"], "bound": "exact", "kind": kind, "n": min(s.get("n") or 0, d.get("n") or 0),
           "s_p99": s_tail, "d_p99": d_tail, "reps": min(s.get("reps") or 0, d.get("reps") or 0),
           "need": m.get("repetitions") or 3, "fix": cell in FIX_CELLS}
    return row


def drift_row(history, op, median_ratio):
    s_hist = [r.ops[op] for r in history.get("stalwart", []) if r.valid and op in r.ops]
    d_hist = [r.ops[op] for r in history.get("dovecot", []) if r.valid and op in r.ops]
    if not s_hist or not d_hist or not s_hist[0].get("p50") or not d_hist[0].get("p50"):
        return None
    matched = [(s_op, d_op) for s_op, d_op in zip(s_hist, d_hist) if s_op.get("p50") and d_op.get("p50")]
    pairs = [d_op["p50"] / s_op["p50"] for s_op, d_op in matched]
    index = min(range(len(pairs)), key=pairs.__getitem__)
    first_s, first_d = matched[index]
    tail = first_d["p99"] / first_s["p99"] if first_s.get("p99") and first_d.get("p99") else None
    return {"ratio": first_d["p50"] / first_s["p50"], "tail": tail, "s": first_s["p50"], "d": first_d["p50"],
            "bound": "exact", "kind": "drift", "median": median_ratio, "range": (min(pairs), max(pairs)),
            "pairs": len(pairs), "per": pairs, "index": index + 1, "s_n": first_s.get("count"), "d_n": first_d.get("count")}


def drift_range(row, stalwart_wins):
    low, high = sorted(oriented(v, stalwart_wins) for v in row["range"])
    return "" if row["pairs"] < 2 else f", range {factor_text(low)} to {factor_text(high)} over all repetitions"


def oriented(value, stalwart_wins):
    return value if stalwart_wins else 1 / value


CATEGORY_METRIC = {
    "imap": "Typical latency (p50), lower is better.",
    "smtp": "Typical latency (p50) from TCP connect to the server's 250 reply, lower is better.",
    "delivery": "Typical latency (p50) from the sender's TCP connect until the message is visible to an IMAP client, lower is better.",
    "throughput": "Highest load that still met the service level (p99 under 1 s, 500 ms for mixed IMAP sessions, at most 0.1% errors), higher is better.",
    "large": "Typical latency (p50) with a warm cache, lower is better.",
    "cold": "Median of 10 samples, each the first operation after both servers were restarted with an empty page cache, lower is better.",
}


def summary_rows(meta, chosen):
    return [(cat, cell, op, label, comp, summary_row(cell, op, meta, chosen)) for cat, cell, op, label, comp in SUMMARY]


def verdict(row, competitor):
    if row["bound"] == "unknown":
        return "unknown", None, False
    stalwart_wins = row["ratio"] >= 1
    factor = row["ratio"] if stalwart_wins else 1 / row["ratio"]
    if factor < EQUAL_BELOW:
        return None, factor, False
    at_least = row["kind"] == "rate" and (row["s_cap"] if stalwart_wins else row["d_cap"])
    return ("Stalwart" if stalwart_wins else competitor), factor, at_least


def fmt_factor(factor, at_least):
    return f"{'at least ' if at_least else ''}{factor_text(factor)}"


def fmt_value(row, which, unit):
    if row["kind"] == "rate":
        text = fmt_rate(row[which], row["s_cap" if which == "s" else "d_cap"], f" {unit}")
        met = row[f"{which}_met"]
        return text + (f" ({met} of {row['need']} repetitions)" if met < row["need"] else "")
    return f"{ms(row[which])} ms"


def result_text(row, competitor):
    winner, factor, at_least = verdict(row, competitor)
    if winner == "unknown":
        return "not separated (both still met the SLO at the top of the ladder)"
    if winner is None:
        return "about equal"
    text = f"**{winner}**, {fmt_factor(factor, at_least)}"
    if row["kind"] == "drift" or row.get("drift"):
        text += f"\\* (median {fmt_factor(oriented(row['median'], row['ratio'] >= 1), at_least)})"
    tail = tail_against(row, competitor)
    if tail:
        text += f" (at p99: {tail[0]} {factor_text(tail[1])} faster)"
    if row["kind"] == "p50" and row.get("reps") and row["reps"] < row["need"] and not row.get("fix"):
        text += f" ({row['reps']} of {row['need']} repetitions)"
    return text


def tail_against(row, competitor):
    tail = row.get("tail")
    if row["kind"] not in ("p50",) or not tail:
        return None
    if (tail >= 1) == (row["ratio"] >= 1):
        return None
    factor = tail if tail >= 1 else 1 / tail
    return (("Stalwart" if tail >= 1 else competitor), factor) if factor >= EQUAL_BELOW else None


def range_text(factors):
    (low, _), (high, high_at_least) = min(factors), max(factors)
    if factor_text(low) == factor_text(high) and not high_at_least:
        return factor_text(high)
    return f"{factor_text(low)} to {fmt_factor(high, high_at_least)}"


def category_headline(title, competitor, rows, load=False):
    decided = [(r, verdict(r[5], r[4])) for r in rows if r[5]]
    pending = len(rows) - len(decided)
    state = "reported later" if MISSING_TEXT != "pending" else "still running"
    tail = f" {pending} more {'test is' if pending == 1 else 'tests are'} {state}." if pending else ""
    if not decided:
        return f"**{title}: results are {'reported later' if MISSING_TEXT != 'pending' else 'still coming in'}.**"
    wins = [(v[1], v[2]) for _, v in decided if v[0] == "Stalwart"]
    others = [v for _, v in decided if v[0] not in ("Stalwart", None, "unknown")]
    verb = "handles more load than" if load else "is faster than"
    count = "both" if len(decided) == 2 else f"all {len(decided)}"
    if len(wins) == len(decided):
        lead = (f"Stalwart {verb} {competitor}, by {range_text(wins)}" if len(decided) == 1 else
                f"Stalwart {verb} {competitor} in {count} tests, by {range_text(wins)}")
    elif wins:
        lead = f"Stalwart {verb} {competitor} in {len(wins)} of {len(decided)} tests, by {range_text(wins)}"
    else:
        lead = f"{competitor} is faster in {len(others)} of {len(decided)} tests"
    return f"**{title}: {lead}.**{tail}"


def render_category(key, rows):
    _, title, competitor = next(c for c in CATEGORIES if c[0] == key)
    rows = [r for r in rows if r[0] == key]
    competitor = competitor or " or ".join(sorted({r[4] for r in rows}, reverse=True))
    out = [category_headline(title, competitor, rows, key == "throughput"), "", CATEGORY_METRIC[key], ""]
    mixed = len({r[4] for r in rows}) > 1
    quick = key in ("smtp", "delivery") and bool(QUICKACK)
    head = ["Test", "Stalwart", "Postfix or Dovecot" if mixed else competitor, "Higher" if key == "throughput" else "Faster"]
    head += ["Faster with a quickack client"] if quick else []
    out.append("| " + " | ".join(head) + " |")
    out.append("|" + "---|" * len(head))
    drift, fix_marks = False, set()
    for _, cell, op, label, comp, row in rows:
        name = f"{label} (vs {comp})" if mixed else label
        if cell in FIX_CELLS and row is not None:
            name += " " + FIX_CELLS[cell]
            fix_marks.add(FIX_CELLS[cell])
        if row is None:
            out.append(f"| {name} | {MISSING_TEXT} | {MISSING_TEXT} | |" + (" |" if quick else ""))
            continue
        unit = op if op in UNITS else ""
        cols = [name, fmt_value(row, "s", unit), fmt_value(row, "d", unit), result_text(row, comp)]
        if quick:
            cols.append(quickack_verdict(cell, op, comp))
        drift = drift or row["kind"] == "drift" or bool(row.get("drift"))
        out.append("| " + " | ".join(cols) + " |")
    if drift:
        out += ["", "\\* " + DRIFT_NOTE]
    for mark in sorted(fix_marks):
        out += ["", FIX_NOTES[mark].replace("](CAVEATS.md", "](report/CAVEATS.md")]
    return "\n".join(out) + "\n"


WINS_CONTEXT = {"large": "250,000-message mailbox, warm cache", "cold": "250,000-message mailbox, cold cache"}


def render_wins(rows):
    out = []
    for category, cell, op, label, comp, row in rows:
        if row is None:
            continue
        if category in WINS_CONTEXT:
            label = f"{label} ({WINS_CONTEXT[category]})"
        winner, factor, at_least = verdict(row, comp)
        values = f"{fmt_value(row, 'd', op if op in UNITS else '')} against {fmt_value(row, 's', op if op in UNITS else '')} for Stalwart"
        if winner == "unknown":
            out.append(f"- Not separated: {label} (both systems still met the SLO at the top of the ladder).")
        elif winner is None:
            out.append(f"- About equal (less than 1.1x apart). {label}: {comp} {values}.")
        elif winner != "Stalwart":
            mark = " " + FIX_CELLS[cell] if cell in FIX_CELLS else ""
            out.append(f"- **{winner}** is {fmt_factor(factor, at_least)} faster. {label}{mark}: {values}.")
        tail = tail_against(row, comp)
        if tail and tail[0] != "Stalwart":
            out.append(f"- At p99 (the slowest 1% of operations), **{tail[0]}** is {factor_text(tail[1])} faster. {label}: "
                       f"p99 {ms(row['d_p99'])} ms against {ms(row['s_p99'])} ms for Stalwart; at the median Stalwart is faster.")
    return "\n".join(out or ["- None so far: Stalwart is faster in every comparison measured."]) + "\n"


def render_tally(rows):
    tally = {"Stalwart": 0, "other": 0, "equal": 0, "unknown": 0}
    pending = 0
    for *_, comp, row in rows:
        if row is None:
            pending += 1
            continue
        winner = verdict(row, comp)[0]
        tally["Stalwart" if winner == "Stalwart" else "equal" if winner is None else winner if winner == "unknown" else "other"] += 1
    decided = len(rows) - pending
    final = MISSING_TEXT != "pending"
    text = (f"Across the {decided} headline comparisons measured{'' if final else ' so far'}, Stalwart is faster in {tally['Stalwart']}, "
            f"Postfix or Dovecot in {tally['other']}, {tally['equal']} {'is' if tally['equal'] == 1 else 'are'} about equal, and "
            f"{tally['unknown']} {'is' if tally['unknown'] == 1 else 'are'} not separated because both systems still kept up at "
            "the highest load tried.")
    state = "will be reported later" if final else ("is" if pending == 1 else "are") + " still running"
    return text + (f" {pending} {'comparison' if pending == 1 else 'comparisons'} {state}." if pending else "") + "\n"


SVG_STYLE = """<style>
.s{fill:#2a78d6}.c{fill:#eb6834}.sl{stroke:#2a78d6}.cl{stroke:#eb6834}
.t1{fill:#0b0b0b}.t2{fill:#52514e}.g{stroke:#e4e3df}.b{stroke:#8f8e89}.bg{fill:#fcfcfb}
text{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif;font-size:12px}
.h{font-weight:600;font-size:13px}.ttl{font-weight:600;font-size:15px}
@media (prefers-color-scheme: dark){.s{fill:#3987e5}.c{fill:#d95926}.sl{stroke:#3987e5}.cl{stroke:#d95926}
.t1{fill:#f0efec}.t2{fill:#c3c2b7}.g{stroke:#343432}.b{stroke:#6f6e69}.bg{fill:#1a1a19}}
</style>"""


def svg_doc(width, height, title, body):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" '
            f'role="img" aria-label="{html.escape(title)}"><title>{html.escape(title)}</title>{SVG_STYLE}'
            f'<rect class="bg" width="{width}" height="{height}" rx="6"/>' + "".join(body) + "</svg>\n")


def svg_factors(rows):
    items = []
    for key, title, _ in CATEGORIES:
        decided = [(r, verdict(r[5], r[4])) for r in rows if r[0] == key and r[5] and r[5]["bound"] != "unknown"]
        if decided:
            items.append(("head", title, None))
            items += [("row", r, v) for r, v in decided]
    if not items:
        return None
    logs = [math.log10(r[5]["ratio"]) for kind, r, _ in items if kind == "row"]
    up, down = max(1, math.ceil(max(logs))), max(1, math.ceil(-min(logs)))
    width, left, right, top = 820, 330, 50, 64
    plot = width - left - right
    scale = plot / (up + down)
    mid = left + down * scale
    y, body = top, []
    body.append(f'<text class="ttl t1" x="16" y="24">How many times faster, per test (log scale)</text>')
    body.append(f'<text class="t2" x="{mid + 8:.0f}" y="46">Stalwart faster &#8594;</text>')
    body.append(f'<text class="t2" x="{mid - 8:.0f}" y="46" text-anchor="end">&#8592; Postfix or Dovecot faster</text>')
    marks = []
    for kind, r, v in items:
        if kind == "head":
            y += 10
            body.append(f'<text class="h t1" x="16" y="{y + 12}">{html.escape(r)}</text>')
            y += 22
            continue
        _, cell, op, label, comp, row = r
        winner, factor, at_least = v
        log = math.log10(row["ratio"])
        x0, x1 = (mid, mid + log * scale) if log >= 0 else (mid + log * scale, mid)
        cls = "s" if log >= 0 else "c"
        label += " " + FIX_CELLS[cell] if cell in FIX_CELLS else ""
        tip = f"{label}: {result_text(row, comp).replace('**', '').replace(chr(92), '')}"
        text = "about equal" if winner is None else (">=" if at_least else "") + factor_text(factor)
        body.append(f'<text class="t2" x="24" y="{y + 13}">{html.escape(label)}</text>')
        marks.append(f'<rect class="{cls}" x="{x0:.1f}" y="{y + 3}" width="{max(x1 - x0, 1.5):.1f}" height="14" rx="3">'
                     f'<title>{html.escape(tip)}</title></rect>')
        tx, anchor = (x1 + 5, "start") if log >= 0 else (x0 - 5, "end")
        marks.append(f'<text class="t1" x="{tx:.1f}" y="{y + 14}" text-anchor="{anchor}">{text}</text>')
        y += 20
    grid = []
    for d in range(-down, up + 1):
        x = mid + d * scale
        grid.append(f'<line class="{"b" if d == 0 else "g"}" x1="{x:.1f}" y1="{top}" x2="{x:.1f}" y2="{y + 4}"/>')
        grid.append(f'<text class="t2" x="{x:.1f}" y="{y + 20}" text-anchor="middle">{10 ** abs(d):,}x</text>')
    height = fix_captions([r[1] for kind, r, _ in items if kind == "row"], grid, y + 34)
    return svg_doc(width, height, "How many times faster Stalwart or Postfix/Dovecot is, per test", body + grid + marks)


def axis_ms(value):
    return f"{value:g} ms" if value < 1000 else f"{value / 1000:g} s"


def svg_latency(rows):
    data = [r for r in rows if r[0] == "large" and r[5]]
    if not data:
        return None
    values = [v for r in data for v in (r[5]["s"], r[5]["d"])]
    lo = math.floor(math.log10(min(values) / 1000))
    hi = math.ceil(math.log10(max(values) / 1000))
    width, left, right, top = 820, 300, 50, 64
    plot = width - left - right
    def xpos(us):
        return left + (math.log10(us / 1000) - lo) / max(hi - lo, 1) * plot
    body = [f'<text class="ttl t1" x="16" y="24">250,000-message mailbox, warm cache: typical latency (p50, log scale)</text>',
            f'<circle class="s" cx="{left}" cy="42" r="5"/><text class="t2" x="{left + 10}" y="46">Stalwart</text>',
            f'<circle class="c" cx="{left + 90}" cy="42" r="5"/><text class="t2" x="{left + 100}" y="46">Dovecot</text>']
    y, marks = top, []
    for _, cell, op, label, comp, row in data:
        label += " " + FIX_CELLS[cell] if cell in FIX_CELLS else ""
        cy = y + 10
        xs, xd = xpos(row["s"]), xpos(row["d"])
        body.append(f'<text class="t2" x="16" y="{cy + 4}">{html.escape(label)}</text>')
        marks.append(f'<line class="b" x1="{min(xs, xd):.1f}" y1="{cy}" x2="{max(xs, xd):.1f}" y2="{cy}" stroke-width="2"/>')
        for x, cls, who, v in ((xs, "s", "Stalwart", row["s"]), (xd, "c", "Dovecot", row["d"])):
            marks.append(f'<circle class="{cls}" cx="{x:.1f}" cy="{cy}" r="5"><title>{html.escape(label)}: {who} {ms(v)} ms</title></circle>')
        y += 24
    grid = []
    for d in range(lo, hi + 1):
        x = left + (d - lo) / max(hi - lo, 1) * plot
        grid.append(f'<line class="g" x1="{x:.1f}" y1="{top}" x2="{x:.1f}" y2="{y}"/>')
        grid.append(f'<text class="t2" x="{x:.1f}" y="{y + 16}" text-anchor="middle">{axis_ms(10.0 ** d)}</text>')
    height = fix_captions([r[1] for r in data], grid, y + 30)
    return svg_doc(width, height, "Typical latency on a 250,000-message mailbox, Stalwart against Dovecot", body + grid + marks)


def write_charts(rows, report):
    charts = {"factors.svg": svg_factors(rows), "latency-250k.svg": svg_latency(rows)}
    os.makedirs(os.path.join(report, "charts"), exist_ok=True)
    for name, svg in charts.items():
        if svg is None:
            continue
        path = os.path.join(report, "charts", name)
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            f.write(svg)
        os.replace(tmp, path)


def collect_quickack(root):
    for run in sorted(glob.glob(os.path.join(root, "bench-*"))):
        for cdir in sorted(glob.glob(os.path.join(run, "cells", "*"))):
            labels = scan_cell(cdir)
            if labels:
                QUICKACK.setdefault(os.path.basename(cdir), labels)


def unique_runs(runs):
    seen = set()
    for run in runs:
        if cluster_of(run) not in seen:
            seen.add(cluster_of(run))
            yield run


def rtt_pairs(path):
    rtt = load(path) or []
    m = {(r.get("from"), r.get("to")): r.get("p50_us") for r in rtt}
    pairs = [(m.get(("load1", "stalwart")), m.get(("load1", "dovecot"))),
             (m.get(("load2", "stalwart")), m.get(("load2", "dovecot"))),
             (m.get(("stalwart", "sink")), m.get(("dovecot", "sink")))]
    diffs = [abs(a - b) for a, b in pairs if a is not None and b is not None]
    return pairs, (max(diffs) if diffs else None)


def render_rtt(runs):
    out = ["| Cluster | Region | load1 to Stalwart / P+D, p50 us | load2 to Stalwart / P+D, p50 us | Stalwart / P+D to sink, p50 us | Max difference us, start / end | Within 10 us | CPU (all hosts) |",
           "|---|---|---|---|---|---|---|---|"]
    for run in unique_runs(runs):
        cluster = cluster_of(run)
        pairs, worst = rtt_pairs(os.path.join(run, "rtt.json"))
        end_path = os.path.join(run, "rtt-end.json")
        _, worst_end = rtt_pairs(end_path) if os.path.exists(end_path) else (None, None)
        inventory = load(os.path.join(run, "hosts.json")) or {}
        region = ((inventory.get("regions") or {}).get("main") or {}).get("location") or REGIONS.get(cluster, "?")
        cpus = {(load(f) or {}).get("cpu_model", "?") for f in glob.glob(os.path.join(run, "hosts", "*.json"))}
        cpu = ", ".join(sorted(c.replace(" 96-Core Processor", "") for c in cpus)) or "?"
        cols = [" / ".join("-" if v is None else f"{v:.1f}" for v in p) for p in pairs]
        measured = [w for w in (worst, worst_end) if w is not None]
        ok = "-" if not measured else ("yes" if max(measured) <= RTT_TARGET_US else "**no**")
        spread = " / ".join("-" if w is None else f"{w:.1f}" for w in (worst, worst_end))
        out.append(f"| {cluster} | {region} | " + " | ".join(cols) + f" | {spread} | {ok} | {cpu} |")
    return "\n".join(out) + "\n"


def render_clusters(runs, meta, chosen):
    out = ["| Cluster | Region | Cells assigned | Cells with complete results | Pending | Ladder extensions |",
           "|---|---|---|---|---|---|"]
    by_group = {}
    for cell, m in meta.items():
        group = chosen[cell][0].split("+")[0] if cell in chosen else m.get("group") or "?"
        by_group.setdefault(group, []).append(cell)
    total = complete_total = 0
    for run in unique_runs(runs):
        cluster = cluster_of(run)
        cells = [c for c in by_group.get(cluster, []) if not c.endswith(EXT_SUFFIX)]
        extensions = ", ".join(sorted(c for c in by_group.get(cluster, []) if c.endswith(EXT_SUFFIX))) or "-"
        complete = 0
        for cell in cells:
            data = chosen.get(cell, (None, {}))[1]
            need = meta[cell].get("repetitions") or 3
            if all(sum(1 for r in data.get(l, []) if r.valid) >= need for l in expected_labels(meta[cell])):
                complete += 1
        total += len(cells)
        complete_total += complete
        inventory = load(os.path.join(run, "hosts.json")) or {}
        region = ((inventory.get("regions") or {}).get("main") or {}).get("location") or REGIONS.get(cluster, "?")
        out.append(f"| {cluster} | {region} | {len(cells)} | {complete} | {len(cells) - complete} | {extensions} |")
    out.append(f"| all | | {total} | {complete_total} | {total - complete_total} | |")
    return "\n".join(out) + "\n"


def render_flags(meta, chosen, duplicates, cvs):
    out = []
    high_cv, errors, partial, invalid = [], [], [], []
    for cell in sorted(chosen, key=natural):
        cluster, data = chosen[cell]
        m = meta.get(cell, {})
        need = m.get("repetitions") or 3
        cold = m.get("cache") == "cold"
        for entry in [] if cold or cell in FIX_CELLS else cvs.get((cell, cluster), []):
            if (entry.get("n") or 0) > 1 and (entry.get("cv") or 0) > CV_MAX:
                high_cv.append(f"{cell} ({cluster}) {TARGET_NAMES.get(entry['target'], entry['target'])}: CV {entry['cv']:.2f}")
        for label, reps in sorted(data.items()):
            name = TARGET_NAMES.get(label, label)
            bad = sum(1 for r in reps if not r.valid)
            if bad:
                invalid.append(f"{cell} ({cluster}) {name}: {bad} invalid repetitions")
            if (sum(1 for r in reps if r.valid) < need and (cell, label) not in PUBLISHED_REPS
                    and not (cell in FIX_CELLS and label in MAIN_LABELS)):
                partial.append(f"{cell} ({cluster}) {name}: {sum(1 for r in reps if r.valid)}/{need} valid repetitions")
            totals = {}
            for r in reps:
                for op, e in r.errors.items():
                    if e:
                        totals[op] = totals.get(op, 0) + e
            for op, e in sorted(totals.items()):
                errors.append(f"{cell} ({cluster}) {name} {op}: {e} errors")
    drift = []
    for cell in sorted(DRIFT_CELLS, key=natural):
        if cell not in chosen:
            continue
        op = next(iter(sorted({o for reps in chosen[cell][1].values() for r in reps for o in r.ops if o.startswith("imap.")
                                and o != "imap.select"})), None)
        history = HISTORY.get((cell, chosen[cell][0].split("+")[0]))
        row = summary_row(cell, op, meta, chosen) if op and history else None
        if row and row["kind"] == "drift":
            labels = DRIFT_LABELS.get((cell, chosen[cell][0].split("+")[0]))
            drifting = f" (rising: {', '.join(TARGET_NAMES.get(l, l) for l in labels)})" if labels else ""
            drift.append(f"{cell} ({chosen[cell][0]}) {op}{drifting}: P+D / Stalwart p50 {factor_text(row['ratio'])} in the repetition least favourable to Stalwart (repetition {row['index']}) "
                         f"({row['s_n']} / {row['d_n']} samples), "
                         f"{factor_text(row['median'])} median of the reported repetitions"
                         + ("" if row["pairs"] < 2 else ", per repetition " + ", ".join(factor_text(f) for f in row["per"])))
    for cell in sorted(RATE_DRIFT_CELLS & set(chosen), key=natural):
        reps = [r for r in chosen[cell][1].get("dovecot", []) if r.valid and r.best is not None]
        if len(reps) > 1:
            drift.append(f"{cell} ({chosen[cell][0]}) P+D: best rate per repetition "
                         + ", ".join(fmt_rate(r.best_rate, r.capped) for r in reps)
                         + f"; the summary uses the highest (least favourable to Stalwart), the median is {fmt_rate(median([r.best_rate for r in reps]), False)}")
    sections = [("Repetition CV above 0.10 after the automatic rerun", high_cv),
                ("State accumulation between repetitions (summary factors use the repetition least favourable to Stalwart)", drift),
                ("Operation errors in the reported step(s)", errors),
                ("Invalid repetitions (load generator bottleneck)", invalid),
                ("Incomplete repetitions", partial),
                ("Cells with results on more than one cluster (the first one is used; a label missing there comes from the next)", [f"{c}: {', '.join(cl)}" for c, cl in duplicates])]
    for title, items in sections:
        out.append(f"**{title}:** " + ("none." if not items else ""))
        out.extend(f"- {i}" for i in items)
        out.append("")
    return "\n".join(out)


def render_setup(meta, chosen):
    out = ["| Cell | Pair | System | Highest rate with connect p99 + greeting p99 under 1 s (median) | Per repetition |",
           "|---|---|---|---|---|"]
    for cell in SETUP_CELLS:
        cluster, data = chosen.get(cell, ("-", {}))
        if cell + EXT_SUFFIX in chosen:
            cluster += f" + {chosen[cell + EXT_SUFFIX][0]}"
        for label in expected_labels(meta.get(cell) or {}):
            reps = data.get(label)
            name = TARGET_NAMES.get(label, label)
            if not reps:
                out.append(f"| {cell} | {cluster} | {name} | {MISSING_TEXT} | |")
                continue
            rate, capped, points = setup_stats(reps, ext_reps(chosen, cell, label))
            text = "below the first step" if rate is None else fmt_rate(rate, capped)
            per = ", ".join(fmt_rate(p[0], p[1]) for p in points) or "-"
            out.append(f"| {cell} | {cluster} | {name} | {text} | {per} |")
    return "\n".join(out) + "\n"


def step_metrics(step, step_seconds):
    ops = step.get("ops") or {}
    session, message = ops.get("smtp") or {}, ops.get("smtp.message") or {}
    delivered = (message.get("count") or 0) / step_seconds if step_seconds else None
    return {"err": connection_error_rate(step) * 100, "m50": message.get("p50"), "m99": message.get("p99"),
            "s99": session.get("p99"), "met": bool(step.get("slo_met")), "del": delivered,
            "limited": bool((step.get("generator") or {}).get("dropped"))}


def render_step_table(meta, chosen):
    out = ["| System | Ladder (cluster) | Offered rate, connections/s | Repetitions | Failed sessions % (per repetition) | "
           "Messages accepted/s | Message p50 / p99 ms | Whole session p99 ms | SLO met as planned (reps) |",
           "|---|---|---|---|---|---|---|---|---|"]
    limited_seen = False
    for cell in sorted(STEP_TABLE_CELLS):
        for label in LABEL_ORDER:
            for part in (cell, cell + EXT_SUFFIX):
                cluster, data = chosen.get(part, ("-", {}))
                reps = [r for r in data.get(label, []) if r.steps]
                if not reps:
                    continue
                by_rate = {}
                for r in reps:
                    for step in r.steps:
                        by_rate.setdefault(round(step.get("target_rate") or 0, 2), []).append(
                            step_metrics(step, r.step_seconds))
                ladder = "continuation" if part.endswith(EXT_SUFFIX) else "planned"
                cluster = "+".join(sorted({r.cluster for r in reps}, key=natural))
                for rate in sorted(by_rate):
                    ms_list = by_rate[rate]
                    errs = [None if m["limited"] and not m["del"] else m["err"] for m in ms_list]
                    err = "-" if median(errs) is None else f"{median(errs):.2f}"
                    if len(errs) > 1:
                        err += " (" + ", ".join("-" if e is None else f"{e:.2f}" for e in errs) + ")"
                    s99 = median([m["s99"] for m in ms_list if m["s99"]])
                    delivered = median([m["del"] for m in ms_list])
                    limited = sum(m["limited"] for m in ms_list)
                    limited_seen = limited_seen or limited > 0
                    mark = f" (limited in {limited})" if limited else ""
                    out.append(f"| {TARGET_NAMES.get(label, label)} | {ladder} ({cluster}) | {rate:,.1f}{mark} | {len(ms_list)} | "
                               f"{err} | {'-' if delivered is None else f'{delivered:,.0f}'} | "
                               f"{ms(median([m['m50'] for m in ms_list]))} / {ms(median([m['m99'] for m in ms_list]))} | "
                               f"{ms(s99)} | {sum(m['met'] for m in ms_list)} / {len(ms_list)} |")
    if limited_seen:
        out.append("")
        out.append("\"Limited in N\": in N repetitions the load generator's in-flight limit filled during the step and "
                   "arrivals were dropped, so the step shows the server's backlog rather than the offered rate; a step in which no "
                   "message was accepted has no failure rate.")
    return "\n".join(out) + "\n"


def render_search_counts(meta, chosen):
    out = ["| Cell | Pair | Operation | Mean result count Stalwart / P+D |", "|---|---|---|---|"]
    cells = sorted((c for c in meta if c.startswith("c11-") or (c.startswith("l11-") and meta[c].get("cache") != "cold")),
                   key=natural)
    for cell in cells:
        cluster, data = chosen.get(cell, ("-", {}))
        ops = sorted({op for reps in data.values() for r in reps for op in r.ops if op.startswith("imap.search")})
        if not ops:
            out.append(f"| {cell} | - | | {MISSING_TEXT} |")
            continue
        for op in ops:
            means = []
            for label in MAIN_LABELS:
                value = median([(r.ops[op].get("items") or {}).get("mean") for r in data.get(label, [])
                                if r.valid and op in r.ops])
                means.append("-" if value is None else f"{value:,.1f}")
            out.append(f"| {cell} | {cluster} | {op} | {' / '.join(means)} |")
    return "\n".join(out) + "\n"


def render_probe(probe_root):
    files = sorted(glob.glob(os.path.join(probe_root, "*.json")))
    if not files:
        return "No probe-check results.\n"
    out = ["| Size | Probe | System | Delivery p50 / p95 / p99 ms | Probe RTT p50 / p95 / p99 ms | Samples |", "|---|---|---|---|---|---|"]
    rows = []
    for f in files:
        d = load(f) or {}
        m = re.match(r"pc-c02x-(\w+)-(imap_\w+)-(\w+)\.json", os.path.basename(f))
        if not m or not d.get("steps"):
            continue
        ops = d["steps"][0].get("ops", {})
        dl, pr = ops.get("smtp.delivery", {}), ops.get("smtp.probe_rtt", {})
        rows.append((m.group(1), m.group(2), m.group(3), dl, pr))
    order = {"4k": 0, "1m": 1}
    rows.sort(key=lambda r: (order.get(r[0], 9), r[1], LABEL_ORDER.index(r[2]) if r[2] in LABEL_ORDER else 9))
    for size, probe, target, dl, pr in rows:
        out.append(f"| {size.upper()} | {'NOOP poll' if probe == 'imap_poll' else 'STATUS poll'} | {TARGET_NAMES.get(target, target)} | "
                   f"{ms(dl.get('p50'))} / {ms(dl.get('p95'))} / {ms(dl.get('p99'))} | {ms(pr.get('p50'))} / {ms(pr.get('p95'))} / {ms(pr.get('p99'))} | {dl.get('count', '-')} |")
    return "\n".join(out) + "\n"


def render_charts(chosen):
    out = []
    for cache, cold in (("cold", "-cold"), ("warm", "")):
        for pattern, op, title in CHARTS:
            series = {}
            for label in ("stalwart", "dovecot"):
                values = []
                for size in SIZES:
                    cell = pattern.format(cold=cold, size=size)
                    reps = chosen.get(cell, (None, {}))[1].get(label)
                    if not reps:
                        p50 = None
                    elif cold:
                        p50 = cold_stats(reps, cell)["p50"]
                    else:
                        p50 = latency_stats(reps, op)["p50"]
                    values.append(None if p50 is None else round(p50 / 1000, 3))
                series[label] = values
            if any(v is None for vs in series.values() for v in vs):
                out.append(f"*{title}, {cache} cache: {MISSING_TEXT}.*\n")
                continue
            out.append("```mermaid")
            out.append("---")
            out.append("config:")
            out.append("  themeVariables:")
            out.append("    xyChart:")
            out.append('      plotColorPalette: "#2563eb, #dc2626"')
            out.append("---")
            out.append("xychart-beta")
            out.append(f'  title "{title}, {cache} cache: p50 ms (blue Stalwart, red P+D)"')
            out.append('  x-axis ["10k", "100k", "250k"]')
            out.append('  y-axis "p50 ms"')
            for label in ("stalwart", "dovecot"):
                out.append("  line [" + ", ".join(f"{v:g}" for v in series[label]) + "]")
            out.append("```\n")
    return "\n".join(out)


def main(argv):
    repo = argv[0]
    results = os.path.join(repo, "results", "c")
    probe = os.path.join(repo, "results", "c-probe-check")
    profile = os.path.join(repo, "scenarios", "profiles", "c-reduced.yaml")
    readme = os.path.join(repo, "README.md")
    report = os.path.join(repo, "report")
    stdout = False
    it = iter(argv[1:])
    for a in it:
        if a == "--results":
            results = next(it)
        elif a == "--probe":
            probe = next(it)
        elif a == "--profile":
            profile = next(it)
        elif a == "--readme":
            readme = next(it)
        elif a == "--report":
            report = next(it)
        elif a == "--stdout":
            stdout = True
        elif a == "--final":
            global MISSING_TEXT
            MISSING_TEXT = "reported later"
        else:
            sys.exit(f"readme-tables.sh: unknown argument {a}")
    runs, meta, chosen, duplicates, cvs = collect(results, profile)
    collect_quickack(os.path.join(os.path.dirname(os.path.abspath(results)), "c-quickack"))
    rows = summary_rows(meta, chosen)
    blocks = {
        "tally": render_tally(rows),
        "wins": render_wins(rows),
        "clusters": render_clusters(runs, meta, chosen),
        "rtt": render_rtt(runs),
        "headline": render_headline(meta, chosen),
        "flags": render_flags(meta, chosen, duplicates, cvs),
        "probe": render_probe(probe),
        "supplementary": render_setup(meta, chosen),
        "mpc10-steps": render_step_table(meta, chosen),
        "search-counts": render_search_counts(meta, chosen),
        "charts": render_charts(chosen),
    }
    for key, _, _ in FAMILIES:
        blocks[f"family:{key}"] = render_family(key, meta, chosen)
    for key, _, _ in CATEGORIES:
        blocks[f"cat:{key}"] = render_category(key, rows)
    if STALE:
        print(f"readme-tables.sh: WARNING: {len(STALE)} multi-host throughput reps still carry doubled rates; run "
              ".ignore/tools/remerge.sh first:", file=sys.stderr)
        for rdir in STALE:
            print(f"  {os.path.relpath(rdir, repo)}", file=sys.stderr)
    if stdout:
        for name, text in blocks.items():
            sys.stdout.write(f"<!-- readme:{name} -->\n{text}\n")
        return
    write_charts(rows, report)
    files = [readme] + sorted(glob.glob(os.path.join(report, "*.md")))
    placed = set()
    for path in files:
        with open(path) as f:
            body = f.read()
        changed = body
        for name, text in blocks.items():
            begin, end = f"<!-- readme:{name}:begin -->", f"<!-- readme:{name}:end -->"
            pattern = re.compile(re.escape(begin) + ".*?" + re.escape(end), re.S)
            if pattern.search(changed):
                placed.add(name)
                changed = pattern.sub(lambda _, t=text, b=begin, e=end: f"{b}\n{t}\n{e}", changed)
        if changed != body:
            with open(path, "w") as f:
                f.write(changed)
            print(f"readme-tables.sh: updated {os.path.relpath(path, repo)}", file=sys.stderr)
    print(f"readme-tables.sh: {len(placed)} blocks, {len(chosen)} cells with results, {len(meta)} cells listed",
          file=sys.stderr)
    missing = [name for name in blocks if name not in placed]
    if missing:
        print(f"readme-tables.sh: no markers for {', '.join(missing)}", file=sys.stderr)


main(sys.argv[1:])
PY
