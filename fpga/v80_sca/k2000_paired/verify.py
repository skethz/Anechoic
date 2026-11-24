"""Verify the V80 timing records and optionally recompute signed K2000 cuts."""
import argparse
import csv
import gzip
import hashlib
import importlib.util
import json
import math
from pathlib import Path
from statistics import fmean

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
TARGET = 33337
FIRST_ID = 431100000


def read_rows(path):
    with gzip.open(path, "rt", newline="") as stream:
        return list(csv.DictReader(stream))


def compare(value, expected, field):
    if not math.isclose(value, expected, rel_tol=2e-10, abs_tol=1e-9):
        raise ValueError(f"{field} differs: {value} versus {expected}")


def check_summary(rows, frequency, published, label):
    hits = sum(cut >= TARGET for cut, _, _ in rows)
    if (hits, len(rows)) != (published["successes"], published["n"]):
        raise ValueError(f"{label}: inconsistent success count")
    device_ms = fmean(cycles for _, cycles, _ in rows) / (1000.0 * frequency)
    host_ms = fmean(time for _, _, time in rows)
    compare(device_ms, published["mean_device_ms"], label + " mean device time")
    compare(host_ms, published["mean_host_ms"], label + " mean host time")
    if hits:
        repeats = 1.0 if hits >= 0.99 * len(rows) else math.log(0.01) / math.log1p(-hits / len(rows))
        compare(device_ms * repeats, published["TTS99_ms"], label + " device TTS99")
        compare(device_ms * math.ceil(repeats), published["integer_TTS99_ms"], label + " whole-round TTS99")
        compare(host_ms * repeats, published["host_TTS99_ms"], label + " host TTS99")
        print(f"{label}: {hits}/{len(rows)}, {device_ms:.5f} ms per request, {device_ms * repeats:.4f} ms TTS99")
    elif published["TTS99_ms"] is not None:
        raise ValueError(f"{label}: finite TTS with zero successes")


def verify(steps, graph):
    data = HERE / "records" / str(steps)
    stats = json.loads((data / "results.json").read_text())
    if stats["target"] != TARGET or stats["steps"] != steps or stats["physical_engines"] != 12:
        raise ValueError("incorrect protocol")
    trials = read_rows(data / "trials.csv.gz")
    waves = read_rows(data / "waves.csv.gz")
    requests = read_rows(data / "requests.csv.gz")
    if (len(trials), len(waves), len(requests)) != (120000, 10000, 1000):
        raise ValueError("unexpected number of trials, physical launches, or requests")
    score = None
    if graph is not None:
        spec = importlib.util.spec_from_file_location("gpu_verifier", ROOT / "gpu/k2000_gbsb/verify.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        score = module.make_scorer(graph)
    hashes = stats["block_endpoint_sha256"]
    if len(hashes) != 4:
        raise ValueError("expected four endpoint blocks")
    for block, expected_hash in enumerate(hashes):
        with gzip.open(data / f"endpoints_b{block}.bin.gz", "rb") as states:
            raw = states.read()
        if len(raw) != 30000 * 256 or hashlib.sha256(raw).hexdigest() != expected_hash:
            raise ValueError(f"corrupt V80 endpoint record in block {block}")
        if steps == 21400:
            gpu_file = ROOT / f"gpu/k2000_gbsb/records/anechoic_b{block}.spins.gz"
            with gzip.open(gpu_file, "rb") as gpu:
                if gpu.read() != raw:
                    raise ValueError(f"V80 and GH200 endpoints differ in block {block}")
        if score is not None:
            for k in range(30000):
                if score(raw[256*k:256*(k+1)]) != int(trials[30000*block+k]["cut"]):
                    raise ValueError(f"score differs for trajectory {FIRST_ID+30000*block+k}")
    lanes = []
    for i, row in enumerate(trials):
        if int(row["trial"]) != FIRST_ID + i or int(row["engine"]) != i % 12 or int(row["cycles"]) <= 0:
            raise ValueError(f"invalid physical trajectory at row {i}")
        lanes.append((int(row["cut"]), int(row["cycles"])))
    if sum(cut >= TARGET for cut, _ in lanes) != stats["trajectory_hits"]:
        raise ValueError("trajectory hit count differs")
    physical = []
    for i, row in enumerate(waves):
        sample = lanes[12*i:12*(i+1)]
        cut = max(x[0] for x in sample)
        cycles = max(x[1] for x in sample)
        observed = tuple(int(row[k]) for k in ("group", "wave", "first_trial", "cut", "cycles"))
        if observed != (i//10, i%10, FIRST_ID+12*i, cut, cycles):
            raise ValueError(f"inconsistent physical wave {i}")
        physical.append((cut, cycles, float(row["host_ms"])))
    groups = []
    for i, row in enumerate(requests):
        sample = physical[10*i:10*(i+1)]
        cut = max(x[0] for x in sample)
        cycles = sum(x[1] for x in sample)
        observed = tuple(int(row[k]) for k in ("group", "first_trial", "cut", "sum_wave_cycles"))
        if observed != (i, FIRST_ID+120*i, cut, cycles):
            raise ValueError(f"inconsistent 120-chain request {i}")
        groups.append((cut, cycles, float(row["host_ms"])))
    for rows, name in ((physical[:1000], "v80_native_12_first1000"), (physical, "v80_native_12_all10000"),
                       (groups, "v80_ten_waves_of_12")):
        check_summary(rows, stats["mhz"], stats[name], f"{steps} steps, {name}")
    if score is not None:
        print(f"{steps} steps: verified 120,000 signed cut values against the graph")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--steps", type=int, choices=(3650, 21400))
    parser.add_argument("--graph", type=Path, help="score every physical endpoint against K2000.bin")
    args = parser.parse_args()
    steps_to_verify = [args.steps] if args.steps else sorted(int(p.name) for p in (HERE / "records").iterdir() if p.is_dir())
    if not steps_to_verify:
        raise ValueError("no measurements found")
    for value in steps_to_verify:
        verify(value, args.graph)
