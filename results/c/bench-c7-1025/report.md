### Track C (bench-c7-1025)

| Host | Role | Size | CPU | Physical host |
|---|---|---|---|---|
| load1 | load | Standard_D16as_v7 | AMD EPYC 9V45 96-Core Processor | SYD29 |
| load2 | load | Standard_D16as_v7 | AMD EPYC 9V45 96-Core Processor | SYD29 |
| stalwart | stalwart | Standard_D8ads_v7 | AMD EPYC 9V45 96-Core Processor | SYD29 |
| dovecot | postfix-dovecot | Standard_D8ads_v7 | AMD EPYC 9V45 96-Core Processor | SYD29 |
| sink | sink | Standard_D2as_v7 | AMD EPYC 9V45 96-Core Processor | SYD29 |

| From | To | TCP RTT p50 us | p99 us |
|---|---|---|---|
| dovecot | load1 | 63.5 | 89.8 |
| dovecot | load2 | 62.8 | 93.1 |
| dovecot | sink | 67.5 | 104.1 |
| dovecot | stalwart | 64.0 | 93.7 |
| load1 | dovecot | 64.5 | 104.6 |
| load1 | load2 | 65.4 | 108.0 |
| load1 | sink | 68.0 | 96.4 |
| load1 | stalwart | 57.3 | 78.5 |
| load2 | dovecot | 64.0 | 104.7 |
| load2 | load1 | 64.4 | 97.9 |
| load2 | sink | 66.3 | 93.8 |
| load2 | stalwart | 63.7 | 95.5 |
| sink | dovecot | 67.3 | 113.5 |
| sink | load1 | 63.9 | 98.6 |
| sink | load2 | 63.2 | 90.5 |
| sink | stalwart | 63.3 | 83.5 |
| stalwart | dovecot | 65.8 | 106.5 |
| stalwart | load1 | 56.8 | 86.4 |
| stalwart | load2 | 63.8 | 95.9 |
| stalwart | sink | 66.6 | 95.8 |

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
| l14-copy-move-large100k-copy-10p | imap.copy | 22.08 / 25.32 / 26.98 | 87.61 / 90.59 / 92.38 |
| l14-copy-move-large100k-copy-one | imap.copy | 0.09 / 0.10 / 0.11 | 0.41 / 0.86 / 1.51 (**7 errors**) |
| l14-copy-move-large100k-copy-range100 | imap.copy | 0.31 / 0.36 / 0.38 | 1.40 / 1.55 / 2.75 |
| l14-copy-move-large100k-move-10p | imap.move | 77.95 / 136.54 / 137.66 | 11763.71 / 22880.26 / 26992.64 (**3 errors**) |
| l14-copy-move-large100k-move-one | imap.move | 0.23 / 0.26 / 0.39 | 8.53 / 16.66 / 514.62 |
| l14-copy-move-large100k-move-range100 | imap.move | 1.31 / 1.46 / 1.55 | 133.82 / 165.31 / 691.33 |
| l14-copy-move-large10k-copy-10p | imap.copy | 2.58 / 2.96 / 3.07 | 8.97 / 9.52 / 9.99 |
| l14-copy-move-large10k-copy-one | imap.copy | 0.08 / 0.09 / 0.10 | 0.38 / 0.64 / 1.10 (**3 errors**) |
| l14-copy-move-large10k-copy-range100 | imap.copy | 0.31 / 0.34 / 0.35 | 1.33 / 1.46 / 1.92 |
| l14-copy-move-large10k-move-10p | imap.move | 20.24 / 24.84 / 30.31 | 596.86 / 2067.45 / 2925.05 |
| l14-copy-move-large10k-move-one | imap.move | 0.12 / 0.14 / 0.15 | 4.45 / 9.94 / 1005.31 |
| l14-copy-move-large10k-move-range100 | imap.move | 0.78 / 1.00 / 1.04 | 86.33 / 1086.46 / 1584.13 |
| l14-copy-move-large250k-copy-10p | imap.copy | 64.22 / 72.89 / 74.62 | 221.89 / 235.65 / 238.27 |
| l14-copy-move-large250k-copy-one | imap.copy | 0.10 / 0.12 / 0.17 | 0.40 / 0.63 / 0.89 |
| l14-copy-move-large250k-copy-range100 | imap.copy | 0.34 / 0.40 / 0.42 | 1.40 / 1.50 / 2.90 |
| l14-copy-move-large250k-move-10p | imap.move | 148.29 / 191.74 / 211.20 | 32923.65 / 46563.33 / 48087.04 |
| l14-copy-move-large250k-move-one | imap.move | 0.28 / 0.31 / 0.60 | 12.76 / 21.70 / 36.39 |
| l14-copy-move-large250k-move-range100 | imap.move | 0.96 / 1.74 / 2.24 | 189.38 / 212.74 / 649.92 |
| l15-expunge-large100k-one-uid_false | imap.expunge | 0.87 / 1.21 / 1.44 | 2.64 / 3.28 / 3.52 |
| l15-expunge-large100k-one-uid_true | imap.uid_expunge | 0.87 / 1.01 / 1.22 | 2.61 / 2.88 / 3.32 |
| l15-expunge-large10k-one-uid_false | imap.expunge | 0.16 / 0.20 / 0.27 | 0.88 / 1.05 / 1.53 |
| l15-expunge-large10k-one-uid_true | imap.uid_expunge | 0.16 / 0.18 / 0.20 | 1.00 / 1.09 / 1.21 |
| l15-expunge-large250k-one-uid_false | imap.expunge | 0.75 / 1.01 / 1.07 | 6.07 / 6.41 / 6.71 |
| l15-expunge-large250k-one-uid_true | imap.uid_expunge | 0.74 / 1.07 / 1.26 | 6.08 / 6.46 / 7.27 |

#### Cells with operation errors

- l14-copy-move-large100k-copy-one imap.copy dovecot: 7 errors
- l14-copy-move-large100k-move-10p imap.move dovecot: 3 errors
- l14-copy-move-large10k-copy-one imap.copy dovecot: 3 errors

