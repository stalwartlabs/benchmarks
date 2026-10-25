### Track C (bench-c14-1026)

| Host | Role | Size | CPU | Physical host |
|---|---|---|---|---|
| load1 | load | Standard_D16as_v7 | AMD EPYC 9V45 96-Core Processor | DUB14 |
| load2 | load | Standard_D16as_v7 | AMD EPYC 9V45 96-Core Processor | DUB14 |
| stalwart | stalwart | Standard_D8ads_v7 | AMD EPYC 9V45 96-Core Processor | DUB14 |
| dovecot | postfix-dovecot | Standard_D8ads_v7 | AMD EPYC 9V45 96-Core Processor | DUB14 |
| sink | sink | Standard_D2as_v7 | AMD EPYC 9V45 96-Core Processor | DUB14 |

| From | To | TCP RTT p50 us | p99 us |
|---|---|---|---|
| dovecot | load1 | 60.4 | 70.0 |
| dovecot | load2 | 62.3 | 73.0 |
| dovecot | sink | 66.7 | 100.1 |
| dovecot | stalwart | 64.2 | 75.7 |
| load1 | dovecot | 60.5 | 73.4 |
| load1 | load2 | 59.5 | 75.7 |
| load1 | sink | 65.1 | 93.1 |
| load1 | stalwart | 61.8 | 74.0 |
| load2 | dovecot | 59.9 | 69.2 |
| load2 | load1 | 60.0 | 71.2 |
| load2 | sink | 66.1 | 98.5 |
| load2 | stalwart | 62.2 | 72.9 |
| sink | dovecot | 64.1 | 97.6 |
| sink | load1 | 59.8 | 73.9 |
| sink | load2 | 59.0 | 68.0 |
| sink | stalwart | 61.3 | 71.2 |
| stalwart | dovecot | 64.1 | 74.9 |
| stalwart | load1 | 58.9 | 73.2 |
| stalwart | load2 | 61.9 | 74.0 |
| stalwart | sink | 64.7 | 96.8 |

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

| Cell | Operation | stalwart p50 / p95 / p99 ms | dovecot p50 / p95 / p99 ms | dovecot+fsync-always p50 / p95 / p99 ms |
|---|---|---|---|---|
| c11-date-sessions1 | imap.search.date | 0.06 / 0.08 / 0.09 | 0.53 / 6.04 / 12.43 |  |
| c11-date-sessions16 | imap.search.date | 0.09 / 0.14 / 0.26 | 1.49 / 6.42 / 11.81 |  |
| c11-from-sessions1 | imap.search.from | 0.07 / 0.08 / 0.10 | 0.15 / 0.45 / 0.89 |  |
| c11-from-sessions16 | imap.search.from | 0.11 / 0.18 / 0.48 | 0.57 / 2.19 / 3.90 |  |
| c11-subject-sessions1 | imap.search.subject | 0.10 / 0.11 / 0.13 | 0.15 / 0.37 / 0.53 |  |
| c11-subject-sessions16 | imap.search.subject | 0.16 / 0.37 / 0.74 | 0.55 / 1.92 / 3.19 |  |
| c15-sessions1-10p-uid_false | imap.expunge | 0.25 / 1.42 / 4.51 | 2.28 / 81.66 / 1385.47 |  |
| c15-sessions1-10p-uid_true | imap.uid_expunge | 0.24 / 1.67 / 4.39 | 2.10 / 52.00 / 1212.41 | 2.62 / 1120.26 / 1303.55 |
| c15-sessions16-10p-uid_false | imap.expunge | 2.89 / 7.87 / 12.44 | 10.97 / 82.81 / 222.46 | 9.51 / 1062.91 / 1225.73 |

