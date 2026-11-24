# Paired Anechoic and GbSB measurements on V80 and GH200

[Four-way TTS₉₉ tables](TABLE.md) · [Machine-readable results](results.csv) · [Measurement records](records)

We ran both algorithms on the **same AMD Alveo V80** and the **same NVIDIA GH200**. The operators used one V80 board at PCIe address `01:00.0` across sessions. The public FPGA records identify the resident logic images by UUID and image hash. Board identity across sessions rests on the operators' record. For the GH200, pseudonymous identifiers from before and after each acquisition block identify the same device. At each of three step counts, each implementation received 1,000 requests of 120 chains. The table reports the time to reach signed K2000 cuts of at least **33,004** and **33,337**. It includes the native twelve-chain V80 measurements. The Intel Agilex result in GbSB Table I is a separate literature reference. [GbSB paper](https://journals.aps.org/prapplied/pdf/10.1103/2qd9-x6v8#page=5)

The submitted 280-step O1 result uses twelve concurrent V80 engines and a K2000 target of 33,000. The four-way tables below the title use the listed 1,000-, 3,650- and 21,400-step schedules and identify their request widths explicitly.

## Matched inputs

K2000 has 2,000 active spins and 1,999,000 signed edges. A 256-byte terminal record contains 2,000 spins followed by 48 zero padding bits. Request `r` uses chain IDs `431100000 + 120*r` through `431100119 + 120*r`. We matched every initial **sign**. Anechoic starts from discrete spins. GbSB also requires continuous magnitudes and zero initial momenta. We checked the initial signs for all 120,000 IDs using a CUDA implementation and the Anechoic CPU generator. [Initial-sign check](../../gpu/k2000_gbsb/cuda/gbsb/signs.cu)

| Implementation detail | Anechoic | Our GbSB port |
|---|---|---|
| Per-chain schedule | The 3,650-row base schedule supplies row `floor(3649*t/(M−1))` at step `t`. The short FPGA run loads the precomputed 1,000 rows. The extended FPGA sequencer advances through the base table for 21,400 steps. | Each of the 2,000 oscillators has its own pump. A = 0.196 and Δt = 1.25 for all horizons. The update uses `1/(M−t)`, so each horizon has its own schedule. |
| V80 launch | Twelve separate engines, with a passive counter for each | One 16 × 16 signed matrix-product core shared by twelve trajectories, with one passive counter |
| GPU request | 120 chains, scored and reduced to a winning partition on the device | 120 chains, signed INT8 slices and exact INT32 matrix products via cuBLAS, followed by FP32 state updates and on-device winner selection |
| Endpoint | Final spin signs after all M steps | Signs of the final positions after all M steps |

The Anechoic comparison uses the prespecified, tapered one-step memory coefficient stored in the base table. In the base schedule, 3,598 of 3,650 rows have a nonzero scheduled coefficient (`kconst`). The online response multiplier (`kcorr`) is zero throughout. The GPU log label `off` denotes the disabled experimental triple-flip move. The scheduled memory term remains active where specified by the table. [Schedule generator](../v80_sca/k2000_paired/source/optimum_tables.hpp) · [GPU launch options](../../gpu/k2000_gbsb/cuda/anechoic/paired_main.cuh)

The GbSB ports round interaction inputs to the nearest Q2.14 value, with ties to even. They use a signed integer field sum, FP32 updates and inelastic walls. The CUDA dynamics use explicit round-to-nearest FP32 multiplies and adds. GbSB starts the pump at 1 and uses the published K2000 best-cut parameters A = 0.196 and Δt = 1.25 at all three horizons. The short and base schedules test smaller step budgets. The 21,400-step schedule also matches the paper’s best-cut operating point. Agreement is checked on terminal signs and signed graph cuts. The original Agilex paper describes its own fixed-point matrix and FP32 update hardware. The V80 resource percentages include the shell. The 1,000- and 3,650-step Anechoic image used 74.05% of LUTs and 88.69% of block RAM tiles. [GbSB paper](https://journals.aps.org/prapplied/pdf/10.1103/2qd9-x6v8#page=5) · [GbSB HLS kernel](src/gbsb_kernel.cpp) · [GbSB CUDA implementation](../../gpu/k2000_gbsb/cuda/gbsb) · [Routed V80 design records](hardware.json)

## Timing and success

A request succeeds if at least one final cut reaches the target. The runs finish their full schedule. The device and host timers cover the following operations.

- On V80, the GbSB counter spans kernel start to completion, including initialization, dynamics, final signed scoring, per-launch winner selection and output writes. Anechoic charges the maximum of its twelve engine counters per launch. The host triggers those engines sequentially. The device metric excludes the offset between their starts, BAR polling and readback, gaps between launches and the final host reduction across ten launches. Both V80 measurements sum ten successive twelve-chain launch times for a 120-chain request. We converted cycles using the frequency derived from the routed clock dividers (249.99999975 MHz nominal). The host interval covers the launches, all 120 returned endpoints and collection of the winners. Offline graph checks follow that interval.
- Both V80 designs stage the graph and tables before acquisition. GbSB loads its matrix in one disjoint warm-up launch. Anechoic warms the matrix and target schedule with two disjoint launches. Within each 1,000-request cohort, every chain ID is distinct. The devices and horizons deliberately reuse the same cohort IDs. The one-request reproduction test repeats the first 120 IDs.
- On GH200, CUDA events on the measurement stream time initialization through final scoring and selection of the 120-chain winner. GbSB uploads the four-byte starting ID inside that interval. Anechoic supplies the ID as a kernel argument. The graph and schedule are resident. The host-time interval ends after receiving the winner. Additional diagnostic transfers follow. The shared GPU's clocks and concurrent load can affect the measured times. The three horizons use four 250-request acquisition blocks per solver. [GPU reproduction driver](../../gpu/k2000_gbsb/measure.py)

Each GH200 process first runs four unmeasured requests for Anechoic or three for GbSB on separate warm-up IDs. Both drivers pause between requests for 20% of the preceding device time, bounded to 0.5–10 ms, outside either timer. At 1,000 and 3,650 steps, the solver run first in each block was Anechoic, GbSB, Anechoic, GbSB. At 21,400 steps we use the previously acquired GH200 timing logs and endpoints. The earlier experiment interleaved other configurations. Among the two reported solvers, the first in its four blocks was Anechoic, GbSB, Anechoic, Anechoic.

The original multi-configuration acquisition driver `native.py` produced the 91.89 ms Anechoic measurement at 3,650 steps. The two-solver acquisition driver `table3650.py` produced the 61.11 ms measurement. Both called the common launch helper `run.py`. All eight original block logs identify the same executable path, `bin/match_a120`. Its frozen, pre-acquisition SHA-256 and the hash of the archived executable both equal `c249969e5dbebe9a2f09885c03e09be39b88b954d15103cfa2d4081026115ba8`. Each block identifies the executable by path. The packaged `measure.py` is a reproduction driver that builds both solvers in a fresh output directory and preserves their recorded relative block order. [GPU reproduction driver](../../gpu/k2000_gbsb/measure.py) · [Earlier GH200 comparison](../../gpu/k2000_gbsb/README.md)

With observed request success fraction `p`, fractional TTS₉₉ equals mean measured device time multiplied by `max(1, ln(0.01)/ln(1−p))`. This assumes independent restarts. With all requests successful, the estimate equals one mean request time. With zero observed successes, a finite point estimate is unavailable. The CSV also gives whole-request TTS₉₉ using the ceiling of the restart multiplier, host TTS₉₉, per-chain successes and two-sided exact 95% binomial intervals for request success. These intervals describe sampling uncertainty in the success rate. A native twelve-chain result always uses success measured directly at that width.

## Recalculate from records

Python 3.9 or later suffices for the record-based checks. To recalculate the original graph scores, supply the pinned edge list and a C++17 compiler. Run these commands from the repository root.

```bash
python3 fpga/v80_gbsb/verify.py
python3 fpga/v80_gbsb/format_table.py
python3 data/fetch_data.py --only k2000
python3 fpga/v80_gbsb/verify.py --edges data/k2000/WK2000_1.rud
```

During packaging we checked the GPU UUID from the before/after logs of every acquisition block. The public verifier checks the corresponding pseudonymous device tokens, chain IDs, image hashes, exact byte counts, padding, winner scores, FPGA counters and request boundaries. Each cohort index contains the two SHA-256 digests and lengths recorded separately from the original FPGA and GPU captures. The distributed package stores one copy of matching endpoint bytes, which the verifier checks against both recorded digests. Across all six cohorts the original captures held 720,000 matched endpoint pairs. In-run, the GbSB V80 host compares the first 120 states against a GPU reference. During offline validation we compared every pair in the two original captures and rescored its terminal spins against the signed graph. The optional `--edges` pass repeats that scoring on the distributed payload. FPGA launch logs and GPU per-trial and per-request timing logs remain separate. Existing published blocks are reused by relative path. The default verifier also checks the original-image restoration flag. The `--measurements-only` option isolates the numerical checks. [Raw data indices](records) · [Verification run receipt](VERIFICATION.json)

## Repeat the measurements

**NVIDIA GH200.** Set `CUDA_VISIBLE_DEVICES` to the chosen Hopper GPU and run the two solvers at each horizon. Each output directory must be new. For a one-request functional check, add `--rounds 1`. The published comparison used CUDA 13.3. To rerun the initial-sign validation, build and invoke the small CUDA checker below. [Both CUDA solvers](../../gpu/k2000_gbsb/cuda)

```bash
for steps in 1000 3650 21400; do
    python3 gpu/k2000_gbsb/measure.py data/k2000/K2000.bin "/path/to/run-$steps" --steps "$steps"
done
nvcc -std=c++17 -O3 -arch=sm_90 -Xcompiler=-ffp-contract=off gpu/k2000_gbsb/cuda/gbsb/signs.cu -o /tmp/gbsb-signs
/tmp/gbsb-signs 431100000 120000
```

**AMD Alveo V80.** The GbSB build and host run guide includes the HLS kernel, four-point simulation, AVED integration, passive counter, board build and physical acquisition. Anechoic uses the existing twelve-engine design, with a resampled host table at 1,000 steps and an extended RTL address sequencer at 21,400. The measured host for the short run takes the same input arguments as the existing host with the step count set to 1,000. [GbSB board instructions](board/README.md) · [Existing Anechoic board design and long schedules](../v80_sca/k2000_paired/README.md) · [Anechoic 1,000-step measurement host](src/anechoic_1000_host.cpp)
