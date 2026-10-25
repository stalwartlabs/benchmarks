### Track C (bench-c19-1026)

| Host | Role | Size | CPU | Physical host |
|---|---|---|---|---|
| load1 | load | Standard_D16as_v7 | AMD EPYC 9V45 96-Core Processor | DXB24 |
| load2 | load | Standard_D16as_v7 | AMD EPYC 9V45 96-Core Processor | DXB24 |
| stalwart | stalwart | Standard_D8ads_v7 | AMD EPYC 9V45 96-Core Processor | DXB24 |
| dovecot | postfix-dovecot | Standard_D8ads_v7 | AMD EPYC 9V45 96-Core Processor | DXB24 |
| sink | sink | Standard_D2as_v7 | AMD EPYC 9V45 96-Core Processor | DXB24 |

| From | To | TCP RTT p50 us | p99 us |
|---|---|---|---|
| dovecot | load1 | 62.3 | 73.8 |
| dovecot | load2 | 62.0 | 69.3 |
| dovecot | sink | 67.2 | 76.3 |
| dovecot | stalwart | 66.2 | 76.7 |
| load1 | dovecot | 62.1 | 72.6 |
| load1 | load2 | 63.2 | 71.1 |
| load1 | sink | 66.2 | 83.5 |
| load1 | stalwart | 65.5 | 73.2 |
| load2 | dovecot | 62.4 | 73.2 |
| load2 | load1 | 63.3 | 72.0 |
| load2 | sink | 70.0 | 86.5 |
| load2 | stalwart | 65.4 | 73.7 |
| sink | dovecot | 69.1 | 84.2 |
| sink | load1 | 63.6 | 74.3 |
| sink | load2 | 64.7 | 73.3 |
| sink | stalwart | 65.7 | 77.1 |
| stalwart | dovecot | 66.0 | 78.8 |
| stalwart | load1 | 62.8 | 70.7 |
| stalwart | load2 | 65.3 | 76.8 |
| stalwart | sink | 66.8 | 76.6 |

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
| c15-sessions16-10p-uid_true | imap.uid_expunge | 2.65 / 7.16 / 10.81 | 8.30 / 39.62 / 77.06 | 6.54 / 257.66 / 1110.02 |
| c15-sessions16-range100-uid_false | imap.expunge | 3.54 / 8.93 / 13.07 | 54.05 / 134.27 / 251.13 | 48.99 / 1154.05 / 1247.23 |

#### smtp-in

| Cell | Operation | stalwart ops/s at SLO (p99 ms) | dovecot ops/s at SLO (p99 ms) | dovecot+fsync-always ops/s at SLO (p99 ms) |
|---|---|---|---|---|
| c03 | smtp | 3,889 (116.48) | 264 (899.58) |  |
| c03 | smtp.message | 3,889 (102.91) | 264 (100.80) |  |

