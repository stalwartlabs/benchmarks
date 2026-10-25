# Methodology

Part of the Stalwart vs Postfix and Dovecot comparison. Start at the [README](../README.md).

## 1. Setup

### 1.1 Hardware and placement

One cluster is five VMs in one Azure region, in one proximity placement group:

| Host | VM size | vCPU / RAM | Storage | Role |
|---|---|---|---|---|
| stalwart | Standard_D8ads_v7 | 8 / 32 GiB | 440 GB local NVMe, XFS, `noatime` | Stalwart (all data on the NVMe) |
| dovecot | Standard_D8ads_v7 | 8 / 32 GiB | 440 GB local NVMe, XFS, `noatime` | Postfix and Dovecot (queue, mdbox, indexes and FTS on the NVMe) |
| load1, load2 | Standard_D16as_v7 | 16 / 64 GiB | network disk | mailbench; both drive whichever system is under test |
| sink | Standard_D2as_v7 | 2 / 8 GiB | network disk | sink MTA for relay tests, lab DNS stub (Unbound, rbldnsd) |

Every host is checked to be an AMD EPYC 9V45 (Zen 5) before anything is installed (`scripts/run-track.sh`, phase `prepare`). Ubuntu 24.04.5 LTS, kernel 7.0.0-1017-azure, identical OS tuning on every host ([SETTINGS.md, section 1](SETTINGS.md#1-os-identical-on-every-host-configos-provisionos-tuningsh)). Hosts are pinned to UTC.

The load hosts are never tied to one system: each cell's runs for both systems use the same load host(s), so a load host's placement cannot favour one side.

### 1.2 Clusters and network symmetry

The reduced cell set ([section 2.7](#27-reduced-cell-set)) ran on parallel clusters, each a full copy of the setup above in its own region. Regions were picked for free quota only: every byte of a cell stays inside one placement group, so the region does not enter the results. Each cell keeps both systems on one cluster; a cell's repetitions never mix clusters.

Round trips are measured right after allocation from every host to every other host (TCP 64-byte ping-pong, 2,000 samples per directed pair, `rtt.json` in each run). The target per cluster: p50 from each load host to Stalwart and to Postfix + Dovecot within 10 us of each other, and the same for both servers to the sink. Clusters outside the target were recreated (at most twice). The table is the published record.

<!-- readme:rtt:begin -->
| Cluster | Region | load1 to Stalwart / P+D, p50 us | load2 to Stalwart / P+D, p50 us | Stalwart / P+D to sink, p50 us | Max difference us, start / end | Within 10 us | CPU (all hosts) |
|---|---|---|---|---|---|---|---|
| c1 | westus3 | 79.0 / 77.6 | 68.1 / 67.8 | 85.7 / 85.4 | 1.4 / 1.5 | yes | AMD EPYC 9V45 |
| c2 | eastasia | 64.7 / 64.3 | 53.7 / 52.9 | 67.5 / 66.8 | 0.8 / 3.1 | yes | AMD EPYC 9V45 |
| c3 | brazilsouth | 62.0 / 60.9 | 62.2 / 59.8 | 79.4 / 80.2 | 2.4 / 6.6 | yes | AMD EPYC 9V45 |
| c4 | southafricanorth | 54.8 / 53.8 | 66.0 / 64.6 | 60.5 / 60.6 | 1.4 / 2.0 | yes | AMD EPYC 9V45 |
| c5 | southcentralus | 85.9 / 89.9 | 92.0 / 91.7 | 94.4 / 94.7 | 4.0 / 3.5 | yes | AMD EPYC 9V45 |
| c6 | koreacentral | 64.1 / 56.6 | 64.0 / 63.7 | 67.6 / 66.6 | 7.5 / 8.1 | yes | AMD EPYC 9V45 |
| c7 | australiaeast | 57.3 / 64.5 | 63.7 / 64.0 | 66.6 / 67.5 | 7.2 / 9.2 | yes | AMD EPYC 9V45 |
| c8 | swedencentral | 77.6 / 78.0 | 81.1 / 78.0 | 67.5 / 65.5 | 3.1 / 2.6 | yes | AMD EPYC 9V45 |
| c9 | germanywestcentral | 78.4 / 79.8 | 58.5 / 61.6 | 61.2 / 67.7 | 6.5 / 5.3 | yes | AMD EPYC 9V45 |
| c10 | spaincentral | 55.6 / 56.3 | 58.5 / 55.1 | 66.5 / 67.8 | 3.4 / 1.8 | yes | AMD EPYC 9V45 |
| c11 | italynorth | 64.3 / 65.1 | 65.1 / 62.9 | 67.1 / 68.3 | 2.2 / 2.3 | yes | AMD EPYC 9V45 |
| c12 | westeurope | 52.5 / 78.7 | 78.8 / 69.5 | 68.3 / 79.9 | 26.2 / 26.1 | **no** | AMD EPYC 9V45 |
| c13 | francecentral | 64.7 / 64.5 | 64.7 / 64.0 | 69.1 / 67.7 | 1.4 / 2.5 | yes | AMD EPYC 9V45 |
| c14 | northeurope | 61.8 / 60.5 | 62.2 / 59.9 | 64.7 / 66.7 | 2.3 / 2.6 | yes | AMD EPYC 9V45 |
| c15 | northcentralus | 53.9 / 56.0 | 55.0 / 55.6 | 70.2 / 70.3 | 2.1 / 3.4 | yes | AMD EPYC 9V45 |
| c16 | japaneast | 63.1 / 77.4 | 66.0 / 78.9 | 81.0 / 59.0 | 22.0 / 22.3 | **no** | AMD EPYC 9V45 |
| c18 | southeastasia | 63.9 / 65.9 | 64.3 / 68.0 | 64.8 / 68.3 | 3.7 / 3.6 | yes | AMD EPYC 9V45 |
| c19 | uaenorth | 65.5 / 62.1 | 65.4 / 62.4 | 66.8 / 67.2 | 3.4 / 0.9 | yes | AMD EPYC 9V45 |
| c20 | eastus2 | 75.5 / 64.0 | 75.8 / 77.0 | 77.4 / 79.9 | 11.5 / 10.8 | **no** | AMD EPYC 9V45 |
| c23 | westus2 | 67.7 / 65.0 | 67.9 / 63.7 | 72.9 / 72.1 | 4.2 / 2.1 | yes | AMD EPYC 9V45 |
| c26 | eastus | 78.4 / 80.0 | 78.2 / 79.3 | 81.2 / 81.6 | 1.6 / - | yes | AMD EPYC 9V45 |

<!-- readme:rtt:end -->

Clusters outside the target are marked **no**; each is listed with the tests it ran and why the asymmetry does not change their result in [CAVEATS.md, section 8](CAVEATS.md#8-clusters-network-symmetry-and-repetitions). "Max difference" is the largest of the three p50 differences (load1, load2 and the server-to-sink pair), measured when the cluster was created (start) and, where available, before it was deleted (end). All hosts of every cluster are AMD EPYC 9V45.

Cell assignment and progress per cluster:

<!-- readme:clusters:begin -->
| Cluster | Region | Cells assigned | Cells with complete results | Pending | Ladder extensions |
|---|---|---|---|---|---|
| c1 | westus3 | 10 | 10 | 0 | - |
| c2 | eastasia | 9 | 9 | 0 | - |
| c3 | brazilsouth | 36 | 31 | 5 | - |
| c4 | southafricanorth | 6 | 5 | 1 | - |
| c5 | southcentralus | 59 | 59 | 0 | - |
| c6 | koreacentral | 25 | 25 | 0 | - |
| c7 | australiaeast | 26 | 26 | 0 | - |
| c8 | swedencentral | 34 | 31 | 3 | - |
| c9 | germanywestcentral | 8 | 8 | 0 | - |
| c10 | spaincentral | 4 | 4 | 0 | - |
| c11 | italynorth | 5 | 4 | 1 | - |
| c12 | westeurope | 1 | 1 | 0 | - |
| c13 | francecentral | 10 | 10 | 0 | - |
| c14 | northeurope | 9 | 9 | 0 | - |
| c15 | northcentralus | 3 | 3 | 0 | c03-mpc10-ext |
| c16 | japaneast | 0 | 0 | 0 | - |
| c18 | southeastasia | 3 | 3 | 0 | c03-ext |
| c19 | uaenorth | 3 | 3 | 0 | - |
| c20 | eastus2 | 0 | 0 | 0 | - |
| c23 | westus2 | 5 | 5 | 0 | - |
| c26 | eastus | 0 | 0 | 0 | c17-ext |
| all | | 256 | 246 | 10 | |

<!-- readme:clusters:end -->

### 1.3 Versions

| Component | Version | Source |
|---|---|---|
| Stalwart | 1.0.0, commit `90b8620c934a703064d59be083203f577c03a5da` | built for this benchmark ([section 1.4](#14-stalwart-build)) |
| Postfix | 3.11.7 | built from source, SHA-256 pinned in `versions.env`, Postfix's own default compiler flags (generic x86-64), `-DUSE_TLS -DUSE_SASL_AUTH` |
| Dovecot CE | 2.4.5 (package `2:2.4.5-2+ubuntu24.04`, build 0cbb641e3e) | repo.dovecot.org packages (generic x86-64), fts_flatcurve included |
| OpenSSL (Postfix, Dovecot) | 3.0.13 | Ubuntu 24.04 |
| TLS in Stalwart | rustls with aws-lc-rs | Stalwart dependencies |
| mailbench | 0.1.0 | `loadgen/`, built on each load host |
| Unbound / rbldnsd (DNS stub) | 1.19.2 / 1.0~20210120-2 | Ubuntu 24.04 |
| OS | Ubuntu 24.04.5 LTS, kernel 7.0.0-1017-azure | Azure image |

Every run records the versions found on its hosts (`results/c/RUN/versions.json`) and the effective configuration files (`results/c/RUN/configs/HOST/`).

### 1.4 Stalwart build

- Source: `$code/stalwart_dev` at commit `90b8620c934a703064d59be083203f577c03a5da`, exported with `git archive` (never built inside a working tree). The crate reports version 1.0.0. Upstream has no v1.0 tag yet (the latest tag at the time of writing is v0.16.27); see [REPRODUCE.md, section 3](REPRODUCE.md#3-versions-and-the-v10-gap).
- Features: `rocks postgres foundationdb redis s3 enterprise`. The benchmark runs without an Enterprise license ([CAVEATS.md, section 10](CAVEATS.md#10-build-and-configuration-differences)), so the enterprise code paths are compiled in but inactive.
- Release profile with fat LTO, `codegen-units = 1`, `opt-level = 3`, `strip = true`, `panic = unwind`. `RUSTFLAGS="-C target-cpu=znver5"`; C and C++ dependencies (RocksDB among them) with `-march=znver5` through gcc-14 14.2.0 (gcc 13.3, Ubuntu's default, rejects `-march=znver5`). No PGO, no BOLT.
- Compiler: rustc 1.98.0 (stable, LLVM 22.1.8). The plan called for the current stable, rustc 1.99.1 (LLVM 23.1.1), but its final fat-LTO step dies with SIGILL inside libLLVM itself (an LLVM trap in SelectionDAG DAGCombine during instruction selection, same offset in two runs; not a missing CPU feature in generated code). 1.98.0 builds the same source with the same flags cleanly, so the benchmark binary uses it.
- Main binary, used for every row not marked ‡, § or ¶, installed on every cluster: SHA-256 `f976519d83f8b463b0882968a4902a96fddfa8d1d576164a0326f258a3fe7ba4` (recorded per run in `versions.json`). It needs Zen 5 and `libfdb_c` on the host (FoundationDB 7.4 client; unused in track C).
- Rows marked ‡: Stalwart build SHA-256 `2d80f00b371faf46b35e8422418b49b9b154c157445b743132fe896d684718ac`, same release flags (fat LTO, `codegen-units = 1`, `znver5`, rustc 1.98.0). Used for the nine warm STORE tests on large mailboxes (l13, cluster c6; 2 Stalwart runs and 4 Postfix + Dovecot runs of 200 samples, alternated) and five STORE tests on regular mailboxes (c13 single-session `\Seen` and `\Flagged` on a range of 100 and on all messages, and 16-session `\Seen` on a range of 100; cluster c3; 1 run of 10,000 samples per system). Postfix + Dovecot were measured in the same session on the same cluster. Raw results: `results/c-store-build/`.
- Rows marked §: Stalwart build SHA-256 prefix `8b3d762ad6c5f8a8`, same release flags. Used for three APPEND tests (c16 with 64 KB messages on one and on 16 sessions, 2 runs per system, and with 4 KB messages on 16 sessions, 1 run per system), on cluster c8, with Postfix + Dovecot measured in the same session. The `fsync=always` column of these rows comes from cluster c6. Raw results: `results/c-append-build/`.
- Rows marked ¶: Stalwart build SHA-256 `a665cdfa8183c0692097e766bcb7018d1db8424d1462ebe166fb29b0a5061c8e`, same release flags. Used for three SELECT QRESYNC tests (c09 one session with 100 and with 0 flag changes, 16 sessions with 100 changes), on cluster c3, 3 interleaved runs per system of 10,000 samples after a 60 s warm-up, with Postfix + Dovecot measured in the same session. Raw results: `results/c-qresync-build/`.

This is an asymmetry and it is deliberate: Stalwart is compiled for the exact CPU, Postfix and Dovecot are generic x86-64 builds as distributed (Postfix with its own default flags, Dovecot from its official packages). A `-march=znver5` build of Postfix and Dovecot was not tested.

## 2. Test procedure

### 2.1 Systems under test

- **Stalwart**: one process, RocksDB as data, blob, full-text search and in-memory store (everything on the local NVMe), configuration applied with `stalwart-cli apply` from `config/stalwart/fairness.ndjson`. Spam filter, sender authentication checks, DKIM signing, throttles, auto-ban, calendar scheduling, tracing and metrics stores are off ([SETTINGS.md, section 2](SETTINGS.md#2-stalwart-configstalwartfairnessndjson-applied-with-stalwart-cli-apply)).
- **Postfix + Dovecot**: Postfix receives on 25, 465 and 587 and delivers over LMTP (unix socket) to Dovecot; Dovecot serves IMAP on 993 with mdbox, `mailbox_list_index`, `fts_flatcurve` with `fts_autoindex = yes`, and authenticates Postfix SASL. Same work per message as Stalwart: no milters, no postscreen, no restrictions beyond relay control ([SETTINGS.md, section 3](SETTINGS.md#3-postfix-3117-configpostfix), B.4).

Both systems use the same certificate (ECDSA P-256), TLS 1.3 only, one cipher suite (TLS_AES_256_GCM_SHA384), X25519, the same SHA512-CRYPT hashes, the same folders and the same lab DNS stub. [FAIRNESS.md, section 2](FAIRNESS.md#2-fairness-checklist) is the full symmetry check.

### 2.2 Dataset

Deterministic from a seed (20261025) and identical on both servers; each server is seeded over IMAP APPEND and then verified (folder counts for every account and SHA-256 of sampled messages against the regenerated dataset; `results/c/RUN/seed/verify-*.json`).

- 1,000 regular users with Zipf (s = 1) mailbox sizes, mean 200 messages (min 5, max 20,000), 192,683 messages in total, in INBOX, Sent (15%), Archive (20%), Trash (4%), Lists/Dev (3%), Lists/Announce (2%) and Receipts (1%).
- Three large accounts: large10k, large100k (with 20 extra folders holding 50,000 messages) and large250k.
- Corpus: a 50,000-word vocabulary with Zipf (s = 1.07) frequencies (about 40 English function words at the top, then seeded pseudo-words), so search terms by rank have realistic hit rates. Message sizes log-normal (median 8 KB, sigma 0.6); 1% carry a 100 KB to 2 MB base64 attachment; 35% are replies with In-Reply-To/References and "Re:" subjects; 30% of senders are other users, 70% come from 5,000 external contacts (Zipf); dates span two years. Fixed 4 KB, 64 KB and 1 MB messages sit in a `Buckets` folder of the first 100 users and of the large accounts for the size-specific tests.
- Passwords are derived from the seed; one SHA512-CRYPT hash (5,000 rounds) per account is generated once and loaded into both servers.

### 2.3 Load generation

mailbench runs on the load hosts, starts at a wall-clock time agreed by all load hosts, and writes one JSON result per run ([section 4](#4-result-files)).

- Closed loop for latency cells: 1 or 16 sessions, no think time, 10,000 samples per repetition for regular cells (1,000 for 1 MB cells), a 30-minute cap per run.
- Open loop for throughput cells (C3, C6, C17): Poisson arrivals at the step rate across both load hosts (each host takes half the rate and a disjoint half of the users); latency counted from the scheduled arrival.
- TLS 1.3 only, X25519 only, certificate not verified, session resumption off: every measured connection is a full TLS handshake on both systems.
- Identical work on both servers: each session reseeds its random stream from the dataset seed, the cell id and the session index when the measurement window opens. The users, folders, ranges and search terms of measured operations are the same on both servers, no matter how many operations each completed during the time-based warm-up.
- Sessions never share a mailbox where that would interfere (C2 probes, write tests); users are partitioned among sessions.

### 2.4 Interleaving, warm-up, drain and repetitions

For every cell, on its cluster:

1. Repetition 1 on Stalwart, then repetition 1 on Postfix + Dovecot, then repetition 2 on each, and so on (A B A B on the same VM pair and the same load host(s)). Only the system under test is loaded; the other one is idle on its own VM.
2. Before every run, background work is drained on both servers (`provision/ctl.sh drain`: queues empty, index queues idle).
3. Every run starts with a time-based warm-up that is not measured: 60 s for regular cells, 30 s for large warm cells, none for cold cells (their single sample follows the cold cycle directly).
4. After the main repetitions of a cell, its `fsync=always` variant (where the cell has one) runs with the same interleaving: the variant is applied to Dovecot, its repetitions run, and the default is restored.
5. Repetitions: 3 for regular cells, 2 for large warm cells, 10 for cold cells (one sample each), 1 for c02-idle.
6. Per-repetition cleanup: after every run of the 1 MB SMTP cells (c01-1m, c02-1m), the SMTP throughput cells (c03, c03-ext, c03-mpc10-ext) and C15 (EXPUNGE), the load-test messages are deleted over IMAP on both servers and Dovecot runs `doveadm purge -A` (untimed). No other cell gets a cleanup between repetitions. A check of every cell for results drifting with the repetition order found drift in four large-mailbox MOVE and EXPUNGE cells, in Postfix + Dovecot's inbound throughput (c03) and in some EXPUNGE cells on regular mailboxes; these are summarised from the repetition least favourable to Stalwart ([CAVEATS.md, section 6](CAVEATS.md#6-state-accumulation-in-dovecots-mdbox)).

A repetition that failed for an infrastructure reason is retried on the same VM pair after the same drain (and cold cycle), so a retried repetition can run out of the strict A B order.

### 2.5 Quiet windows

Stalwart v1.0 runs daily maintenance by default: expunge at 00:00, data cleanup at 02:00, blob cleanup at 04:00 (host local time, which is UTC on every host). No run (warm-up plus measurement) may overlap 23:55 to 00:30, 01:55 to 02:30 or 03:55 to 04:30 UTC; the runner estimates each run's length and waits when it would cross a window (`quiet-waits.tsv` per run). Any run whose measured window overlapped a blocked window anyway is rerun, with one exception: one Dovecot repetition ended one minute inside the guard window before 04:00, before the job started, and was kept. Dovecot has no scheduled jobs; `doveadm purge` is never run during a measurement. Cron, logrotate, sysstat, apt timers and the other shared timers are disabled on every host.

### 2.6 Validity rules and the error check

- A run is **invalid** when the load generator may have been the bottleneck: host CPU mean above 70% (whole host, from `/proc/stat`), more than 1% of open-loop arrivals late by more than 10 ms, or any dropped arrival. Invalid runs are kept on disk, counted in the tables and excluded from the statistics ([RESULTS.md, section 14](RESULTS.md#14-flags-cv-errors-incomplete-cells) lists any).
- **valid = true only covers the generator.** Operation errors (protocol errors, timeouts, rejected commands) are a separate check: `scripts/check-errors.sh results/c/RUN` lists every run with errors in its reported step(s), and every listed run was examined. Errors are published in the tables and explained in [CAVEATS.md, section 11](CAVEATS.md#11-errors-that-are-not-failures-of-the-measured-operation).
- **Repetition spread**: when the CV of the per-repetition p50 of any operation exceeds 0.10, the cell's repetitions are rerun once (the first attempt is kept under `attempt1-*`). If the CV is still above 0.10 the cell is published and flagged ([RESULTS.md, section 14](RESULTS.md#14-flags-cv-errors-incomplete-cells)). Cold cells are excluded from the CV rule: with one cold sample per repetition, their spread is part of the result and is shown as median, p90 and maximum.
- **Disk**: a run that pushes a data disk above 80% is not used.
- **Throughput SLO**: a ladder step meets the SLO when the p99 of every SLO label is under the limit and the error rate of those labels is at most 0.1%; the reported rate is the highest valid step that met it, and the cell's value is the median over repetitions. c03-mpc10's SLO label is the per-message latency inside the session, which does not count failed sessions, so that test is reported step by step instead of as one rate ([CAVEATS.md, section 5](CAVEATS.md#5-10-messages-per-connection-test)).
- **Saturated steps**: a step above the reported rate that drops arrivals after the SLO was already missed marks server saturation and does not invalidate the repetition; a repetition is invalid only when the generator limited a step at or below the reported rate ([CAVEATS.md, section 4](CAVEATS.md#4-throughput-lower-bounds-saturation-and-acceptance)).
- **Ladder ceilings**: when a repetition met the SLO at the top planned step, its rate is a lower bound. Such ladders are continued (`scenarios/c-ext/`, same step timing and SLO, starting at the old top step); a value that is still a lower bound is printed as ">=", and a factor computed from it as "at least" ([CAVEATS.md, section 4](CAVEATS.md#4-throughput-lower-bounds-saturation-and-acceptance)).
- **Acceptance, not delivery**: throughput counts SMTP acceptance on both systems; delivery follows from each server's queue, and every run starts with drained queues ([CAVEATS.md, section 4](CAVEATS.md#4-throughput-lower-bounds-saturation-and-acceptance)).

### 2.7 Reduced cell set

The full matrix (348 cells) would have taken about 250 hours serially. The published results use a reduced set of 256 cells (`scenarios/profiles/c-reduced.yaml`, applied with `--profile` on both listing and running):

- c02-idle: one cell instead of twelve (4 KB, 1 session, 1 recipient, 500 samples, 1 repetition); Dovecot needs 0.5 s per sample there by design ([RESULTS.md, section 2](RESULTS.md#2-c2-smtp-to-inbox-delivery-latency)).
- The `fsync=always` variant only on the write families (C1 to C3, C13 to C17), not on read-only IMAP cells or large-mailbox cells.
- Large mailboxes, warm: 2 repetitions; 50 samples for the 10% COPY, MOVE and EXPUNGE cells.
- Large mailboxes, cold: only SELECT, FETCH 1:* FLAGS, SEARCH BODY common, SORT DATE and STORE, 10 repetitions of one cold sample each.
- The 60 s warm-up is kept everywhere.

The cells run on many identical clusters in parallel, split by scenario file, with these constraints: SMTP cells never run before IMAP cells on the same cluster (they grow INBOXes); every large-mailbox scaling curve (one operation over 10k, 100k and 250k) stays on one cluster; cold cells have their cluster to themselves; throughput cells get both load hosts of their cluster. Within a cell, both systems and all repetitions share one VM pair; cells of one family can come from different clusters, and the tables name the cluster of every cell. The exceptions within a cell are the Dovecot `fsync=always` variants of c03 and of the c03-mpc10 continuation, which ran on separate clusters.

### 2.8 Statistics

Each run's latencies go into an HdrHistogram (microsecond resolution). Tables report, per cell, operation and system, the median over valid repetitions of each repetition's p50, p95 and p99; cold cells report the median, p90 and maximum of their cold samples ([RESULTS.md, section 13](RESULTS.md#13-large-mailboxes-cold-cache)). Throughput: median over repetitions of the best rate (">=" when the median repetition topped out). Where state accumulated between repetitions, summary factors use the repetition least favourable to Stalwart and also give the median and range ([CAVEATS.md, section 6](CAVEATS.md#6-state-accumulation-in-dovecots-mdbox)). The raw histograms are in every result file, so other aggregations can be computed from the published data.

## 3. Limitations

- **Cloud VMs.** No access to hardware performance counters, possible noisy neighbours, and VM-to-VM placement varies between allocations. The design limits the effect (same VM pair, interleaved repetitions, published RTT per cluster, CV check) but does not remove it. Absolute numbers on other hardware will differ.
- **Cold cache is a page-cache drop plus a service restart.** It empties the OS page cache and the servers' in-process caches, but not the NVMe's own cache or the hypervisor's. Ten cold samples per cell and system are enough for the median, not for tail percentiles.
- **Synthetic corpus.** Message bodies use a Zipf vocabulary of pseudo-words, not real mail; search hit rates are realistic by rank, but tokenizer behaviour on real text and real attachments was not tested.
- **One node each.** No replication, no clustering; Stalwart's distributed storage backends are covered by the storage backend benchmarks (in preparation).
- **Durability is not equal** ([FAIRNESS.md, section 1.1](FAIRNESS.md#11-durability-this-favours-stalwart)).
- **Not tested here**: POP3, ManageSieve, JMAP, CalDAV/CardDAV, spam filtering and authentication checks (all off), TLS session resumption, IMAP COMPRESS, Postfix or Dovecot built for Zen 5, Dovecot `mail_compress`, different `mdbox_rotate_size`.

## 4. Result files

```
results/c/RUN/
  cells.json                    cells listed for this cluster (mailbench scenarios --profile ... --group ...)
  cells/CELL/LABEL/repN/        LABEL is stalwart, dovecot or dovecot+fsync-always
    merged.json                 mailbench result (schema mailbench/1), shards merged
    meta.json                   runner metadata (validity, start time, hosts)
  cells/CELL/cv-main.json       repetition CV per system (and cv-variant.json)
  cells/CELL/attempt1-main/     first attempt, kept when a CV rerun replaced it
  cells/CELL-ext/               ladder continuations (scenarios/c-ext/)
  rtt.json                      RTT between every pair of hosts
  hosts/HOST.json               host facts (CPU, memory, kernel, disks, schedulers)
  configs/HOST/                 effective configuration files
  versions.json                 component versions per host
  seed/verify-*.json            dataset verification per server
  quiet-waits.tsv               waits for the quiet windows
```

The per-load-host results that `merged.json` is built from, the `vmstat` logs of every host during each run, and runs not used for the published tables are not in the repository, to keep it small; they are available on request.

Result JSON: latencies in microseconds; latency cells have one step, throughput cells one step per ladder rate with `best_step` and `best_rate`; every operation has count, errors, error kinds and samples, throughput, mean, min, p50, p90, p95, p99, p99.9, max and the HdrHistogram (base64, deflate).

Operation labels:

| Label | From | To |
|---|---|---|
| `smtp` | TCP connect | the last 250 (phases: connect, greeting with banner and first EHLO, tls including STARTTLS and the second EHLO, auth, command) |
| `smtp.message` | MAIL FROM | 250 after DATA, per message |
| `smtp.delivery` | TCP connect of the sending session | message visible in every recipient's INBOX (C2) |
| `smtp.probe_rtt` | NOOP sent | NOOP reply, for the probe that saw the message (C2 resolution) |
| `smtp.relay` | TCP connect | message accepted by the sink MTA (C5) |
| `imap.login` | TCP connect | LOGOUT completed (phases: connect, tls, greeting, auth, command) |
| `imap.list`, `imap.status_all` | command sent | tagged OK (STATUS over every folder) |
| `imap.select`, `imap.select_qresync` | SELECT sent | tagged OK |
| `imap.select_cold` | SELECT sent on a fresh connection after the cold cycle | tagged OK (cold cells: the mailbox open) |
| `imap.cold_op` | the first operation after `imap.select_cold` | tagged OK (cold cells: the l10 to l13 cold value) |
| `imap.fetch`, `imap.search.NAME`, `imap.sort`, `imap.thread` | command sent | tagged OK |
| `imap.store`, `imap.copy`, `imap.move`, `imap.expunge`, `imap.uid_expunge`, `imap.append` | command sent | tagged OK |
| `mixed.*` | each step of a C17 session | its tagged OK; `mixed.session` is the whole session |
