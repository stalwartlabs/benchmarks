### Track C (bench-c8-1025)

| Host | Role | Size | CPU | Physical host |
|---|---|---|---|---|
| load1 | load | Standard_D16as_v7 | AMD EPYC 9V45 96-Core Processor | GVX22 |
| load2 | load | Standard_D16as_v7 | AMD EPYC 9V45 96-Core Processor | GVX22 |
| stalwart | stalwart | Standard_D8ads_v7 | AMD EPYC 9V45 96-Core Processor | GVX22 |
| dovecot | postfix-dovecot | Standard_D8ads_v7 | AMD EPYC 9V45 96-Core Processor | GVX22 |
| sink | sink | Standard_D2as_v7 | AMD EPYC 9V45 96-Core Processor | GVX22 |

| From | To | TCP RTT p50 us | p99 us |
|---|---|---|---|
| dovecot | load1 | 79.4 | 90.3 |
| dovecot | load2 | 78.5 | 93.5 |
| dovecot | sink | 65.5 | 93.7 |
| dovecot | stalwart | 63.6 | 75.5 |
| load1 | dovecot | 78.0 | 88.0 |
| load1 | load2 | 61.2 | 69.2 |
| load1 | sink | 81.5 | 114.2 |
| load1 | stalwart | 77.6 | 95.0 |
| load2 | dovecot | 78.0 | 90.2 |
| load2 | load1 | 62.2 | 73.3 |
| load2 | sink | 81.1 | 111.3 |
| load2 | stalwart | 81.1 | 94.9 |
| sink | dovecot | 68.6 | 103.5 |
| sink | load1 | 78.8 | 88.0 |
| sink | load2 | 77.6 | 88.1 |
| sink | stalwart | 65.1 | 77.6 |
| stalwart | dovecot | 63.4 | 76.3 |
| stalwart | load1 | 78.7 | 89.3 |
| stalwart | load2 | 80.3 | 93.5 |
| stalwart | sink | 67.5 | 106.3 |

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

#### imap-large

| Cell | Operation | stalwart p50 / p95 / p99 ms | dovecot p50 / p95 / p99 ms |
|---|---|---|---|
| l09-select-cold-large100k | imap.select | 0.08 / 0.09 / 0.09 | 0.15 / 0.18 / 0.25 |
| l09-select-cold-large10k | imap.select | 0.10 / 0.10 / 0.12 | 0.14 / 0.17 / 0.20 |
| l09-select-cold-large250k | imap.select | 0.08 / 0.09 / 0.10 | 0.14 / 0.20 / 0.22 |
| l10-fetch-cold-large100k-flags_all | imap.fetch | 8.83 / 9.58 / 9.70 | 74.17 / 76.73 / 81.15 |
| l10-fetch-cold-large10k-flags_all | imap.fetch | 0.88 / 0.95 / 1.18 | 6.73 / 6.98 / 7.19 |
| l10-fetch-cold-large250k-flags_all | imap.fetch | 20.38 / 22.13 / 22.25 | 141.95 / 172.03 / 187.65 |
| l11-search-body-common-cold-large100k | imap.search.body-common | 1.88 / 2.74 / 4.68 | 39.36 / 58.30 / 59.81 |
| l11-search-body-common-cold-large10k | imap.search.body-common | 0.53 / 0.88 / 2.19 | 3.51 / 4.38 / 6.97 |
| l11-search-body-common-cold-large250k | imap.search.body-common | 4.28 / 6.29 / 7.89 | 125.95 / 187.39 / 189.69 |
| l12-sort-cold-large100k-date | imap.sort | 8.09 / 8.38 / 10.77 | 76.42 / 80.58 / 84.22 |
| l12-sort-cold-large10k-date | imap.sort | 0.69 / 0.79 / 1.17 | 7.97 / 8.41 / 9.18 |
| l12-sort-cold-large250k-date | imap.sort | 22.09 / 22.75 / 28.37 | 195.84 / 205.31 / 223.62 |
| l13-store-cold-large100k-all | imap.store | 281.60 / 307.71 / 311.55 | 59.20 / 60.00 / 62.53 |
| l13-store-cold-large100k-one | imap.store | 0.12 / 0.23 / 0.32 | 0.15 / 0.18 / 0.24 |
| l13-store-cold-large100k-range100 | imap.store | 0.36 / 0.56 / 0.60 | 0.22 / 0.29 / 0.37 |
| l13-store-cold-large10k-all | imap.store | 40.29 / 45.28 / 48.16 | 7.70 / 8.04 / 8.26 |
| l13-store-cold-large10k-one | imap.store | 0.11 / 0.18 / 0.23 | 0.15 / 0.19 / 0.21 |
| l13-store-cold-large10k-range100 | imap.store | 0.32 / 0.46 / 0.57 | 0.22 / 0.27 / 0.31 |
| l13-store-cold-large250k-all | imap.store | 795.13 / 883.20 / 921.09 | 149.38 / 152.19 / 152.57 |
| l13-store-cold-large250k-one | imap.store | 0.13 / 0.20 / 0.28 | 0.16 / 0.18 / 0.21 |
| l13-store-cold-large250k-range100 | imap.store | 0.34 / 0.46 / 0.58 | 0.22 / 0.28 / 0.35 |

