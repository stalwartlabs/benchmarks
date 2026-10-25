### Track C (bench-c6-1025)

| Host | Role | Size | CPU | Physical host |
|---|---|---|---|---|
| load1 | load | Standard_D16as_v7 | AMD EPYC 9V45 96-Core Processor | SEL27 |
| load2 | load | Standard_D16as_v7 | AMD EPYC 9V45 96-Core Processor | SEL27 |
| stalwart | stalwart | Standard_D8ads_v7 | AMD EPYC 9V45 96-Core Processor | SEL27 |
| dovecot | postfix-dovecot | Standard_D8ads_v7 | AMD EPYC 9V45 96-Core Processor | SEL27 |
| sink | sink | Standard_D2as_v7 | AMD EPYC 9V45 96-Core Processor | SEL27 |

| From | To | TCP RTT p50 us | p99 us |
|---|---|---|---|
| dovecot | load1 | 61.5 | 68.9 |
| dovecot | load2 | 64.4 | 72.4 |
| dovecot | sink | 74.7 | 106.7 |
| dovecot | stalwart | 65.7 | 79.5 |
| load1 | dovecot | 63.2 | 71.5 |
| load1 | load2 | 63.3 | 71.2 |
| load1 | sink | 71.6 | 107.3 |
| load1 | stalwart | 62.6 | 74.5 |
| load2 | dovecot | 65.0 | 78.4 |
| load2 | load1 | 63.3 | 73.7 |
| load2 | sink | 64.1 | 99.7 |
| load2 | stalwart | 63.7 | 79.8 |
| sink | dovecot | 73.9 | 110.8 |
| sink | load1 | 65.6 | 78.1 |
| sink | load2 | 59.6 | 69.7 |
| sink | stalwart | 67.1 | 84.4 |
| stalwart | dovecot | 64.4 | 75.3 |
| stalwart | load1 | 62.6 | 70.1 |
| stalwart | load2 | 64.3 | 72.9 |
| stalwart | sink | 72.8 | 113.3 |

| Component | Version |
|---|---|
| cpu | AMD EPYC 9V45 96-Core Processor |
| dovecot | 2.4.5-2+ubuntu24.04 (0cbb641e3e) |
| fdb_client | FoundationDB CLI 7.4 (v7.4.8) |
| kernel | 7.0.0-1017-azure |
| mailbench | mailbench 0.1.0 |
| openssl | 3.0.13 |
| os | Ubuntu 24.04.5 LTS |
| postfix | 3.11.7 |
| rbldnsd | 1.0~20210120-2 |
| sha256 | f976519d83f8b463b0882968a4902a96fddfa8d1d576164a0326f258a3fe7ba4 |
| source | url |
| stalwart | 1.0.0 |
| stalwart_cli | 1.0.14 |
| stalwart_sha256 | f976519d83f8b463b0882968a4902a96fddfa8d1d576164a0326f258a3fe7ba4 |
| unbound | 1.19.2 |

#### imap

| Cell | Operation | stalwart ops/s at SLO (p99 ms) | dovecot ops/s at SLO (p99 ms) | dovecot+fsync-always ops/s at SLO (p99 ms) |
|---|---|---|---|---|
| c16-1m-sessions1 | imap.append | 249 (65.12) | 133 (3.42) | 142 (4.57) |
| c16-1m-sessions16 | imap.append | 254 (257.02) | 485 (69.82) | 441 (69.95) |
| c16-sessions1-4k | imap.append | 3,192 (0.48) | 151 (0.58) | 121 (1.25) |
| c16-sessions1-64k | imap.append | 1,206 (4.64) | 1,284 (0.72) | 87 (1.41) |
| c16-sessions16-4k | imap.append | 6,205 (9.50) | 5,855 (6.82) | 3,003 (11.73) |
| c16-sessions16-64k | imap.append | 2,414 (20.41) | 3,547 (9.84) | 1,433 (24.30) |
| c17 | mixed.delete | 1,556 (1.99) | 405 (19.60) | 405 (19.14) |
| c17 | mixed.fetch_new | 1,556 (1.54) | 405 (5.71) | 405 (2.74) |
| c17 | mixed.flag | 1,556 (1.49) | 405 (6.29) | 405 (6.21) |
| c17 | mixed.login | 1,556 (19.68) | 405 (151.42) | 405 (76.61) |
| c17 | mixed.logout | 1,556 (1.23) | 405 (6.06) | 405 (2.94) |
| c17 | mixed.move | 1,556 (2.31) | 405 (18.22) | 405 (23.55) |
| c17 | mixed.read | 1,556 (1.79) | 405 (7.04) | 405 (3.23) |
| c17 | mixed.search | 1,556 (1.83) | 405 (7.15) | 405 (4.38) |
| c17 | mixed.select | 1,556 (1.14) | 405 (4.82) | 405 (2.70) |
| c17 | mixed.session | 1,556 (21.97) | 405 (171.26) | 405 (92.99) |
| c17 | mixed.sync | 1,556 (1.25) | 405 (5.61) | 405 (2.78) |

#### imap-large

| Cell | Operation | stalwart p50 / p95 / p99 ms | dovecot p50 / p95 / p99 ms | dovecot+fsync-always p50 / p95 / p99 ms |
|---|---|---|---|---|
| l12-sort-large100k-date | imap.sort | 7.78 / 7.94 / 8.32 | 73.22 / 75.04 / 75.81 |  |
| l12-sort-large100k-from | imap.sort | 33.50 / 34.27 / 37.13 | 38.13 / 38.35 / 39.22 |  |
| l12-sort-large100k-subject | imap.sort | 38.69 / 39.87 / 41.84 | 38.51 / 38.96 / 39.57 |  |
| l12-sort-large10k-date | imap.sort | 0.80 / 0.81 / 0.84 | 7.42 / 7.53 / 7.66 |  |
| l12-sort-large10k-from | imap.sort | 2.87 / 2.94 / 3.13 | 3.85 / 3.88 / 3.92 |  |
| l12-sort-large10k-subject | imap.sort | 3.12 / 3.17 / 3.26 | 3.78 / 3.84 / 3.89 |  |
| l12-sort-large250k-date | imap.sort | 21.85 / 22.20 / 23.45 | 183.87 / 188.35 / 217.22 |  |
| l12-sort-large250k-from | imap.sort | 99.07 / 102.56 / 103.65 | 94.56 / 95.49 / 98.88 |  |
| l12-sort-large250k-subject | imap.sort | 117.76 / 121.63 / 123.52 | 98.11 / 99.90 / 102.40 |  |
| l12-thread-large100k | imap.thread | 10.62 / 11.96 / 12.54 | 183.94 / 186.94 / 188.99 |  |
| l12-thread-large10k | imap.thread | 1.00 / 1.01 / 1.07 | 16.98 / 17.18 / 17.30 |  |
| l12-thread-large250k | imap.thread | 32.15 / 33.70 / 34.93 | 487.42 / 492.80 / 495.62 |  |
| l13-store-large100k-all | imap.store | 279.81 / 310.01 / 332.67 | 72.70 / 80.45 / 81.92 |  |
| l13-store-large100k-one | imap.store | 0.10 / 0.11 / 0.12 | 0.13 / 0.14 / 0.16 |  |
| l13-store-large100k-range100 | imap.store | 0.35 / 0.48 / 0.57 | 0.19 / 0.20 / 0.22 |  |
| l13-store-large10k-all | imap.store | 41.49 / 47.70 / 48.98 | 7.10 / 7.25 / 7.39 |  |
| l13-store-large10k-one | imap.store | 0.26 / 0.27 / 0.28 | 0.13 / 0.14 / 0.17 |  |
| l13-store-large10k-range100 | imap.store | 0.66 / 0.71 / 0.74 | 0.19 / 0.20 / 0.22 |  |
| l13-store-large250k-all | imap.store | 772.61 / 870.40 / 919.29 | 133.76 / 161.79 / 310.65 |  |
| l13-store-large250k-one | imap.store | 0.10 / 0.11 / 0.12 | 0.12 / 0.13 / 0.14 |  |
| l13-store-large250k-range100 | imap.store | 0.34 / 0.41 / 0.44 | 0.19 / 0.21 / 0.24 |  |

