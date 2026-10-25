### Track C (bench-c5-1025)

| Host | Role | Size | CPU | Physical host |
|---|---|---|---|---|
| load1 | load | Standard_D16as_v7 | AMD EPYC 9V45 96-Core Processor | SAT14 |
| load2 | load | Standard_D16as_v7 | AMD EPYC 9V45 96-Core Processor | SAT14 |
| stalwart | stalwart | Standard_D8ads_v7 | AMD EPYC 9V45 96-Core Processor | SAT14 |
| dovecot | postfix-dovecot | Standard_D8ads_v7 | AMD EPYC 9V45 96-Core Processor | SAT14 |
| sink | sink | Standard_D2as_v7 | AMD EPYC 9V45 96-Core Processor | SAT14 |

| From | To | TCP RTT p50 us | p99 us |
|---|---|---|---|
| dovecot | load1 | 91.0 | 101.2 |
| dovecot | load2 | 89.8 | 109.8 |
| dovecot | sink | 94.7 | 118.3 |
| dovecot | stalwart | 64.8 | 77.4 |
| load1 | dovecot | 89.9 | 98.3 |
| load1 | load2 | 68.6 | 86.8 |
| load1 | sink | 95.4 | 119.6 |
| load1 | stalwart | 85.9 | 97.7 |
| load2 | dovecot | 91.7 | 103.5 |
| load2 | load1 | 68.5 | 80.8 |
| load2 | sink | 95.9 | 125.5 |
| load2 | stalwart | 92.0 | 100.3 |
| sink | dovecot | 93.4 | 125.1 |
| sink | load1 | 90.2 | 98.4 |
| sink | load2 | 92.3 | 102.2 |
| sink | stalwart | 89.0 | 109.9 |
| stalwart | dovecot | 65.5 | 75.9 |
| stalwart | load1 | 89.5 | 99.3 |
| stalwart | load2 | 90.1 | 100.5 |
| stalwart | sink | 94.4 | 120.9 |

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
| l09-select-large100k | imap.select | 0.09 / 0.09 / 0.10 | 0.15 / 0.16 / 0.17 |
| l09-select-large10k | imap.select | 0.11 / 0.11 / 0.12 | 0.15 / 0.22 / 0.45 |
| l09-select-large250k | imap.select | 0.09 / 0.09 / 0.10 | 0.15 / 0.17 / 0.17 |
| l09-select-qresync-large100k | imap.select_qresync | 0.87 / 0.92 / 0.95 | 3.37 / 3.77 / 4.69 |
| l09-select-qresync-large10k | imap.select_qresync | 0.31 / 0.39 / 0.41 | 0.55 / 0.60 / 0.61 |
| l09-select-qresync-large250k | imap.select_qresync | 0.70 / 0.76 / 0.79 | 8.28 / 8.56 / 10.05 |
| l10-fetch-body-large100k-1m | imap.fetch | 0.70 / 1.05 / 1.39 | 4.08 / 4.79 / 7.93 |
| l10-fetch-body-large100k-4k | imap.fetch | 0.14 / 0.14 / 0.15 | 0.16 / 0.17 / 0.18 |
| l10-fetch-body-large100k-64k | imap.fetch | 0.20 / 0.21 / 0.24 | 0.37 / 0.40 / 0.72 |
| l10-fetch-body-large10k-1m | imap.fetch | 0.69 / 0.71 / 0.77 | 4.63 / 5.34 / 536.32 |
| l10-fetch-body-large10k-4k | imap.fetch | 0.14 / 0.14 / 0.16 | 0.15 / 0.16 / 0.17 |
| l10-fetch-body-large10k-64k | imap.fetch | 0.20 / 0.22 / 0.23 | 0.41 / 0.68 / 1.26 |
| l10-fetch-body-large250k-1m | imap.fetch | 0.68 / 0.71 / 0.80 | 4.92 / 86.56 / 129.90 |
| l10-fetch-body-large250k-4k | imap.fetch | 0.14 / 0.15 / 0.15 | 0.15 / 0.17 / 0.18 |
| l10-fetch-body-large250k-64k | imap.fetch | 0.20 / 0.21 / 0.22 | 0.39 / 0.41 / 0.45 |
| l10-fetch-large100k-body_random | imap.fetch | 0.16 / 0.22 / 0.62 | 0.19 / 0.35 / 1.79 |
| l10-fetch-large100k-envelope_last | imap.fetch | 0.16 / 0.17 / 0.19 | 0.58 / 0.63 / 0.96 |
| l10-fetch-large100k-flags_all | imap.fetch | 8.48 / 9.71 / 28.60 | 76.16 / 630.08 / 2315.52 |
| l10-fetch-large100k-header_fields_range | imap.fetch | 0.28 / 0.30 / 0.31 | 0.46 / 0.48 / 0.60 |
| l10-fetch-large10k-body_random | imap.fetch | 0.15 / 0.17 / 0.42 | 0.19 / 0.26 / 0.89 |
| l10-fetch-large10k-envelope_last | imap.fetch | 0.16 / 0.17 / 0.20 | 0.66 / 0.87 / 1.08 |
| l10-fetch-large10k-flags_all | imap.fetch | 0.93 / 0.99 / 1.03 | 5.68 / 5.82 / 7.73 |
| l10-fetch-large10k-header_fields_range | imap.fetch | 0.24 / 0.26 / 0.28 | 0.51 / 0.96 / 1.07 |
| l10-fetch-large250k-body_random | imap.fetch | 0.15 / 0.18 / 0.20 | 0.17 / 0.23 / 0.34 |
| l10-fetch-large250k-envelope_last | imap.fetch | 0.16 / 0.17 / 0.21 | 0.70 / 0.72 / 0.75 |
| l10-fetch-large250k-flags_all | imap.fetch | 20.49 / 26.34 / 27.71 | 179.13 / 855.55 / 1335.30 |
| l10-fetch-large250k-header_fields_range | imap.fetch | 0.28 / 0.29 / 0.31 | 0.41 / 0.52 / 0.65 |
| l11-search-body-common-large100k | imap.search.body-common | 1.81 / 2.15 / 2.24 | 43.50 / 68.17 / 714.50 |
| l11-search-body-common-large10k | imap.search.body-common | 0.41 / 0.47 / 0.55 | 3.44 / 4.42 / 5.61 |
| l11-search-body-common-large250k | imap.search.body-common | 3.75 / 5.27 / 5.51 | 136.32 / 234.81 / 493.63 |
| l11-search-body-rare-large100k | imap.search.body-rare | 0.20 / 0.26 / 0.28 | 14.55 / 16.98 / 18.60 |
| l11-search-body-rare-large10k | imap.search.body-rare | 0.14 / 0.15 / 0.16 | 1.59 / 1.82 / 1.92 |
| l11-search-body-rare-large250k | imap.search.body-rare | 0.30 / 0.46 / 0.50 | 35.71 / 41.17 / 48.72 |
| l11-search-date-large100k | imap.search.date | 0.54 / 0.55 / 0.55 | 246.46 / 254.53 / 270.33 |
| l11-search-date-large10k | imap.search.date | 0.12 / 0.12 / 0.13 | 24.89 / 25.41 / 28.55 |
| l11-search-date-large250k | imap.search.date | 0.89 / 0.91 / 0.92 | 608.51 / 633.34 / 646.65 |
| l11-search-from-large100k | imap.search.from | 0.14 / 0.66 / 0.68 | 16.54 / 22.81 / 25.50 |
| l11-search-from-large10k | imap.search.from | 0.10 / 0.14 / 0.15 | 1.84 / 2.32 / 2.40 |
| l11-search-from-large250k | imap.search.from | 0.17 / 1.50 / 1.53 | 41.66 / 61.77 / 63.39 |
| l11-search-subject-large100k | imap.search.subject | 0.16 / 0.21 / 0.23 | 14.45 / 17.05 / 18.57 |
| l11-search-subject-large10k | imap.search.subject | 0.13 / 0.14 / 0.15 | 1.60 / 1.86 / 1.93 |
| l11-search-subject-large250k | imap.search.subject | 0.19 / 0.31 / 0.38 | 35.63 / 43.05 / 48.98 |
| l11-search-text-multi-large100k | imap.search.text-multi | 0.39 / 0.79 / 0.94 | 16.20 / 37.89 / 44.91 |
| l11-search-text-multi-large10k | imap.search.text-multi | 0.18 / 0.22 / 0.24 | 1.74 / 2.78 / 3.50 |
| l11-search-text-multi-large250k | imap.search.text-multi | 0.61 / 1.46 / 1.59 | 37.90 / 93.53 / 131.10 |

