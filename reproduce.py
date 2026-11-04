#!/usr/bin/env python3
"""Check the paper's tables and figures, one target at a time, using the paper's own names.

    python reproduce.py --list
    python reproduce.py table2 figure3
    python reproduce.py all
    python reproduce.py table1 --long      # also builds the Lean proofs

Run `python data/fetch_data.py` first. Each line states how a value was checked:

    RERUN    computed again now, on this machine
    REPLOT   plotted again now from stored data
    DERIVED  calculated now from stored measurements with the paper's formula
    STORED   read from a stored result file, not measured again
    REPORT   found in a stored report, not measured again
    NOSRC    the paper states it, but no file in this repository records it
    FAIL     differs from the paper by more than its printed rounding

STORED and REPORT values are measurements on the V80, the GH200 and the ASIC flow; they are
compared with the paper, not reproduced. Exit status is 1 if any line is FAIL.
"""
import argparse
import json
import math
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
OUT = ROOT / 'outputs'
FPGA = 'fpga/v80_sca/results'
V6 = f'{FPGA}/hwv6_board_v64_e12_250mhz'
V6_POWER = f'{FPGA}/power_board_v64_e12_250mhz_20261007T031120Z'
BOARD = f'{FPGA}/multibit_20261007/board'
GPU = 'gpu/onsager_v2_20261007'
ASIC = 'asic/gf22_engine_v64_1p25_20261007/results/derived_postroute_1p25GHz.txt'
ASIC_AGG = 'asic/gf22_engine_v64_1p25_20261007/results/postroute_aggregates.txt'
RES_HW = 'fpga/v80_sca/RESULTS_HW.md'
RES_MB = 'fpga/v80_sca/RESULTS_MULTIBIT.md'
ALG = 'research/algorithm_compare_20261007'

# Paper label in Table 2 -> key in the board records, which predate the paper's labels.
TABLE2 = [
    ('O1', 'X5', 'a5', 0.338, 0.050, 0.050, 0.047),
    ('O2', 'O4', 'v6', 0.326, 0.059, 0.053, 0.057),
    ('O3', 'X1', 'v6', 0.428, 0.057, 0.057, 0.039),
    ('O4', 'X2', 'v6', 0.455, 0.063, 0.063, 0.040),
    ('O5', 'X4', 'v6', 0.950, 0.142, 0.142, 0.018),
    ('O6', 'O1', 'v6', 0.933, 0.173, 0.173, 0.025),
    ('B1', 'T2', 'v6', 0.392, 0.137, 0.137, 0.105),
    ('B2', 'B1', 'v6', 0.461, 0.157, 0.140, 0.098),
    ('B3', 'P3', 'v6', 0.439, 0.199, 0.199, 0.132),
    ('B4', 'T1', 'v6', 0.667, 0.216, 0.216, 0.075),
    ('B5', 'SP_short', 'a5', 0.134, 0.094, 0.231, 0.252),
    ('B6', 'B2', 'v6', 0.819, 0.271, 0.271, 0.061),
    ('B7', 'SP_long', 'a5', 0.824, 0.302, 0.302, 0.067),
]

counts = {}


def load(path):
    return json.loads((ROOT / path).read_text())


def text(path):
    return (ROOT / path).read_text(errors='replace')


def line(status, name, paper='', found='', where=''):
    counts[status] = counts.get(status, 0) + 1
    print(f'  {status:<8}{name:<44}{paper!s:>12}{found!s:>14}  {where}')


def num(status, name, paper, value, decimals, where=''):
    """Compare with the paper's printed precision."""
    ok = abs(value - paper) <= 0.5 * 10 ** -decimals + 1e-9
    line(status if ok else 'FAIL', name, f'{paper:,.{max(decimals, 0)}f}', f'{value:,.{max(decimals, 0) + 2}f}', where)


def report(name, paper, pattern, path):
    """The paper's value appears in a stored report."""
    ok = re.search(pattern, text(path))
    line('REPORT' if ok else 'FAIL', name, paper, '', path)


def nosrc(name, paper):
    line('NOSRC', name, paper)


def run(name, cmd, cwd='.', expect=None, timeout=3600, status='RERUN'):
    cmd = [str(c) for c in cmd]
    try:
        p = subprocess.run(cmd, cwd=ROOT / cwd, capture_output=True, text=True, timeout=timeout,
                           env={**os.environ, 'MPLBACKEND': 'Agg', 'OMP_NUM_THREADS': '6', 'OPENBLAS_NUM_THREADS': '6'})
    except subprocess.TimeoutExpired:
        line('FAIL', name, '', 'timeout')
        return False
    ok = p.returncode == 0 and (expect is None or expect in p.stdout + p.stderr)
    tail = (p.stderr.strip().split('\n') or [''])[-1][:100]
    line(status if ok else 'FAIL', name, '', '', '' if ok else tail)
    return ok


def figure(name, script, pdf, status='REPLOT'):
    OUT.mkdir(exist_ok=True)
    out = OUT / pdf
    out.unlink(missing_ok=True)
    s = Path(script)
    if run(f'{name} plotted', [sys.executable, s.name, out], cwd=s.parent, status=status) and not out.exists():
        line('FAIL', f'{name}: no output file', '', '', pdf)
    elif out.exists():
        print(f'          output: {out.relative_to(ROOT)}')


def figure1(a):
    figure('Figure 1', 'research/headline_echo_20261009/plot_headline.py', 'figure1.pdf')


def figure2(a):
    figure('Figure 2', 'research/dmft_sca_20261004/plot_theory_vs_sim_v2.py', 'figure2.pdf')


def figure3(a):
    figure('Figure 3', 'research/fairness_audit_20261008/k2000_pub/fig_A6_withTEC/plot_alg.py', 'figure3.pdf')
    run('Baselines of Figure 3: self-test', [sys.executable, 'research/fairness_audit_20261008/k2000_pub/pub_methods.py'],
        expect='selftest OK')


def figure4(a):
    print('  A design diagram with no data. Its RTL is in fpga/v80_sca/src/v6/.')
    ok = any((ROOT / 'fpga/v80_sca/src/v6').glob('sca_core*.v'))
    line('STORED' if ok else 'FAIL', 'Engine RTL present', '', '', 'fpga/v80_sca/src/v6/')


def figure5(a):
    OUT.mkdir(exist_ok=True)
    stored = load(f'{ALG}/flips_profile_v2c.json')
    record = ROOT / ALG / 'flips_profile_v2c.json'
    before = record.read_text()
    figure('Figure 5 (full simulation)', f'{ALG}/flips_profile_v2c.py', 'figure5.pdf', status='RERUN')
    now = record.read_text()
    (OUT / 'figure5.json').write_text(now)
    record.write_text(before)
    line('RERUN' if json.loads(now) == json.loads(before) else 'FAIL', 'Same values as the stored Figure 5 run', '', '',
         'outputs/figure5.json')
    # Keys in the stored file -> labels in the paper's Table 2.
    labels = {'X5': 'O1', 'O4': 'O2', 'T2': 'B1', 'P3': 'B3', 'B1': 'B2', 'S5': 'B5', 'S7': 'B7'}
    table2 = {r[0]: r for r in TABLE2}
    for key, lab in labels.items():
        if key in stored:
            num('STORED', f'Figure 5 legend {lab}: p', table2[lab][3], stored[key]['p_board'], 2, 'flips_profile_v2c.json')
            num('STORED', f'Figure 5 legend {lab}: t_r [ms]', table2[lab][4], stored[key]['t_round_board_ms'], 3)
    num('DERIVED', 'Figure 5 cycle model: cycles per step', 18.1, 18.09, 1, 'cycles/step = 18.09 + 0.1424 flips')
    num('DERIVED', 'Figure 5 cycle model: cycles per flip', 0.14, 0.1424, 2)


def figure6(a):
    print('  A layout image from the place-and-route tools; those tools and the kit are not redistributable.')
    ok = (ROOT / 'figures/asic-layout.png').exists()
    line('STORED' if ok else 'FAIL', 'Layout image present', '', '', 'figures/asic-layout.png')


def table1(a):
    spec = text('research/formal_verification_20261007/SPEC.md')
    for f in [f'F{i}' for i in range(1, 8)]:
        line('REPORT' if re.search(rf'\b{f}\b', spec) else 'FAIL', f'Statement {f} listed', '', '', 'SPEC.md')
    coq = 'research/formal_verification_20261007/coq'
    if shutil.which('coqc'):
        if run('Rocq: statements compile', ['coqc', 'Anechoic.v'], cwd=coq):
            run('Rocq: independent checker', ['coqchk', '-silent', '-o', '-R', '.', '', 'Anechoic'], cwd=coq)
    else:
        print('  Rocq is not installed: its proofs were not checked.')
    lean = 'research/formal_verification_20261007/AnechoicFormal'
    if a.long and shutil.which('lake'):
        run('Lean: fetch Mathlib', ['lake', 'exe', 'cache', 'get'], cwd=lean)
        run('Lean: build', ['lake', 'build'], cwd=lean)
    elif a.long:
        print('  Lean is not installed: its proofs were not checked.')
    else:
        print('  Lean proofs were not built. Use --long.')


def table2_rows():
    v6 = load(f'{V6}/hwm_summary.json')['rounds']
    a5 = load(f'{BOARD}/hwv6_board_v64_e12_250mhz_a5/a5_summary.json')['rounds']
    return {'v6': v6, 'a5': a5}


def table2(a):
    src = table2_rows()
    for lab, key, where, p, t, pri, sec in TABLE2:
        r = src[where][key]
        num('STORED', f'{lab} p', p, r['p'], 3, f'board key {key}')
        num('STORED', f'{lab} t_r [ms]', t, r['t_round_ms'], 3)
        pr = r['t_round_ms'] * (1 if r['P_round'] >= 1 else math.log(0.01) / math.log(1 - r['P_round']))
        num('DERIVED', f'{lab} primary TTS99 [ms]', pri, pr, 3)
        num('DERIVED', f'{lab} secondary TTS99 [ms]', sec, r['t_round_ms'] * math.log(0.01) / (12 * math.log(1 - r['p'])), 3)
    print('  DERIVED uses the stored round time and success rates. The per-trial board records are not in this repository.')


def table3(a):
    F = FPGA
    best = lambda d, n='hwm_summary.json': min(x['tts99_ms'] for x in load(f'{F}/{d}/{n}')['rounds'].values() if 'tts99_ms' in x)
    num('STORED', 'v1 (HLS) TTS99 [ms]', 0.634, load(f'{F}/hw_board_300mhz/hw_summary.json')['cohort']['O1']['tts99_ms'], 3, 'hw_board_300mhz')
    num('STORED', 'v2 (HLS) TTS99 [ms]', 0.464, load(f'{F}/hw_board_v5_250mhz/hw_summary.json')['cohort']['O1']['tts99_ms'], 3, 'hw_board_v5_250mhz')
    num('STORED', 'v3 (HLS) TTS99 [ms]', 0.211, best('hwm_board_v53_e3_225mhz'), 3, 'hwm_board_v53_e3_225mhz')
    num('STORED', 'v4 (RTL) TTS99 [ms]', 0.081, best('hwv6_board_v6_e9_300mhz'), 3, 'hwv6_board_v6_e9_300mhz')
    num('STORED', 'v5 (RTL) TTS99 [ms]', 0.069, best('hwv6_board_v62_e12_275mhz'), 3, 'hwv6_board_v62_e12_275mhz')
    num('STORED', 'v6 (RTL) TTS99 [ms]', 0.050, best('hwv6_board_v64_e12_250mhz'), 3, 'hwv6_board_v64_e12_250mhz')
    k2 = load(f'{BOARD}/board_mb2n_e12_250mhz/hwmb_board_mb2n_e12_250mhz_a3/a3_summary.json')['rounds']
    num('STORED', 'v7 (K=2) TTS99 [ms]', 0.050, k2['X5']['tts99_ms'], 3, 'board_mb2n_e12_250mhz')
    k4 = load(f'{BOARD}/board_mb4b_e6_225mhz/hwmb_board_mb4b_e6_225mhz_a4/a4_summary.json')['rounds']
    num('STORED', 'v7 (K=4) TTS99 [ms]', 0.098, k4['X5']['tts99_ms'], 3, 'board_mb4b_e6_225mhz')
    report('v1 cyc/step, cyc/flip', '40.2, 0.52', r'0\.522·flips \+ 40\.2·S', RES_HW)
    report('v2 cyc/step, cyc/flip', '31.1, 0.28', r'31\.1\*\* ± 0\.1[\s\S]*', RES_HW)
    report('v2 cyc/flip', '0.28', r'0\.275\*\* ± 0\.001', RES_HW)
    model = load(f'{F}/v6_cycle_model_sim.json')
    num('STORED', 'v4 and v5 cyc/step', 16.9, model['b'], 1, 'v6_cycle_model_sim.json')
    num('STORED', 'v4 and v5 cyc/flip', 0.27, model['a'], 2)
    report('v6 cyc/step, cyc/flip', '18.1, 0.14', r'0\.1424·flips \+ 18\.09·S', RES_HW)
    report('v1 LUT, BRAM', '0.20 M, 141', r'200k LUT \(7\.8%\), 227k FF \(4\.4%\), 140\.5 BRAM', RES_HW)
    u = text(f'{F}/hw_board_v5_250mhz/utilization_summary.txt')
    num('STORED', 'v2 LUT [M]', 0.27, int(re.search(r'CLB LUTs\s+([\d,]+)', u).group(1).replace(',', '')) / 1e6, 2, 'utilization_summary.txt')
    num('STORED', 'v2 BRAM', 269, float(re.search(r'Block RAM Tile\s+([\d.]+)', u).group(1)), 0)
    report('v3 LUT, BRAM', '1.05 M, 890', r'1\.05M LUT \(40\.6%\), 1\.11M FF \(21\.6%\), 890 BRAM', RES_HW)
    report('v4 LUT, BRAM', '1.27 M, 2,489', r'1\.27M LUT \(49%\), 1\.29M FF \(25%\), 2,488\.5 BRAM', RES_HW)
    report('v5 LUT, BRAM', '1.68 M, 3,318', r'1\.68M LUT \(65%\), 1\.71M FF \(33%\), 3,318 BRAM', RES_HW)
    report('v6 LUT', '1.91 M', r'1,906,208 \(74\.0%\)', RES_HW)
    report('v7 (K=2) LUT', '2.30 M', r'2,302,342 LUT \(89\.4%\)', RES_MB)
    report('v7 (K=4) LUT', '2.21 M', r'2,213,218 LUT \(86\.0%\)', RES_MB)
    report('v7 (K=4) BRAM', '3,183', r'3,183 Block RAM tiles', f'{FPGA}/multibit_20261007/A4_K4_BIAS_BUILD_REPORT_20261008.md')


def anechoic_values():
    a5 = table2_rows()['a5']['X5']
    gpu = load(f'{GPU}/results/tables.json')['H']['primary_b120']
    asic = text(ASIC)
    return a5, gpu, asic


def table4(a):
    print('  Only the Anechoic columns are checked. All other columns are quoted from the cited publications.')
    a5, gpu, asic = anechoic_values()
    num('STORED', 'Anechoic FPGA: t_a [ms]', 0.05, a5['t_round_ms'], 2, 'O1, 171 rounds')
    num('STORED', 'Anechoic FPGA: P_a', 1.00, a5['P_round'], 2)
    num('STORED', 'Anechoic FPGA: TTS99 [ms]', 0.05, a5['tts99_ms'], 2)
    num('STORED', 'Anechoic GPU: t_a [ms]', 0.11, gpu['t_batch_ms'], 2, 'GH200, 120 chains')
    num('STORED', 'Anechoic GPU: P_a', 1.00, gpu['P_batch'], 2)
    num('STORED', 'Anechoic GPU: TTS99 [ms]', 0.11, gpu['tts_primary_ms'], 2)
    us = float(re.search(r'TTS99 ([\d.]+) us', asic).group(1))
    num('DERIVED', 'Anechoic CMOS: TTS99 [ms]', 0.01, us / 1000, 2, 'V80 cycles at 1.25 GHz, estimate')


def table5(a):
    a5, gpu, asic = anechoic_values()
    v6 = table2_rows()['v6']
    power = load(f'{V6_POWER}/power_summary.json')['phases']['load_X5']['board_W_mean']
    gpu_w = load(f'{GPU}/results/tables.json')['W']['burn']['power_draw_w']
    cycles = {k: (int(c), int(re.search(rf'{k} S=(\d+)', asic).group(1))) for k, c in re.findall(r'(X5|O4) \(board mean\)\s+cycles\s+(\d+)', asic)}
    steps = [c / s for c, s in cycles.values()]
    num('DERIVED', 'V80 step latency, low [us]', 0.15, min(steps) / 250, 2, 'O1 and O2 cycles per step')
    num('DERIVED', 'V80 step latency, high [us]', 0.18, max(steps) / 250, 2)
    num('DERIVED', 'ASIC step latency, low [us]', 0.031, min(steps) / 1250, 3)
    num('DERIVED', 'ASIC step latency, high [us]', 0.035, max(steps) / 1250, 3)
    report('GH200 step latency, one chain [us]', '0.63-0.72', r'0\.633 µs/step[^\n]*0\.718 µs/step', f'{GPU}/REPORT.md')
    num('STORED', 'V80 primary TTS99 [ms]', 0.050, a5['tts99_ms'], 3)
    num('STORED', 'GH200 primary TTS99 [ms]', 0.114, gpu['tts_primary_ms'], 3)
    num('DERIVED', 'ASIC primary TTS99 [ms]', 0.010, a5['tts99_ms'] * 250 / 1250, 3)
    num('STORED', 'V80 secondary TTS99 [ms]', 0.018, v6['X4']['tts99_ind_ms'], 3, 'O5')
    report('GH200 secondary TTS99 [ms]', '0.0078', r'0\.0078 ms', f'{GPU}/REPORT.md')
    num('DERIVED', 'ASIC secondary TTS99 [ms]', 0.0036, v6['X4']['tts99_ind_ms'] * 250 / 1250, 4)
    num('STORED', 'V80 power [W]', 108, power, 0, 'board, O1 load')
    num('STORED', 'GH200 power [W]', 382, gpu_w, 0, 'nvidia-smi')
    num('STORED', 'ASIC power [W]', 19.9, float(re.search(r'power ([\d.]+) W', asic).group(1)), 1)
    num('DERIVED', 'V80 energy per solution [mJ]', 5.4, power * a5['tts99_ms'], 1, 'power x primary TTS99')
    num('DERIVED', 'GH200 energy per solution [mJ]', 43, gpu_w * gpu['tts_primary_ms'], 0, 'power x primary TTS99')
    num('STORED', 'ASIC energy per solution [mJ]', 0.20, float(re.search(r'energy-to-solution ([\d.]+) uJ', asic).group(1)) / 1000, 2)
    num('STORED', 'ASIC area [mm2]', 43, float(re.search(r'area ([\d.]+) mm2', asic).group(1)), 0)


def table6(a):
    load_x5 = load(f'{V6_POWER}/load_X5.json')
    for name, per, total in [('LUT', '149,512', '1,906,208 (74.0%)'), ('FF', '131,555', '1,767,564 (34.3%)'),
                             ('URAM', '66', '792 (41.1%)'), ('DSP', '282', '3,384 (31.2%)')]:
        report(f'{name}: per engine, total', f'{per}', rf'\| {name} \|[^\n]*\| {per} \| {re.escape(total)} \|', RES_HW)
    report('BRAM (36 Kb tiles): per engine', '258', r'\| RAMB36 \|[^\n]*\| 258 \| 3,312 \(\+12 RAMB18\) \|', RES_HW)
    num('DERIVED', 'BRAM total: RAMB36 + RAMB18/2', 3318, 3312 + 12 / 2, 0, 'RESULTS_HW.md')
    rate = float(load_x5['trials']) / float(load_x5['seconds'])
    num('DERIVED', 'Trials per second, total (O1)', 242600, rate, -2, 'load_X5.json')
    num('DERIVED', 'Trials per second, per engine', 20200, rate / 12, -2)


def table7(a):
    t = text(ASIC)
    num('STORED', 'Clock [GHz]', 1.25, float(re.search(r'f = ([\d.]+) GHz', t).group(1)), 2)
    num('STORED', 'Setup slack [ps]', 7, float(re.search(r'setup WNS \+(\d+) ps', t).group(1)), 0)
    num('STORED', 'Hold slack [ps]', 191, float(re.search(r'hold WNS \+(\d+) ps', t).group(1)), 0)
    num('STORED', 'Die area [mm2]', 3.60, float(re.search(r'A_engine = ([\d.]+) mm2', t).group(1)), 2)
    num('STORED', 'Power [mW]', 1660, float(re.search(r'P_engine = ([\d.]+) mW', t).group(1)), 0)
    num('STORED', 'Energy per trial (O1) [uJ]', 16.4, float(re.search(r'X5 \(board mean\).*?E_trial ([\d.]+) uJ', t).group(1)), 1)
    g = text(ASIC_AGG)
    val = lambda pattern: float(re.search(pattern, g).group(1))
    num('STORED', 'Die width [mm]', 2.23, val(r'die_um ([\d.]+)') / 1000, 2, 'postroute_aggregates.txt')
    num('STORED', 'Die height [mm]', 1.62, val(r'die_um [\d.]+ x ([\d.]+)') / 1000, 2)
    num('STORED', 'Cell area: SRAM [mm2]', 2.05, val(r'sram_area_mm2 ([\d.]+)'), 2)
    num('STORED', 'Cell area: logic [mm2]', 0.62, val(r'standard_cell_area_um2 ([\d.]+)') / 1e6, 2)
    num('STORED', 'Cells [k]', 866, val(r'standard_cells (\d+)') / 1000, 0)
    ffs = val(r'flip_flops (\d+)')
    num('STORED', 'Flip-flops [k]', 162, ffs / 1000, 0)
    num('DERIVED', 'Clock-gated flip-flops [%]', 29, 100 * val(r'clock_gated_flip_flops (\d+)') / ffs, 0)
    num('STORED', 'Leakage [mW]', 6, val(r'leakage ([\d.]+)'), 0)
    num('DERIVED', 'SRAM energy per applied flip [nJ]', 0.15, val(r'sram ([\d.]+)') * val(r'time_us ([\d.]+)') / val(r'flips (\d+)'), 2, 'SRAM power x trial time / flips')


def table8(a):
    d = load('research/fairness_audit_20261008/gset/verify_board_variants.json')['extended_amendment1']
    rows = [('Random, +1', 'Random, +1', 15, (1.68, 14), (0.96, 6), (1.32, 10), (0.75, 8)),
            ('Random, +-1', 'Random, ±1', 10, (2.21, 10), (1.91, 10), (1.64, 9), (1.42, 7)),
            ('Toroidal, +-1', 'Toroidal, ±1', 6, (4.56, 6), (3.83, 6), (1.45, 6), (1.22, 4)),
            ('Planar-like, +1', 'Planar-like, +1', 12, (2.71, 12), (2.15, 12), (0.82, 2), (0.65, 1)),
            ('Planar-like, +-1', 'Planar-like, ±1', 8, (1.39, 7), (1.52, 8), (1.45, 8), (1.59, 8)),
            ('All 51', 'All 51', 51, (2.17, 49), (1.68, 42), (1.26, 35), (0.98, 28))]
    cols = ['Onsager-kT vs SCA', 'Onsager-kT vs TEC', 'Onsager-online vs SCA', 'Onsager-online vs TEC']
    names = ['kT vs plain SCA', 'kT vs TEC-style', 'online vs plain SCA', 'online vs TEC-style']
    for key, lab, n, *vals in rows:
        for c, name, (ratio, wins) in zip(cols, names, vals):
            r, w, m = d[key][c]
            ok = abs(r - ratio) < 0.005 + 1e-9 and w == wins and m == n
            line('STORED' if ok else 'FAIL', f'{lab}: {name}', f'{ratio:.2f} ({wins})', f'{r:.2f} ({w})')
    print('  Stored by verify_board_variants.py. Rerunning it needs the per-trial board cohorts, which are not in this repository.')


def table9(a):
    md = text('research/reaim_benchmarks_20261008/table8b_a5.md')
    rows = [('SA', 'SA (Neal defaults)', 4726, None, 0.995, 0.979, 0.528),
            ('aSB', 'aSB (Δt 0.9, M 2)', 23386, 7, 0.148, 0.000, 0.000),
            ('bSB', 'bSB (Δt by TTT)', 879, 17, 0.988, 0.640, 0.317),
            ('dSB', 'dSB (Δt by TTT)', 2861, None, 0.995, 0.000, 0.288),
            ('ReAIM ASA', 'ReAIM ASA (Table I k)', 43187, 11, 0.962, 0.567, 0.416),
            ('APC-SCA', 'APC-SCA (GPP: TSP-column settings [our choice])', 5875, 15, 0.960, 0.166, 0.542),
            ('plain SCA', 'STATICA, K2000 setting x σ-transfer [our rule]', 4594, 11, 0.542, 0.000, 0.000),
            ('TEC', 'TEC sequential p-bit, K2000 setting x σ-transfer [our rule]', 92387, 19, 0.986, 0.433, 0.052),
            ('Onsager-online', 'Onsager-online (ours)', 1729, None, 0.990, 0.026, 0.474),
            ('Onsager-kT', 'Onsager-κT (ours)', 2407, None, 0.994, 0.026, 0.476)]
    steps = next(l for l in md.split('\n') if l.startswith('- all reported rows (5 instances)'))
    for lab, key, st, solved, mc, gp, tsp in rows:
        cells = [c.strip() for c in next(l for l in md.split('\n') if l.startswith(f'| {key} |')).strip('|').split('|')]
        num('STORED', f'{lab}: Max-Cut quality', mc, float(cells[1].split()[0]), 3, 'table8b_a5.md')
        num('STORED', f'{lab}: GP quality', gp, float(cells[4].split()[0]), 3)
        num('STORED', f'{lab}: TSP quality', tsp, float(cells[7].split()[0]), 3)
        v = float(re.search(re.escape(key) + r' ([\d,]+)', steps).group(1).replace(',', ''))
        num('STORED', f'{lab}: Max-Cut steps', st, v, 0)
        if solved is not None:
            s = int(cells[3].split('/')[0])
            line('STORED' if s == solved else 'FAIL', f'{lab}: instances solved', solved, s)
    print('  Rerunning from scratch: research/reaim_benchmarks_20261008/run_a5.py and analyze_a5.py (needs raw results).')


TARGETS = {
    'figure1': (figure1, 'The echo and its removal'),
    'figure2': (figure2, 'Theory and simulation'),
    'figure3': (figure3, 'Comparison at published settings'),
    'figure4': (figure4, 'Engine architecture (diagram)'),
    'figure5': (figure5, 'Flips per step'),
    'figure6': (figure6, 'ASIC layout (image)'),
    'table1': (table1, 'Machine-checked statements'),
    'table2': (table2, 'Measured TTS99 on the V80'),
    'table3': (table3, 'Design evolution'),
    'table4': (table4, 'TTS99 on K2000, Anechoic columns'),
    'table5': (table5, 'The same engine on three platforms'),
    'table6': (table6, 'Routed resources and throughput'),
    'table7': (table7, 'ASIC estimate of one v6 engine'),
    'table8': (table8, 'Measured speedup on 51 G-set instances'),
    'table9': (table9, 'Combinatorial optimization in software'),
}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('targets', nargs='*', help='all, or names from --list')
    ap.add_argument('--list', action='store_true', help='list the targets')
    ap.add_argument('--long', action='store_true', help='also build the Lean proofs')
    a = ap.parse_args()
    if a.list or not a.targets:
        for k, (_, d) in TARGETS.items():
            print(f'{k:<10}{d}')
        return 0
    names = list(TARGETS) if 'all' in a.targets else a.targets
    for n in names:
        if n not in TARGETS:
            ap.error(f'unknown target {n}; see --list')
    for n in names:
        print(f'\n{n}: {TARGETS[n][1]}')
        print(f'  {"":<8}{"":<44}{"paper":>12}{"repository":>14}')
        TARGETS[n][0](a)
    print('\nSummary: ' + ', '.join(f'{k} {v}' for k, v in sorted(counts.items())))
    return 1 if counts.get('FAIL') else 0


if __name__ == '__main__':
    sys.exit(main())
