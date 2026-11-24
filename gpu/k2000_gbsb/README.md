# Anechoic and GbSB on one GH200

We measured K2000 time-to-solution at **cut ≥33,337** on the same NVIDIA GH200. For each algorithm, we issued **1,000 device requests of 120 chains**. Each chain ran 21,400 steps. Both algorithms received the same 120,000 initial spin-sign vectors. The GPU selected the highest final cut within each request.

| Algorithm | Successful requests | Successful chains | Mean device time per request | TTS₉₉ |
|---|---:|---:|---:|---:|
| Anechoic | 843/1,000 | 1,818/120,000 | 41.859 ms | **104.114 ms** |
| GbSB, our implementation | 1,000/1,000 | 118,185/120,000 | 444.408 ms | **444.408 ms** |

At this batch width and step count, **GbSB’s TTS₉₉ was 4.27 times Anechoic’s**. GbSB reached the target more often per chain. Anechoic’s shorter time per request outweighed its greater number of restarts. In the first and second blocks of 500 requests, Anechoic succeeded 407 and 436 times, respectively. GbSB succeeded 500 times in each half. The observed timing ratio had a 95% interval of 3.96–4.61 when resampling matched runs in consecutive groups of ten within each acquisition block. Each solver can have a different best width and step count. [Per-request records](records/rounds.csv) · [Counts, intervals and timing](records/results.json)

### Relationship to the original GbSB measurement

GbSB’s published K2000 result on an Intel Agilex 7 FPGA was 989 successes in 1,000 single-trajectory runs and 9.61 ms TTS₉₉. We matched its target and repetition count. Each GH200 request contained 120 trajectories. Comparing the two rows above holds the device, graph, width, step count and timing boundary fixed. The paper’s FPGA result has a separate hardware and parallelism configuration. [GbSB, Table I and Section VI](https://arxiv.org/pdf/2508.17655v5#page=9)

### Protocol

- The signed graph has 2,000 vertices and 1,999,000 edges. Padding in Anechoic’s 2,048-slot representation contributes zero to the objective. All 240,000 final spin vectors are available below in chronological order. Each vector is 256 bytes, least significant bit first within each byte.
- Each arm used four blocks of 250 requests. Request `r` used trial IDs `431100000 + 120*r` through `431100119 + 120*r`. Anechoic used seed 20261004. GbSB used these initial spin signs and deterministic, independent magnitudes for its continuous positions. Its momentum started at zero.
- Anechoic retained its parallel binary update and Onsager correction. At step `t`, it read row `floor(t*3649/21399)` of the saved 3,650-step schedule. The run ended after annealing. GbSB used the published best-known-cut parameters `A = 0.196` and `Δt = 1.25`, FP32 state updates, quantized Q2.14 interaction inputs, exact signed integer matrix products and inelastic walls.
- Events on the GPU timed initialization, annealing, final scoring and selection of the winner. The graph and schedule were already resident. Graph upload, warm-up, answer transfer to the host and diagnostic copies followed separate timing boundaries. The measurements were acquired on a shared GH200. The saved device times reflect its load during acquisition.
- For measured request success fraction `p`, TTS₉₉ is the mean device time multiplied by `max(1, log(0.01)/log(1-p))`. All observed requests succeeding gives one request. Rounding the restart count up to an integer gives **125.577 ms** for Anechoic and **444.408 ms** for GbSB.

### Recalculate and reproduce

From the repository root, the first command recalculates both TTS values directly from the 1,000 paired rows with Python. The next two commands also check every endpoint against the signed graph. Python 3.10 or newer supports the integer population count used by the verifier.

```bash
python3 gpu/k2000_gbsb/verify.py
python3 data/fetch_data.py --only k2000
python3 gpu/k2000_gbsb/verify.py --graph data/k2000/K2000.bin
```

For a new GPU measurement, select one Hopper GPU using `CUDA_VISIBLE_DEVICES`. The published run used CUDA 13.3 and cuBLAS on a GH200. The output path must be new. For a short functional test, append `--rounds 1`. The seed IDs, schedules and returned endpoints allow hardware-independent checks of the output. Device timings vary with GPU clocks and other jobs.

```bash
CUDA_VISIBLE_DEVICES=0 python3 gpu/k2000_gbsb/measure.py data/k2000/K2000.bin /path/to/new-run
```

[CUDA sources](cuda) · [Measurement driver](measure.py) · [Independent cut and timing verifier](verify.py) · [Final spins and per-request data](records)
