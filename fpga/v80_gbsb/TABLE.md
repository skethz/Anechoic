# Anechoic and GbSB on the same V80 and the same GH200

Each entry gives fractional device TTS₉₉ in milliseconds, followed by successful requests / measured requests. Every request at width 120 charges all 120 trajectories. V80 executes ten consecutive launches of twelve, while GH200 processes 120 in one batch. A request succeeds if its best final signed cut reaches the threshold.

## Target ≥33,337 (best-known K2000 cut)

| Steps per chain | Anechoic V80 | Anechoic GH200 | GbSB V80 | GbSB GH200 |
|---:|---:|---:|---:|---:|
| 1,000 | 447.34 (18/1,000) | 284.34 (18/1,000) | 1,755,868.78 (5/1,000) | 14,047.99 (5/1,000) |
| 3,650 | 96.37 (258/1,000) | 61.11 (258/1,000) | — (0/1,000) | — (0/1,000) |
| 21,400 | 89.95 (843/1,000) | 104.11 (843/1,000) | 39,940.96 (1,000/1,000) | 444.41 (1,000/1,000) |

## Target ≥33,004 (99% of the best-known K2000 cut, rounded up)

| Steps per chain | Anechoic V80 | Anechoic GH200 | GbSB V80 | GbSB GH200 |
|---:|---:|---:|---:|---:|
| 1,000 | 1.76 (1,000/1,000) | 1.12 (1,000/1,000) | 1,911.19 (1,000/1,000) | 15.29 (1,000/1,000) |
| 3,650 | 6.24 (1,000/1,000) | 3.96 (1,000/1,000) | 6,851.33 (1,000/1,000) | 48.80 (1,000/1,000) |
| 21,400 | 36.16 (1,000/1,000) | 41.86 (1,000/1,000) | 39,940.96 (1,000/1,000) | 444.41 (1,000/1,000) |

**Timing boundary.** At 21,400 steps and cut 33,337, Anechoic device TTS₉₉ was 89.95 ms on V80 and 104.11 ms on GH200. Elapsed through host return, the ordering reversed to 110.35 ms on V80 (all 120 endpoints) and 104.16 ms on GH200 (one winner). V80 device counters omit staggered engine starts, polling and readback, gaps between launches, and the host reduction of ten winners. GH200 times the 120-chain winner selection on the device. Charging whole requests at this target gives 108.49 ms and 125.58 ms of device time, respectively.

**Request width.** All 120-chain requests reached 33,004. GbSB also reached 33,337 on every 21,400-step request. In these cells fractional TTS₉₉ equals one full request time. At cut 33,004, the native twelve-chain V80 TTS₉₉ values across all 10,000 launches, in step order, were 0.176, 0.624, 3.616 ms for Anechoic and 191.12, 685.13, 3,994.10 ms for GbSB, one tenth of the width-120 times. The paired GH200 runs all used width 120.

The two algorithms received identical initial spin signs for each chain ID. For each algorithm and schedule, offline comparison of the original captures found that all 120,000 final bitmaps agreed between devices. A dash indicates zero observed successes and an unavailable finite TTS estimate. For GbSB at 1,000 steps and cut 33,337, 5/1,000 successes give an exact 95% request-success interval of 0.163% to 1.163%. At zero successes, the two-sided exact 95% upper confidence limit is 0.368% for 1,000 requests and 0.0369% for 10,000. GbSB’s pump update depends on the selected horizon M through 1/(M−t) from the first step. The three rows therefore evaluate different schedules.

## Native V80 control at cut ≥33,337

Each observation below is a single physical twelve-chain launch. The first 1,000 launches form a chronological subset of the 10,000 launches. Each 120-chain request above contains ten of these launches.

| Steps per chain | Anechoic, first 1,000 | GbSB, first 1,000 | Anechoic, all 10,000 | GbSB, all 10,000 |
|---:|---:|---:|---:|---:|
| 1,000 | 270.43 (3/1,000) | — (0/1,000) | 427.25 (19/10,000) | 1,759,833.04 (5/10,000) |
| 3,650 | 83.14 (34/1,000) | — (0/1,000) | 95.39 (297/10,000) | — (0/10,000) |
| 21,400 | 89.96 (169/1,000) | 3,994.10 (1,000/1,000) | 89.67 (1,695/10,000) | 3,994.10 (10,000/10,000) |

Both V80 implementations ran at nominal 250 MHz. At 21,400 steps, the twelve-engine Anechoic image used 74.07% of LUTs and 88.69% of block RAM tiles. The GbSB image used one matrix core with twelve trajectory lanes, 7.23% of LUTs and 2.04% of block RAM tiles. These percentages include the board shell. At cut 33,337 and 21,400 steps, the GbSB-to-Anechoic V80 TTS₉₉ ratio was 444.0 at width 120 and 44.5 across all native launches. These ratios describe the two ports at their different resource allocations. [Routed resources and timing](hardware.json)

At 3,650 steps, the table uses the GH200 run that alternated the two solvers in successive blocks. In an earlier run on the same shared GPU, Anechoic produced the same 258 successful requests and 91.89 ms device TTS₉₉, versus 61.11 ms here. Both runs invoked the same executable path. This spread at 3,650 steps exceeds the V80–GH200 difference at 21,400 steps. The device ordering at 21,400 steps describes this acquisition. [Earlier acquisition](../v80_sca/k2000_paired/records/3650/results.json)

Goto et al. report 9.61 ms TTS₉₉ on their Intel Agilex 7 implementation at cut 33,337, with 989 successes in 1,000 single-trajectory runs. Their 9.61 ms is faster than every cut-33,337 TTS₉₉ measured here. Its request width, datapath and clock differ from these ports. [GbSB, Table I](https://journals.aps.org/prapplied/pdf/10.1103/2qd9-x6v8#page=5)

The machine-readable results include mean device and host times, fractional and whole-request device TTS₉₉, request and chain success counts, exact 95% intervals for request success, and both cut thresholds for the native-width control. [All results](results.csv) · [Protocol and reproduction](README.md)
