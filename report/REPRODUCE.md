# Reproducing the benchmark

Part of the Stalwart vs Postfix and Dovecot comparison. Start at the [README](../README.md).

## 1. Requirements

An Azure subscription with about 50 vCPU of D-family v7 quota per cluster in a region that offers Zen 5 (EPYC 9V45) D8ads_v7, D16as_v7 and D2as_v7, the `az` CLI logged in, `jq`, `python3` and `ssh` locally. Nothing in this repository needs credentials beyond the Azure login.

## 2. One cluster end to end

```sh
# 1. VMs, network and proximity placement group; prints work/RUN/hosts.json
infra/azure/up.sh infra/topologies/c.json --run bench-c1 --location main=westus3

# 2. Prepare, binary, provision, seed, bench, collect, report
STALWART_BINARY=/path/to/stalwart \
BENCH_SCENARIOS=scenarios/c \
BENCH_SCENARIO_PROFILE=scenarios/profiles/c-reduced.yaml \
BENCH_SCENARIO_GROUP=c1 \
  scripts/run-track.sh work/bench-c1/hosts.json

# 3. README and report/ tables from every results/c/bench-c*/ directory
scripts/readme-tables.sh

# 4. Tear down
infra/azure/down.sh infra/topologies/c.json --run bench-c1
```

- `BENCH_SCENARIO_GROUP` selects one cluster's share (the group names in `scenarios/profiles/c-reduced.yaml`); leave it out to run all 256 cells on one cluster.
- Every phase of `run-track.sh` is resumable; finished cells are skipped. Results land in `results/c/RUN/`.
- `STALWART_BINARY` (local file) or `STALWART_BINARY_URL` installs a prebuilt binary. Without either, provisioning builds `STALWART_REF` from source on the Stalwart VM ([section 3](#3-versions-and-the-v10-gap)).
- `scripts/check-errors.sh results/c/RUN` lists runs with operation errors; `scripts/report.sh results/c/RUN` renders one run's tables.
- `infra/ec2/` has the same interface for AWS but was not used for these results and is untested.

The published 256 cells took about 11 hours of wall clock, spread over many clusters of 50 vCPU each. On a single cluster the same set takes roughly 90 hours. Azure cost depends on region and pricing and was not tracked per cluster.

## 3. Versions and the v1.0 gap

`versions.env` pins every component and its checksum. Two caveats for Stalwart:

- The benchmarked code is commit `90b8620c934a703064d59be083203f577c03a5da` (`STALWART_BENCH_COMMIT`). Upstream has no v1.0 tag yet, so `STALWART_REF='v1.0.0'` in `versions.env` is a placeholder until the release tag exists; until then, set `STALWART_REF` to the commit, or use a prebuilt binary.
- The from-source path in `provision/stalwart.sh` uses rustup's current stable toolchain, `-C target-cpu=native` and fat LTO. On Zen 5 with rustc 1.99.1 that hits the LLVM SIGILL from [METHODOLOGY.md, section 1.4](METHODOLOGY.md#14-stalwart-build); install rustc 1.98.0 as the default toolchain on the VM first, or build elsewhere with the flags in [METHODOLOGY.md, section 1.4](METHODOLOGY.md#14-stalwart-build) and pass `STALWART_BINARY`.
