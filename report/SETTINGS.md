# Tuned settings

Part of the Stalwart vs Postfix and Dovecot comparison. Start at the [README](../README.md).

Every setting that differs from the shipped default, with the reason. Stalwart defaults were read from a fresh server at commit 90b8620c (`stalwart-cli snapshot`).

## 1. OS (identical on every host; `config/os/`, `provision/os-tuning.sh`)

| Setting | Value | Default | Reason |
|---|---|---|---|
| `net.core.somaxconn`, `net.ipv4.tcp_max_syn_backlog` | 65535 | 4096 / 1024 | no accept-queue drops at high connection rates |
| `net.core.netdev_max_backlog` | 65536 | 1000 | no packet drops under load |
| `net.ipv4.ip_local_port_range` | 1024 65535 | 32768 60999 | load hosts open many short connections |
| `net.ipv4.tcp_tw_reuse` | 1 | 2 (loopback only) | same, client side |
| `net.ipv4.tcp_fin_timeout` | 15 | 60 | same |
| `net.core.rmem_max`, `wmem_max`, `tcp_rmem`, `tcp_wmem` | 64 MiB maximum | 208 KiB / 4 to 6 MiB | large message bodies |
| `net.ipv4.tcp_slow_start_after_idle` | 0 | 1 | reused connections are not throttled after think time |
| `vm.swappiness` | 1 | 60 | no swapping of server memory |
| `vm.max_map_count` | 1048576 | 65530 | RocksDB and mdbox open many files |
| `fs.file-max`, `fs.nr_open`, nofile limits, systemd `DefaultLimitNOFILE` | 4194304 / 1048576 | distribution defaults | connection count |
| `fs.inotify.max_user_instances` / `max_user_watches` | 8192 / 1048576 | 128 / 8192 or more | Dovecot IDLE uses inotify per session |
| Transparent huge pages | `never` (enabled and defrag) | `madvise` | database workloads; same on both |
| NVMe I/O scheduler | `none` | `none` on most NVMe (set explicitly) | plan |
| NIC RX ring | hardware maximum | driver default | plan |
| Data filesystem | XFS, `noatime`, local NVMe at `/mnt/data` | n/a | plan |
| unattended-upgrades, apt timers, man-db, fstrim, motd-news, snapd, cron, logrotate, sysstat | disabled | enabled | no background jobs during measurements |
| Resolver | `/etc/resolv.conf` to the lab DNS stub (systemd-resolved disabled) on both servers | systemd-resolved | every lookup answered inside the lab, same path for both |
| Egress guard | iptables chain `BENCH-EGRESS`: outbound TCP 25/465/587/2525 only to lab hosts | none | no test mail leaves the lab |

## 2. Stalwart (`config/stalwart/fairness.ndjson`, applied with `stalwart-cli apply`)

| Object.field | Value | Default | Reason |
|---|---|---|---|
| DataStore (`config.json`) | RocksDB at `/mnt/data/stalwart/db` | n/a | RocksDB for this comparison |
| BlobStore, SearchStore, InMemoryStore | `Default` (inside the data store) | same | explicit; blobs and FTS in RocksDB |
| Certificate, `SystemSettings.defaultCertificateId` | lab ECDSA P-256 certificate from file | none | same certificate as Postfix and Dovecot |
| `SystemSettings.defaultHostname` / `defaultDomainId` | `mail.example.org` / example.org | machine host name | identity |
| Domain example.org | certificate, DKIM and DNS management Manual; sub-addressing Disabled | DKIM Automatic, sub-addressing Enabled | no DKIM key generation task; Postfix has no recipient delimiter configured |
| NetworkListener | 25, 587 (STARTTLS), 465, 993, 443 (implicit TLS); TLS 1.2 and the TLS 1.3 AES-128 and ChaCha20 suites disabled | 25, 465, 993, 995, 4190, 443, 8080 | same ports and the one TLS 1.3 suite of Postfix and Dovecot; no POP3, ManageSieve or plain HTTP |
| MtaInboundThrottle (2 shipped rules) | present, `enable: false` | enabled (5/s per IP; 25/h per sender domain and recipient) | throttles disabled, not raised |
| MtaQueueQuota (shipped rule) | `enable: false` | enabled (100k messages, 10 GiB) | Postfix has no equivalent queue quota |
| MtaOutboundThrottle | none | none | explicit |
| MtaTlsStrategy default and invalid-tls | DANE disabled, MTA-STS disabled, `allowInvalidCerts` true, STARTTLS optional | DANE and MTA-STS optional, invalid certificates refused | matches Postfix `smtp_tls_security_level = may` |
| SpamSettings | `enable: false`, `spamFilterRulesUrl: null` | enabled, rules downloaded from GitHub | no spam filter |
| `MtaStageData.enableSpamFilter` | `false` | `is_empty(authenticated_as)` | no spam filter |
| `MtaStageData.dkimSignDomain` | `false` | sign for local senders | no DKIM signing (Postfix does none) |
| `MtaStageData.addAuthResultsHeader`, `addReceivedSpfHeader` | `false` | true on port 25 | no authentication checks run |
| SenderAuth: `dkimVerify`, `arcVerify`, `spfEhloVerify`, `spfFromVerify`, `dmarcVerify`, `reverseIpVerify` | `disable` | relaxed on port 25 | no sender authentication |
| `MtaStageEhlo.rejectNonFqdn` | `false` | true on port 25 | Postfix has no HELO restrictions by default |
| `MtaStageMail.isSenderAllowed` | `true` | spam-block list lookup | that lookup is part of the spam filter |
| Security: `authBanRate`, `abuseBanRate`, `loiterBanRate`, `scanBanRate` | `null`; `scanBanPaths` empty | 100/35/150/30 per day | auto-ban disabled |
| AllowedIp | one entry per load host | none | safety net against bans |
| `Imap.rateLimit` | `null` | 2000/min per account | rate limit disabled |
| `Imap.maxConcurrentConnections` | `null` | 16 per account | limit disabled; Dovecot's raised to 1,000 |
| `Http.rateLimitAnonymous` / `rateLimitAuthenticated` | `null` | 100 / 1000 per min | management API used by the seeder |
| `CalendarScheduling.enable`, `httpRsvpEnable` | `false` | true | no iTIP processing of inbound mail |
| Tracer | one log tracer, level info, `/var/log/stalwart`, daily rotation | same shape, created at first start | explicit; info level like Postfix and Dovecot |
| TracingStore, MetricsStore | `Disabled` (written as `Default` then `Disabled` so the value is stored) | `Default` (created at first start by the enterprise build) | no tracing or metrics history |
| Metrics (Prometheus, OpenTelemetry) | `Disabled` | `Disabled` | explicit |
| Asn | `Disabled` (written as an empty resource then `Disabled`) | URL resource (ASN/geo downloads at start) | no network fetch and no lookups per connection |
| `Search.indexEmailFields` | from, to, cc, bcc, subject, body | also attachment | flatcurve indexes text parts only |
| `Search.indexTelemetry` | `false` | true | no tracing store |
| `Email.defaultFolders` | Inbox, Drafts, Sent, Archive, Junk, Trash | Inbox, Drafts, "Sent Items", "Deleted Items", "Junk Mail" | same folder names as Dovecot |
| Admin account | `admin@example.org`, role Admin, SHA512-CRYPT | none | management API for seeding |

Kept at the shipped defaults: RocksDB block cache (1/8 of RAM, at most 8 GiB), write buffers 128 MiB, `poolWorkers` and Tokio worker threads equal to the cores, all cache sizes, `Email.compressionAlgorithm` lz4, `MtaStageData.maxMessages` 10 per connection, SMTP pipelining and chunking, local queue 25 threads, remote queue 50 threads, `SystemSettings.maxConnections` 8192 per listener, the daily jobs at 00:00 (expunge), 02:00 (data cleanup) and 04:00 UTC (blob cleanup).

## 3. Postfix 3.11.7 (`config/postfix/`)

| Parameter | Value | Default | Reason |
|---|---|---|---|
| `queue_directory`, `data_directory` | `/mnt/data/postfix/spool`, `/mnt/data/postfix/lib` | `/var/spool/postfix`, `/var/lib/postfix` | queue on the NVMe |
| `maillog_file` | `/var/log/postfix.log` | syslog | log to a local file like Stalwart |
| `virtual_mailbox_domains`, `virtual_mailbox_maps` | example.org, `hash:/mnt/data/postfix/vmailbox` | none | recipient validation |
| `virtual_transport` | `lmtp:unix:private/dovecot-lmtp` | virtual | delivery to Dovecot LMTP |
| `mydestination`, `local_recipient_maps`, `alias_maps`, `recipient_delimiter` | empty | local delivery | virtual-only server |
| `inet_protocols` | ipv4 | all | the lab is IPv4 |
| `message_size_limit` | 104857600 | 10240000 | same as Stalwart (100 MiB) |
| `default_process_limit` | 1000 | 100 | no process starvation under load |
| `in_flow_delay` | 0 | 1s | no inbound throttling |
| `smtpd_client_connection_count_limit`, `_connection_rate_limit`, `_message_rate_limit`, `_recipient_rate_limit`, `_new_tls_session_rate_limit` | 0 | 50 / 0 / 0 / 0 / 0 | no connection limits |
| `smtpd_peername_lookup` | no | yes | Stalwart does no reverse DNS in this profile |
| `lmtp_destination_concurrency_limit`, `lmtp_initial_destination_concurrency` | 25, 25 | 20, 5 | matches Stalwart's local delivery queue, no slow start |
| `lmtp_destination_recipient_limit` | 50 | 50 | explicit |
| `smtp_destination_concurrency_limit`, `smtp_initial_destination_concurrency` | 50, 50 | 20, 5 | matches Stalwart's remote queue, no slow start |
| `smtpd_sasl_type`, `smtpd_sasl_path` | dovecot, `private/auth` | cyrus | AUTH through Dovecot (same passdb and cache) |
| `smtpd_sender_login_maps` + `reject_sender_login_mismatch` (submission) | sender must equal login | none | Stalwart `mustMatchSender` is on by default |
| `smtpd_tls_chain_files` | lab certificate and key | none | same certificate |
| `smtpd_tls_security_level` | may (encrypt on 587, wrapper mode on 465) | none | STARTTLS on 25 and 587, implicit TLS on 465 |
| `smtpd_tls_protocols`, `smtpd_tls_mandatory_protocols` | `>=TLSv1.3` | `>=TLSv1` / `>=TLSv1.2` | TLS 1.3 only, like Stalwart |
| `tls_config_file`, `tls_config_name` | `/etc/postfix/openssl.cnf`, postfix (Ciphersuites TLS_AES_256_GCM_SHA384, Groups X25519) | OpenSSL defaults | one suite and group on both servers |
| `smtpd_tls_session_cache_database`, `smtp_tls_session_cache_database` | `btree:` in `data_directory` | none | TLS session cache |
| `smtp_tls_security_level` | may | none | opportunistic outbound TLS, like Stalwart |
| master.cf | `submission` (587) and `submissions` (465) with SASL, no postscreen, no chroot | commented out | submission ports |
| master.cf `pickup -o content_filter=discard:` | locally submitted mail (cron, sudo) discarded | delivered | system mail to root has no mailbox and would sit in the queue, blocking the drain; test mail always arrives over SMTP |

## 4. Dovecot 2.4.5 (`config/dovecot/dovecot.conf`)

| Setting | Value | Default | Reason |
|---|---|---|---|
| `mail_driver`, `mail_home`, `mail_path` | mdbox, `/mnt/data/dovecot/mail/<domain>/<user>`, `~/mdbox` | none | mdbox on the NVMe |
| `mail_uid`, `mail_gid` | vmail | none | virtual users |
| `mail_fsync` | never (variant `fsync-always`: always) | optimized | durability matched to Stalwart ([FAIRNESS.md, section 1.1](FAIRNESS.md#11-durability-this-favours-stalwart)) |
| `mailbox_list_index` | yes | yes | explicit |
| `mail_always_cache_fields` | flags, date.received, date.sent, size.virtual, imap.envelope, imap.bodystructure, From/To/Cc/Subject/Message-ID/In-Reply-To/References headers | empty | cache filled at delivery for the FETCH/SORT/THREAD set, as Stalwart stores this metadata at delivery |
| namespace inbox | separator `/`; Drafts, Sent, Archive, Junk, Trash auto-subscribed | separator `.`, no special folders | same folder set and separator as Stalwart |
| passdb / userdb | passwd-file `/mnt/data/dovecot/users`, `{SHA512-CRYPT}` | none | same hashes as Stalwart |
| `auth_mechanisms` | plain login | plain | same as Stalwart |
| `auth_cache_size`, `auth_cache_ttl`, `auth_cache_negative_ttl` | 16M, 1 hour, 1 hour | 0 (off) | auth caching on both |
| `ssl`, certificate and key | required, lab certificate | yes | same certificate |
| `ssl_min_protocol`, `ssl_cipher_suites`, `ssl_curve_list`, `ssl_server_prefer_ciphers` | TLSv1.3, TLS_AES_256_GCM_SHA384, X25519, server | TLSv1.2, OpenSSL defaults | same TLS as Stalwart and Postfix |
| `mail_plugins` | fts, fts_flatcurve | none | full-text search |
| `fts_autoindex` | yes | no | index on delivery and APPEND |
| `fts_header_excludes` / `fts_header_includes` | all excluded except From, To, Cc, Bcc, Subject | all headers indexed | same header set as Stalwart's index |
| `language en` (default), `language_tokenizers`, `language_filters` | generic email-address; lowercase stopwords snowball | none | English stemming, like Stalwart |
| `protocol imap { mail_max_userip_connections }` | 1000 | 10 | concurrency limit lifted, like Stalwart |
| `service imap-login` | imap port 0; `restart_request_count = unlimited`, `process_min_avail = 8`, `client_limit = 8192`, `vsz_limit = 1G` | 143 open, 1, 0, 1000, 256M | high-performance login mode, IMAPS only |
| `service imap { process_limit }` | 8192 | 1024 | same connection ceiling as Stalwart |
| `service imap { vsz_limit }` | 2G on every cluster that ran large-mailbox cells or C17 ([CAVEATS.md, section 10](CAVEATS.md#10-build-and-configuration-differences)) | 256M | tuned, needed for 250k-message mailboxes; Dovecot's message: "Out of memory (service imap { vsz_limit=256 MB }, you may need to increase it)" |
| `service lmtp` | unix socket in the Postfix queue, `process_min_avail = 25` | none, 0 | Postfix delivers with up to 25 LMTP connections |
| `service auth` | unix listener for Postfix SASL | none | Postfix AUTH |
| `log_path`, `info_log_path` | `/var/log/dovecot.log` | syslog | local log file at info |

## 5. DNS stub and sink (not systems under test)

Unbound on the sink host: lab ACL, 2 threads, 64/128 MiB caches, iterator only (no DNSSEC validation), static zones example.org and example.net, PTR and A records for lab hosts, forwarding to the cloud resolver. rbldnsd serves the DNSBL zones queried by Stalwart's spam-filter rules with test entries only (unused in track C, where the spam filter is off). Sink MTA: `mailbench sink` on port 25, no STARTTLS, discards bodies.
