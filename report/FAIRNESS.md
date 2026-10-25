# Fairness

Part of the Stalwart vs Postfix and Dovecot comparison. Start at the [README](../README.md).

## 1. Durability and other fairness notes

### 1.1 Durability: this favours Stalwart

The three components do not make the same promise when they acknowledge a message:

| System | Setting used | What the 250 or tagged OK means |
|---|---|---|
| Stalwart | as shipped (RocksDB default write options; not configurable in v1.0) | the write-ahead log record has been written to the OS on every commit, without fsync. A process crash loses nothing; a kernel crash or power loss can lose the last acknowledged writes. |
| Postfix | as shipped (queue file fsync; cannot be disabled) | the queue file has been fsynced before the 250. |
| Dovecot | `mail_fsync = never` | mdbox and index writes reach the OS on every operation, without fsync. Same promise as Stalwart. |
| Dovecot variant | `mail_fsync = always` | Dovecot fsyncs mail and index writes. |

So on SMTP inbound (C1 to C3) and relay (C4 to C6), Postfix pays for an fsync per message that Stalwart does not. That tilts those results toward Stalwart, and the size of the tilt is not measured separately (there is no supported way to switch Postfix's fsync off, and Stalwart was not modified). On IMAP writes (C13 to C16) Dovecot with `mail_fsync = never` and Stalwart make the same promise. The `fsync=always` rows show what full durability on the Dovecot side costs; there is no Stalwart counterpart to them.

### 1.2 Work per message

Neither side does more than the other on the measured path: no spam filter, greylisting, DNSBL, SPF, DKIM, DMARC, ARC or reverse DNS on either side; no DKIM signing; no Sieve; no throttles, rate limits or auto-ban; FTS at delivery on both (Stalwart built-in, Dovecot flatcurve with autoindex), over the same fields (From, To, Cc, Bcc, Subject and body text; no attachment text extraction; English stemming and stop words); message metadata for FETCH, SORT and THREAD computed at delivery on both. Logging is at info level to local files on both: Stalwart writes about 5 lines per inbound message, Postfix and Dovecot together 6 to 8. The full list, with where to check each item, is [section 2](#2-fairness-checklist).

### 1.3 Known differences that remain

- Postfix queue fsync ([section 1.1](#11-durability-this-favours-stalwart)).
- Stalwart compresses stored messages with LZ4 (shipped default); Dovecot mdbox stores them uncompressed (no `mail_compress`, shipped default).
- Stalwart stores one copy of a message delivered to several recipients (content-addressed blobs); Dovecot stores one copy per recipient ([CAVEATS.md, section 12](CAVEATS.md#12-storage-use)).
- Postfix and Dovecot LMTP each add a Received header, Stalwart adds one; Postfix adds one on submission where Stalwart adds none.
- Stalwart uses rustls with aws-lc-rs, Postfix and Dovecot OpenSSL 3.0.13.
- Build flags ([METHODOLOGY.md, section 1.4](METHODOLOGY.md#14-stalwart-build)): Stalwart for znver5, Postfix and Dovecot generic x86-64.
- Stalwart allows 10 messages per SMTP connection and 100 recipients per message by default, Postfix no limit and 1,000; no cell exceeds 10 of either.
- Stalwart runs its daily maintenance jobs ([METHODOLOGY.md, section 2.5](METHODOLOGY.md#25-quiet-windows)) and, without a license, logs one line every 5 minutes for a metrics task that does nothing.

### 1.4 Tuning applied to Postfix and Dovecot

Postfix: process limit 1,000, no connection or rate limits, `in_flow_delay = 0`, no reverse DNS lookup, LMTP concurrency 25 and SMTP concurrency 50 without slow start (to match Stalwart's local and remote delivery queues), TLS session caches, queue on the NVMe. Dovecot: imap-login in high-performance mode (`restart_request_count = unlimited`, `process_min_avail = 8`, `client_limit = 8192`), `service imap process_limit = 8192` and `vsz_limit = 2G` ([CAVEATS.md, section 10](CAVEATS.md#10-build-and-configuration-differences)), 25 LMTP processes kept ready, auth cache, `mailbox_list_index`, `mail_always_cache_fields` for the FETCH/SORT/THREAD set, `mail_max_userip_connections = 1000`. [SETTINGS.md](SETTINGS.md) lists every value with its default and reason.

Review requests for Dovecot experts are listed at the end of [section 2](#2-fairness-checklist).

## 2. Fairness checklist

For Postfix and Dovecot experts reviewing whether their side was configured fairly. The effective configurations of every run are in `results/c/RUN/configs/HOST/` (dumped by `provision/ctl.sh config-dump`).

### 2.1 Environment

- Both servers run on the same VM size (D8ads_v7, AMD EPYC 9V45), same image, kernel, sysctls, transparent huge pages, NVMe scheduler and NIC ring settings (`host.txt` in each config dump).
- All data (Stalwart RocksDB; Postfix queue, Dovecot mdbox, indexes and FTS) is on the same kind of local NVMe, XFS with `noatime`.
- Both servers resolve through the same lab DNS stub and the same `/etc/resolv.conf`.
- Runs alternate Stalwart and Postfix + Dovecot on the same VM pair and the same load hosts.
- Background work is drained before every run on both sides.
- Cold-cache cycles stop, drop caches and restart both servers the same way.

### 2.2 Durability

- Stalwart: RocksDB default write options (WAL written to the OS on every commit, no fsync per commit). Not configurable in v1.0.
- Dovecot: `mail_fsync = never`.
- Postfix: fsyncs the queue file before 250; cannot be disabled. Favours Stalwart on SMTP inbound and relay.
- One extra Postfix + Dovecot run with `mail_fsync = always` on the write families.

### 2.3 Work done per message

- No spam filter, greylisting, DNSBL, SPF, DKIM, DMARC, ARC or reverse DNS checks on either side (Stalwart: SpamSettings, SenderAuth, MtaStage* objects; Postfix: no restrictions, `smtpd_peername_lookup = no`, no milters, no postscreen).
- No DKIM signing on either side.
- No throttles, rate limits, connection limits or auto-ban: Stalwart's throttles and queue quota exist but are disabled, auto-ban rates are null, IMAP and HTTP rate limits and the per-account IMAP connection limit are null; Postfix anvil limits are 0, `in_flow_delay = 0`; Dovecot `mail_max_userip_connections = 1000`.
- No Sieve, vacation, calendar (iTIP) processing, telemetry, metrics or tracing stores on Stalwart; no Sieve on Dovecot (Pigeonhole not installed).
- Logging at info level to a local file on both sides.
- FTS at delivery and APPEND on both, same fields (From, To, Cc, Bcc, Subject, body text), no attachment text extraction, English stemming and stop words.
- Message metadata for FETCH ENVELOPE/BODYSTRUCTURE, SORT and THREAD computed at delivery on both (Stalwart stores it; Dovecot `mail_always_cache_fields`).
- Same auto-created folders on both (Inbox, Drafts, Sent, Archive, Junk, Trash) with `/` as separator.
- Submission checks the sender against the login on both (Stalwart `mustMatchSender`, Postfix `reject_sender_login_mismatch`).
- Outbound relay: opportunistic STARTTLS without certificate verification, DANE or MTA-STS on both; the sink offers no STARTTLS, so both relay in plaintext. Delivery concurrency: Stalwart remote queue 50 threads, Postfix `smtp_destination_concurrency_limit = 50` without slow start.
- Local delivery concurrency: Stalwart local queue 25 threads; Postfix to Dovecot LMTP up to 25 connections without slow start, 25 LMTP processes kept ready.

### 2.4 Authentication

- The same SHA512-CRYPT (5,000 rounds) hash for every account on both servers, generated once by `mailbench accounts`.
- Auth caching on both, and on both a cached login still runs the full SHA512-CRYPT verification: Dovecot caches the passdb entry and verifies the password against it on every login (`src/auth/passdb-cache.c`, 2.4.5); Stalwart caches the account and verifies the hash on every login (`crates/directory/src/core/secret.rs`).
- Postfix SMTP AUTH goes through the Dovecot auth service (same passdb, same cache).

### 2.5 TLS

- One ECDSA P-256 certificate for both servers, TLS 1.3 only, TLS_AES_256_GCM_SHA384 only, X25519 (Postfix and Dovecot pin it server side; the load generator offers only X25519, so Stalwart negotiates it too).
- STARTTLS on 25 and 587, implicit TLS on 465 and 993 on both. Postfix to Dovecot LMTP is a local unix socket in plaintext, as in real deployments.
- The load generator never resumes TLS sessions, so every measured connection is a full TLS 1.3 handshake on both sides. (Server defaults differ: Stalwart keeps a 256-entry stateful resumption cache and sends no tickets; Postfix and Dovecot issue stateless tickets. With resumption on, hit rates would differ.)

### 2.6 Symmetry on the measured path

| Path | Check | Stalwart | Postfix + Dovecot | Verdict |
|---|---|---|---|---|
| SMTP 25 | Recipient validation | RCPT checked against the internal directory (account cache) | RCPT checked against a `hash:` virtual mailbox map | same (one in-memory or mmap lookup each) |
| SMTP 25 | Relay control | relay only when authenticated | `defer_unauth_destination` | same |
| SMTP 25 | AUTH offered | no | no (`smtpd_sasl_auth_enable = no`) | same |
| SMTP 25 | HELO/EHLO checks | EHLO required, non-FQDN allowed | none | same in effect (clients always send EHLO) |
| SMTP 25 | Reverse DNS, SPF, DKIM, DMARC, ARC, DNSBL, spam, greylisting | off | off | same |
| SMTP | Message size limit | 100 MiB | 100 MiB | same |
| SMTP | Recipients per message | 100 | 1,000 | differs; cells use at most 10 |
| SMTP | Messages per connection | 10 (shipped) | unlimited | differs; cells use at most 10 |
| SMTP | Failed RCPT handling | 5 failures, 5 s wait | `smtpd_error_sleep_time` 1 s, soft/hard limits 10/20 | differs only on errors; not on the measured path |
| SMTP | Header loop detection | max 50 Received | `hopcount_limit = 50` | same |
| SMTP | Headers added | Received (port 25 only), Return-Path and Delivered-To at delivery; Message-ID/Date only if missing | Received by Postfix (all ports) and by Dovecot LMTP, Return-Path and Delivered-To by LMTP; Message-ID/Date only if missing | near-same; Postfix + Dovecot add one more Received header, and one on submission |
| SMTP 465/587 | AUTH mechanisms | PLAIN, LOGIN, OAUTHBEARER, XOAUTH2 advertised; tests use PLAIN | PLAIN, LOGIN; tests use PLAIN | same for the tested mechanism |
| SMTP 465/587 | Sender must match login | yes | yes | same |
| SMTP 587 | AUTH only after STARTTLS | yes | yes (`smtpd_tls_auth_only`) | same |
| Delivery | Durability before 250 | WAL write, no fsync | queue file fsync | known difference, favours Stalwart |
| Delivery | Spam, Sieve, iTIP at delivery | off | none | same |
| Delivery | FTS at delivery | built-in, asynchronous index queue | flatcurve via `fts_autoindex`, asynchronous indexer | same; C2 measures visibility, not index completion |
| Delivery | Metadata cached at delivery | full message metadata stored | `mail_always_cache_fields` | same |
| Delivery | Compression | LZ4 (shipped) | none (shipped) | known difference |
| Relay | Outbound TLS | opportunistic, no verification, no DANE/MTA-STS | `smtp_tls_security_level = may` | same (plaintext to the sink on both) |
| Relay | Concurrency | remote queue 50 threads | 50 per destination, no slow start | same |
| IMAP | Login cost | full SHA512-CRYPT per login (account cached) | full SHA512-CRYPT per login (passdb entry cached) | same |
| IMAP | AUTH mechanisms | PLAIN, OAUTHBEARER, XOAUTH2, LOGIN command | PLAIN, LOGIN, LOGIN command | same for the tested LOGIN command |
| IMAP | Rate limit, per-user connection limit | none, none | none, 1,000 per user and IP | same in effect |
| IMAP | Request and literal size | 50 MB request, 75 MB APPEND | no APPEND limit (no quota) | differs only above 50 MB; corpus maximum 2 MB |
| IMAP | Folder set and separator | Inbox, Drafts, Sent, Archive, Junk, Trash; `/` | same | same |
| TLS | Protocol, cipher, group, certificate | TLS 1.3, AES-256-GCM, X25519, ECDSA P-256 | same (pinned server side) | same |
| TLS | Session resumption | stateful cache, no tickets | stateless tickets | neutralised: the generator never resumes |
| All | Throttles, quotas, auto-ban | disabled | anvil limits 0, no quota | same |
| All | Logging | info, about 5 lines per inbound message | info, 6 to 8 lines per message | comparable |
| Background | Periodic jobs | daily expunge and purges (00:00, 02:00, 04:00 UTC); a metrics task every 5 min (no-op without a license) | none | known difference; runs avoid the daily jobs |

Configuration note: a Stalwart singleton update to a value equal to its unstored default is not persisted, so the first normal start would still insert the shipped ASN resource (ASN/geo downloads from GitHub) and the enterprise tracing and metrics stores. The fairness plan therefore writes a different value first and then `Disabled`; verified on a fresh store (no downloads, the stores stay disabled).

### 2.7 Open questions for reviewers

- `mdbox_rotate_size` is left at its default (10M). A larger value reduces the file count on the 250k mailbox; suggestions welcome.
- Should Dovecot keep `mail_always_cache_fields` for headers that only SORT uses, or rely on on-demand caching after a warm-up pass?
- Is `vsz_limit = 2G` for `service imap` the value you would use for 250k-message mailboxes ([CAVEATS.md, section 10](CAVEATS.md#10-build-and-configuration-differences))?
