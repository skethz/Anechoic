# Single-core RTL ablation on K2000

The [results table](TABLE.md) gives cycles per anneal on 16 paired, echo-corrected O1 starts and the resource counts of nine routed designs. The bandwidth control changes only the read limit inside the eight-queue, four-copy design. The physical four-extractor design also changes the number of dual-port coupling-memory copies. The barrier design waits for all eight decision groups before updating fields. Timing runs from entry into SEED to entry into OUT.

## Verify the archived results

From this directory, run the following command with Python 3.10 or newer.

```sh
python3 verify.py --print-table
```

The verifier checks the [file digests](SHA256SUMS), the stimulus and reference-output lengths, the cut and flip count for every trial, the per-trial start and output events, zero word mismatches, and the final route and utilization reports. It regenerates both tables and compares them with the published Markdown. The 12 RTL logs cover nine implemented designs and three instrumented runs. The eight-grant streaming and barrier controls must match their corresponding routed RTL sources cycle for cycle on every trial.

| Files | Contents |
|---|---|
| [inputs](inputs/) | Complete AXI stimulus, expected output and counts used by the testbench |
| [src](src/) | Exact RTL for the nine routed cores, the row-limit control, three measured testbenches and the C++ reference generator |
| [RTL logs](logs/rtl/) and [reference output](logs/reference.log) | Timing events and output checks for the 16 fixed trial IDs |
| [Route records](logs/route/) | Original build logs, utilization, timing, slack and route reports for each implementation |
| [Vivado scripts](scripts/) | Original out-of-context synthesis and implementation Tcl flows |

Machine identifiers and machine-specific directory prefixes in the archived logs and reports have been replaced with neutral labels. The design names, numerical measurements and measurement boundaries are preserved.

## Rebuild the inputs

The signed K2000 instance uses the [public benchmark source](https://github.com/hariby/SA-complete-graph/blob/785d664eddb65a5c90a03f5c2253a7cb2cf6ef8b/WK2000_1.rud). The [dataset script](../../../data/fetch_data.py) downloads and packs the graph. The packed graph SHA-256 is `a3058db6cffdbb632bc46223958cc7f8dce17da22eb2e4bbed6f60f811e6c0e9`. O1 uses 280 synchronous steps, a geometric temperature schedule from 15 to 5, pinning 8, and the ramped κT correction with κ = 1.75. The global seed is 20261004. The trial IDs are 42700000 through 42700015.

With a C++17 compiler on the PATH, the following commands regenerate the complete 33,050 input beats, the 5,024 expected output words and the reference log. Each trial emits 32 final spin words, its cut, its flip count and 280 step counters. The regenerated files must match the archived files byte for byte.

```sh
python3 ../../../data/fetch_data.py --only k2000
python3 replay.py inputs work/inputs ../../../data/k2000/K2000.bin
```

## Replay the simulations

The archived measurements used Verilator 5.032 and a C++17 compiler on Linux. The complete input vector is included for offline replay. Each output directory in these examples must be new. Each replay compares every trial's cycle count with its original log, and the testbench checks all 5,024 output words against the reference. Supply `--design` to select one or more designs, or omit it to run them all.

```sh
python3 replay.py rtl work/example --design cap4 --design cap8
python3 replay.py rtl work/rtl
python3 verify.py --rtl-logs work/rtl
```

## Repeat synthesis and routing

The original runs used Vivado 2025.1 build 6140274 with the V80 device data installed, part `xcv80-lsva4737-2MHP-e-S`, speed file −2MHP PRODUCTION 2.04. The Tcl flows set four threads, a 4.000 ns clock after out-of-context synthesis and before optimization, and the placement block `CLOCKREGION_X2Y5:CLOCKREGION_X4Y7`. Each resource measurement comes from one placement per design after the final physical optimization.

```sh
python3 replay.py route work/route
python3 verify.py --route-reports work/route
```

The `route` command also accepts `--design`, for example `--design matched4`. Rebuilding routes uses Vivado on a workstation with the device files. The archived-results check uses Python alone.
