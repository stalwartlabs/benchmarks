# mailbench

Load generator, seeder, delivery probe and sink MTA used by the benchmarks in this repository. It drives Stalwart and Postfix + Dovecot through the same client code paths.

## Build

```
cargo build --release
```

The binary is `target/release/mailbench`. It has no runtime dependencies.

## Commands

| Command | Purpose |
|---|---|
| `mailbench scenarios DIR [--json]` | List the cells of every scenario file (matrix expanded) |
| `mailbench run --scenario FILE --cell ID --target T --out FILE.json` | Run one cell; exit 0 valid, 3 invalid run, 1 failure |
| `mailbench merge IN.json... --out OUT.json` | Merge the results of several load hosts (histograms included) |
| `mailbench accounts --dataset D --out FILE [--format tsv\|dovecot-passwd\|postfix-vmailbox]` | Write the account list with SHA512-CRYPT hashes |
| `mailbench seed --dataset D --target T [--step accounts\|mailboxes\|all] [--users A-B]` | Create Stalwart accounts over the management API and fill mailboxes by IMAP APPEND (resumable) |
| `mailbench verify --dataset D --target T --out FILE.json` | Check folder counts and sampled message hashes; exit 4 on mismatch |
| `mailbench sink --listen 0.0.0.0:25` | Sink MTA for relay tests; reports acceptance back to the sender over UDP |
| `mailbench message --dataset D --account user0001 --index 0` | Print one dataset message |

Targets are resolved from `/etc/bench/hosts.json` (`--target stalwart` or `--target dovecot`); `--server HOST` and the `--*-port` flags override it for local runs. Run `mailbench <command> --help` for every flag.

## Measurement

- Every operation records a total latency and, where they apply, the phases `connect` (TCP), `tls`, `greeting`, `auth` and `command`, on a monotonic clock, into HdrHistograms (1 us to 1 h, 3 significant digits).
- Closed loop: N sessions, optional think time, a warm-up that is discarded, then a sample target or a maximum duration.
- Open loop: Poisson arrivals at each rate of a ladder; latency is measured from the scheduled arrival time, so queueing in the generator (coordinated omission) is part of the result. A step is invalid when the host CPU averages more than 70%, more than 1% of arrivals start more than 10 ms late, or any arrival is dropped.
- Delivery time (C2): the recipient's INBOX is polled with back-to-back NOOPs from the moment the sending session connects until EXISTS grows; the NOOP round trip is recorded as the resolution. An IDLE variant measures push-notification latency.
- Relay time (C5): the sink MTA sends the token of each accepted message back to the sending load host over UDP, so the timing stays on one clock.
- TLS: TLS 1.3 only, X25519 only, no session resumption, certificates not verified (lab certificates).

## Corpus and datasets

The corpus is generated from a seed, so every host and both servers see identical messages. Text uses a vocabulary of English function words plus seeded pseudo-words with Zipf frequencies (or a real word list given with `--word-list`). Sizes are log-normal (median 8 KB) with 1% large attachments, 35% of messages are replies with threading headers, Message-IDs are unique. Datasets: `c` (1,000 users with Zipf mailbox sizes, mean 200 messages, plus 10k/100k/250k-message accounts), `s`, `m`, `l`, and `tiny` for smoke tests.

## Scenarios

Scenario files live in `../scenarios`. Each file describes a cell template and an optional `matrix` whose keys are dotted paths into the template; every combination becomes a cell named `<id>-<values>`.
