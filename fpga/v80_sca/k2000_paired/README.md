# Anechoic on V80 and GH200 with matched starts

We measured the time to reach a final signed K2000 cut of at least **33,337**. Each device ran the same 120,000 initial states at each schedule length. On V80, a physical launch starts twelve engines. A 120-chain request charges all ten successive physical launches. GH200 processes 120 chains in one request. The native 1,000-launch V80 sample consists of the first 12,000 starts. The 10,000-launch sample includes every start.

| Steps per chain | Device and request size | Successful requests | Mean device time per request (ms) | Device TTS₉₉ (ms) |
|---:|---|---:|---:|---:|
| 3,650 | V80, 12 parallel starts | 34/1,000 | 0.62453 | 83.1441 |
| 3,650 | V80, 12 parallel starts | 297/10,000 | 0.62449 | 95.3851 |
| 3,650 | V80, 10 consecutive launches of 12 | 258/1,000 | 6.24485 | 96.3741 |
| 3,650 | GH200, 120 parallel starts | 258/1,000 | 5.95401 | 91.8856 |

All 120,000 V80 endpoints at each schedule length matched their GH200 spin vectors, signed cut values and total flip counts. Each trajectory runs to the scheduled end. Both devices used seed 20261004. Request zero starts at trial 431100000 and every subsequent request advances by 120.

The V80 device clock was 250 MHz. Each engine has a passive launch-to-completion cycle counter. A physical launch charges the maximum of its twelve counter readings. The 120-chain case sums ten launch times. The graph and base table were resident before measurement. Host elapsed time, saved separately, includes all returned V80 endpoints and winner selection. The GH200 host receives the device-selected winner. The device-time columns follow each implementation’s measured resident boundary.

TTS₉₉ uses the observed request success rate and mean request time. A success rate of at least 99% charges one request. Other positive rates multiply mean time by log(0.01)/log(1−p). The per-schedule JSON also gives the whole-request restart estimate and the exact binomial interval on success probability. [Device and host records](records) · [Matched GH200 experiment and GbSB comparison](../../../gpu/k2000_gbsb/README.md)

## Recalculate the measurements

From the repository root, run the verifier with Python 3.10 or newer. Supplying the signed graph also checks all recorded cut values. For 21,400 steps, the verifier compares all recorded V80 endpoint bits with the independently stored GH200 endpoint files.

```bash
python3 fpga/v80_sca/k2000_paired/verify.py
python3 data/fetch_data.py --only k2000
python3 fpga/v80_sca/k2000_paired/verify.py --graph data/k2000/K2000.bin
```

The records contain three compressed CSVs giving individual chains, physical launches and 120-chain requests. The four endpoint files contain the board-returned states in trial order, 30,000 chains per file and 256 bytes per chain. Spin bits are least-significant bit first within each byte. Unused spin positions are zero.

## Hardware and measurement sources

The 3,650-step run uses the paper’s twelve-engine V80 arithmetic and schedule table. The extended RTL addresses the base table at floor(3649t/21399) for 21,400 consecutive steps. It retains all spin, field, random-number and Onsager state between steps. The schedule test exercises the controller, resets and final step. [Original V80 design](../DESIGN.md) · [Extended RTL](source/sca_core.v) · [Base schedule](../../../gpu/k2000_gbsb/base_schedule.bin) · [Controller test](source/check_schedule_rtl.py)

The supplied C++ host uses the design-generated AXI register header, the timer-offset header, AMI, and C++17. Its arguments specify the signed graph, base table, step count, resident image UUID, measured clock in MHz, first trial, number of 120-chain requests, and a fresh output directory. It warms the graph and table on disjoint IDs, reads every counter and checks the signed graph score before storing the raw endpoints. [Measurement host](source/board_host.cpp)
