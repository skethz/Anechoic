# Reproduction Guide

This guide maps the paper to the repository. Folder names carry the date of each study, because the scripts and frozen protocols refer to one another by these paths.

## Contents

1. [Repository structure](#repository-structure)
2. [Paper results and their code](#paper-results-and-their-code)
3. [FPGA builds](#fpga-builds)
4. [GPU builds](#gpu-builds)
5. [RTL regressions](#rtl-regressions)
6. [Proofs](#proofs)
7. [Release notes](#release-notes)

## Repository structure

| Folder | Contents |
|---|---|
| `fpga/v80_sca/` | V80 engine. RTL in `src/v6/` (`sca_core*.v`); HLS kernels, host programs and golden models in `src/`; build, run and analysis scripts in `scripts/`. Also the frozen protocols (`PROTOCOL_HW*.md`), the design notes (`DESIGN.md`, `MULTIBIT_SPEC.md`) and the result summaries (`RESULTS_HW.md`, `RESULTS_MULTIBIT.md`, `results/`). |
| `gpu/onsager_v2_20261007/` | Bit-exact kernel for the NVIDIA GH200 (`src/sca_gpu.cu`), with protocol, report and result tables. |
| `gpu/multibit_bias_20261008/` | GPU kernel with multi-bit couplings and bias, with its G-set results. |
| `asic/gf22_engine_v64_1p25_20261007/` | ASIC variant of the v6 engine at 1.25 GHz. RTL in `rtl/`; source RTL and golden model in `orig/`; RTL regression in `sim/` and `scripts/`; derived 12-engine totals in `results/`. |
| `asic/gf22_engine_v64_mb_20261008/` | Multi-bit ASIC variant (K = 2 and K = 4) with bias. |
| `research/dmft_sca_20261004/` | Dynamical mean-field theory of synchronous SCA. |
| `research/headline_echo_20261009/` | Echo statistics and plot of Figure 1. |
| `research/formal_verification_20261007/` | Lean 4/Mathlib (`SnowballFormal/`) and Rocq (`coq/`) proofs. |
| `research/algorithm_compare_20261007/`, `ablation_20261005/`, `theory_ideas_20261003/`, `iamp_evaluation_20261003/`, `statica_reproduction_20261003/`, `reaim_reproduction_20261003/` | The corrected update rules, the re-implemented baselines and their studies. |
| `research/fairness_audit_20261008/` | Comparison at the baselines' published settings (`k2000_pub/`), G-set speed-ups (`gset/`) and hardware tables (`hw_table2/`). |
| `research/v6_schedule_20261006/` | Schedule selection for the board configurations. |
| `research/gset_20261007/` | G-set study with the engine's model. |
| `research/reaim_benchmarks_20261008/` | Max-Cut, graph partitioning and TSP benchmarks in software. |
| `research/optimum_mitigation_20261007/` | Study at the best-known K2000 cut. |
| `data/` | Download and verification of the benchmark instances. |
| `figures/` | Figures shown in the README. |

## Paper results and their code

| Paper | Source |
|---|---|
| Figure 1 (the echo and its removal) | `research/headline_echo_20261009/` (`echo_stats.py`, `plot_headline.py`) |
| Figure 2 (theory and simulation) | `research/dmft_sca_20261004/` (`dmft.py`, `dmft_torch.py`, `plot_theory_vs_sim_v2.py`) |
| Table 1 (machine-checked statements) | `research/formal_verification_20261007/` (`SPEC.md`) |
| Figure 3 (comparison at published settings) | `research/fairness_audit_20261008/k2000_pub/` (`run_pub.py`, `pub_methods.py`, Amendment A6; data and plot in `fig_A6_withTEC/`), with the algorithm folders above |
| Stability predictions for the correction | `research/theory_ideas_20261003/` (`a2.py`, `PROTOCOL_A2.md`) |
| Figure 4 and the engine design | `fpga/v80_sca/src/v6/`, `fpga/v80_sca/DESIGN.md` |
| Tables 2 and 3 (board TTS99, design evolution) | `fpga/v80_sca/` (`RESULTS_HW.md`, `RESULTS_MULTIBIT.md`, `PROTOCOL_HW*.md`, `results/`) |
| Figure 5 (flips per step) | `research/algorithm_compare_20261007/flips_profile_v2c.py` |
| Tables 4 and 5 (Anechoic on FPGA, GPU and ASIC) | `fpga/v80_sca/`, `gpu/onsager_v2_20261007/` (`REPORT.md`), `asic/gf22_engine_v64_1p25_20261007/results/` |
| Table 6 (FPGA resources) | `fpga/v80_sca/RESULTS_HW.md` (final v6.4 section) |
| Figure 6, Table 7 and the ASIC results | `asic/` (RTL, regression, derived totals). The layout figure is [`figures/asic-layout.png`](../figures/asic-layout.png). |
| Table 8 (G-set, measured) | `fpga/v80_sca/RESULTS_MULTIBIT.md` and `PROTOCOL_HW_MB_A3*`, `research/gset_20261007/`, `research/fairness_audit_20261008/gset/` |
| Table 9 (software benchmarks) | `research/reaim_benchmarks_20261008/` (`run_a5*.py`, `analyze_a5.py`, `table8b_a5.md`) |
| Comparison with GbSB at the best-known cut | `research/optimum_mitigation_20261007/` |

## FPGA builds

The V80 builds run from `fpga/v80_sca/scripts/` and need AMD Vivado/Vitis 2025.1, the [AVED](https://github.com/Xilinx/AVED) shell, and the platform-integration and programming scripts of the authors' earlier V80 design, which are not part of this repository. They record the runs behind the paper rather than a one-command build. The final v6 bring-up is `bringup_v64.sh`, and its frozen protocol is `PROTOCOL_HW_V6.md` with its amendments.

## GPU builds

`gpu/onsager_v2_20261007/src/build.sh` builds the kernel and the reference check on a host with CUDA 13.3 and an NVIDIA GH200. `src/run_protocol.sh PHASE` runs the phases of `PROTOCOL.md` in the order V, K, M, P, H, W, and validation (V) must pass first. Set the paths and the GPU identifier for your host.

## RTL regressions

`asic/gf22_engine_v64_1p25_20261007/scripts/questa_rtl_regression.sh` compares the unmodified v6.4b engine with the 1.25 GHz ASIC variant on all vector sets, using Siemens Questa. Set the paths for your environment. The vectors come from `scripts/gen_vectors_x5.cpp` and `orig/gen_vectors.cpp`.

## Proofs

- Statements and results: [`research/formal_verification_20261007/README.md`](../research/formal_verification_20261007/README.md) and `SPEC.md`.
- Rocq: `cd research/formal_verification_20261007/coq && coqc Snowball.v && coqchk -silent -o -R . "" Snowball`
- Lean: `cd research/formal_verification_20261007/SnowballFormal && lake exe cache get && lake build && lake env lean Axioms.lean`

## Release notes

- **Placeholders.** The experiments ran on the authors' servers. For publication, user names, host names, local paths and device identifiers were replaced by placeholders: `/scratch/USER`, `gpu-host`, `fpga-host` and `GPU-xxxxxxxx-…`. Set them for your environment.
- **Hash records.** The SHA-256 records of the frozen protocols and inputs (`*.sha256`, `SHA256SUMS*.txt`) refer to the unredacted originals. The self-test in `research/fairness_audit_20261008/k2000_pub/pub_methods.py` checks the published files.
- **Protocol gates.** The V80 bring-up and run scripts (`fpga/v80_sca/scripts/bringup_*.sh`, `run_hw_v6_a5.sh`) stop unless the frozen protocol files match their records. In this release that check fails, because paths were replaced and some inputs are not included. Regenerate the records for your setup, or remove the check.
- **Removed from this release.** Unreferenced exploratory scripts, an earlier board power run and unused variants of Figure 3 were removed. Superseded benchmark amendments, intermediate GPU and FPGA kernels and their results, and the 1 GHz ASIC variant were removed as well. All of them remain in the Git history. Frozen protocols, hash records and earlier reports are unchanged, so they can name files that are now only in the history.
- **Superseded documents.** Some reports in the study folders were written before the final measurements. Each carries a dated note at the top that gives the final values and their source.
- **Raw data.** Per-trial records, spin states and traces are not included because of their size. The summaries, and the scripts that produced them, are included.
- **ASIC.** The ASIC folders contain the RTL, its regression against the golden model and the derived totals. Synthesis and place-and-route scripts and reports are not included, because they depend on a foundry design kit under a non-disclosure agreement.
- **FPGA platform.** The V80 builds use AMD's AVED shell, together with the platform-integration and programming scripts of the authors' earlier V80 design (`fpga/v80_snowball/`). Neither is part of this repository.
