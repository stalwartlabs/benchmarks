### Track C (bench-c20-1026)

| Host | Role | Size | CPU | Physical host |
|---|---|---|---|---|
| load1 | load | Standard_D16as_v7 | AMD EPYC 9V45 96-Core Processor | AVC17 |
| load2 | load | Standard_D16as_v7 | AMD EPYC 9V45 96-Core Processor | AVC17 |
| stalwart | stalwart | Standard_D8ads_v7 | AMD EPYC 9V45 96-Core Processor | AVC17 |
| dovecot | postfix-dovecot | Standard_D8ads_v7 | AMD EPYC 9V45 96-Core Processor | AVC17 |
| sink | sink | Standard_D2as_v7 | AMD EPYC 9V45 96-Core Processor | AVC17 |

| From | To | TCP RTT p50 us | p99 us |
|---|---|---|---|
| dovecot | load1 | 64.9 | 81.5 |
| dovecot | load2 | 77.3 | 86.2 |
| dovecot | sink | 79.9 | 108.4 |
| dovecot | stalwart | 77.3 | 89.6 |
| load1 | dovecot | 64.0 | 73.8 |
| load1 | load2 | 77.8 | 96.2 |
| load1 | sink | 78.3 | 108.9 |
| load1 | stalwart | 75.5 | 83.3 |
| load2 | dovecot | 77.0 | 87.6 |
| load2 | load1 | 77.1 | 94.5 |
| load2 | sink | 78.0 | 104.0 |
| load2 | stalwart | 75.8 | 84.7 |
| sink | dovecot | 76.5 | 99.2 |
| sink | load1 | 77.2 | 101.6 |
| sink | load2 | 77.2 | 86.1 |
| sink | stalwart | 78.1 | 89.7 |
| stalwart | dovecot | 77.2 | 91.0 |
| stalwart | load1 | 74.7 | 87.2 |
| stalwart | load2 | 77.4 | 86.7 |
| stalwart | sink | 77.4 | 103.8 |

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

#### smtp-in

| Cell | Operation | dovecot+fsync-always ops/s at SLO (p99 ms) |
|---|---|---|
| c03 | smtp | 188 (452.61) |
| c03 | smtp.message | 188 (48.29) |

