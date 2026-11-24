"""Rebuild the paired device table from the independently acquired FPGA and GPU logs."""
import argparse
import array
import csv
from functools import lru_cache
import gzip
import hashlib
import io
import json
import math
import os
from pathlib import Path
from statistics import fmean
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
FIRST = 431100000
STEPS = (1000, 3650, 21400)
TARGETS = (33004, 33337)
ARMS = ("anechoic", "gbsb")
EDGE_SHA = "9ed615e5e18726914f12740b7f9bedb6b69676477ed5958fac42c8ab0c252ba7"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read_rows(path, count):
    with gzip.open(path, "rt", newline="") as stream:
        rows = list(csv.DictReader(stream))
    require(len(rows) == count, f"{path} has {len(rows)} rows, expected {count}")
    return rows


def ints(row, fields):
    return tuple(int(row[k]) for k in fields.split())


def positive(value):
    number = float(value)
    require(math.isfinite(number) and number > 0, "invalid recorded duration")
    return number


@lru_cache(maxsize=None)
def lower_success_limit(hits, n):
    """Two-sided 95% Clopper–Pearson lower limit for the request success rate."""
    if hits == 0:
        return 0.0
    if hits == n:
        return 0.025**(1/n)
    log_choose = math.lgamma(n+1) - math.lgamma(hits+1) - math.lgamma(n-hits+1)
    lo, hi = 0.0, hits/n
    for _ in range(52):
        p = (lo+hi)/2
        term = math.exp(log_choose + hits*math.log(p) + (n-hits)*math.log1p(-p))
        tail = term
        for k in range(hits, n):
            term *= (n-k)/(k+1) * (p/(1-p))
            tail += term
            if term < tail*1e-15 or term == 0:
                break
        if tail < 0.025:
            lo = p
        else:
            hi = p
    return (lo+hi)/2


def graph_scorer(edges, work):
    """Read the pinned original signed graph, including both endpoints of every edge."""
    require(hashlib.sha256(edges.read_bytes()).hexdigest() == EDGE_SHA, "canonical .rud digest")
    n = 2000
    weights = bytearray(n*(n-1)//2)
    with edges.open() as stream:
        require(stream.readline().split() == ["2000", "1999000"], "wrong edge-list dimensions")
        for line in stream:
            a, b, w = map(int, line.split())
            a -= 1
            b -= 1
            if a > b:
                a, b = b, a
            require(0 <= a < b < n and w in (-1, 1), "invalid signed edge")
            idx = a*(2*n-a-1)//2 + b-a-1
            require(weights[idx] == 0, "repeated signed edge")
            weights[idx] = w & 255
    require(0 not in weights, "missing edge")
    upper = work / "upper.i8"
    upper.write_bytes(weights)
    binary = work / "signed-cuts"
    subprocess.run([os.environ.get("CXX", "c++"), "-std=c++17", "-O3", "-march=native",
                    str(HERE/"src/score.cpp"), "-o", str(binary)], check=True)
    def score(raw):
        spins, cuts = work/"spins.bin", work/"cuts.i32"
        spins.write_bytes(raw)
        subprocess.run([str(binary),str(upper),str(spins),str(cuts)],
                       check=True, stdout=subprocess.DEVNULL)
        data = cuts.read_bytes()
        require(len(data) == len(raw)//256*4, "incomplete independent score file")
        result = array.array("i")
        require(result.itemsize == 4, "native 32-bit int required")
        result.frombytes(data)
        return result
    return score


def endpoint_block(index, block, score):
    info = index["blocks"][block]
    require(info["first_trial"] == FIRST + 30000*block and info["endpoints"] == 30000, "endpoint IDs")
    raw = gzip.decompress((HERE/info["endpoint_file"]).read_bytes())
    require(len(raw) == info["v80_spin_bytes"] == info["gh200_spin_bytes"] == 30000*256,
            "truncated or oversized endpoint block")
    sha = hashlib.sha256(raw).hexdigest()
    require(sha == info["v80_spin_sha256"] == info["gh200_spin_sha256"], "independent endpoint digests disagree")
    if block == 0:
        checks = json.loads((HERE/"reproduction_checks.json").read_text())
        key = f'{index["steps"]}_{index["algorithm"]}'
        first_request = raw[:120*256]
        require(checks["initial_signs_match"] and
                hashlib.sha256(first_request).hexdigest() == checks["sha256_by_arm_step"][key],
                "fresh GH200 reproduction disagrees with the first request")
        if index["algorithm"] == "gbsb":
            first_path = HERE/"src"/f'first_request_{index["steps"]}.bin'
            require(first_path.read_bytes() == first_request, "FPGA startup reference differs")
    # The 2,048-bit container holds 2,000 active spins. Check all 48 padding bits unconditionally.
    padding = bytes(6)
    require(all(raw[i+250:i+256] == padding for i in range(0,len(raw),256)), "nonzero endpoint padding")
    return score(raw) if score else None


def assess(steps, arm, score=None, *, check_restoration=True):
    local = HERE/"records"/str(steps)/arm
    index = json.loads((local/"index.json").read_text())
    require(index["algorithm"] == arm and index["steps"] == steps and len(index["blocks"]) == 4, "wrong index")
    gpu, fpga = (index["hardware"][k] for k in ("GH200","V80"))
    require(gpu["same_device_id_verified_before_and_after_every_block"], "GPU acquisition identity incomplete")
    if check_restoration:
        require(fpga["restoration_confirmed"], "board restoration incomplete")
    instance = json.loads((HERE/"reproduction_checks.json").read_text())["gh200_instance_token"]
    require(all(b["gh200_before"] == b["gh200_after"] == instance for b in index["blocks"]),
            "GH200 instance token changed before or after an acquisition block")
    require(fpga["trajectory_lanes"] == 12 and fpga["ip_instances"] == (1 if arm == "gbsb" else 12),
            "wrong physical parallelism")
    board = HERE/fpga["physical_records"]
    mhz = positive(fpga["clock_mhz"])
    require(abs(mhz-250) < 0.001,"unexpected clock")
    image = "anechoic_short" if arm == "anechoic" and steps in (1000,3650) else arm
    route = json.loads((HERE/"hardware.json").read_text())[image]
    timing = route["routed_timing"]
    require(steps in route["measured_horizons"] and fpga["pdi_sha256"] == route["pdi_sha256"]
            and fpga["image_logic_uuid"] == route["logic_uuid"] and mhz == route["clock"]["actual_mhz"]
            and min(timing["setup_slack_ns"],timing["hold_slack_ns"]) >= 0,
            "physical data and routed-image records disagree")
    if image == "anechoic_short":
        earlier = HERE/"../v80_sca/k2000_paired/records/3650/results.json"
        require(fpga["pdi_sha256"] == json.loads(earlier.read_text())["programmed_pdi_sha256"],
                "short-schedule PDI differs from the earlier acquisition")
    lanes = read_rows(board/"trials.csv.gz", 120000)
    cuts = []
    gpu_rounds = []
    for block in range(4):
        independent = endpoint_block(index, block, score)
        gt = read_rows(local/f"gh200_trials_b{block}.csv.gz", 30000)
        gr = read_rows(local/f"gh200_requests_b{block}.csv.gz", 250)
        for k, trial in enumerate(gt):
            i = block*30000 + k
            row = lanes[i]
            col = "lane" if arm == "gbsb" else "engine"
            require(ints(row, "trial "+col) == (FIRST+i, i%12), f"FPGA chain ID or lane {i}")
            gpu_id = "trial" if arm == "gbsb" else "trial_id"
            c = int(row["cut"])
            require(ints(trial, gpu_id+" cut") == (FIRST+i,c), f"GPU trial ID or cut {i}")
            if arm == "anechoic":
                require(int(trial["flips"]) == int(row["flips"]) and int(trial["anneal_cut"]) == c,
                        f"Anechoic flips/cut disagree at {i}")
            if independent is not None:
                require(independent[k] == c, f"original signed-edge cut mismatch at {i}")
            cuts.append(c)
        for ridx, row in enumerate(gr):
            i = block*250+ridx
            chunk = cuts[i*120:(i+1)*120]
            best = max(chunk)
            require(ints(row, "round first_id cut winner") == (ridx,FIRST+120*i,best,chunk.index(best)),
                    f"GPU request or selected winner {i}")
            gpu_rounds.append((best, positive(row["device_ms"]), positive(row["host_ms"])))
    waves = []
    ticks = []
    for i, row in enumerate(read_rows(board/"waves.csv.gz",10000)):
        best = max(cuts[i*12:(i+1)*12])
        require(ints(row,"group wave first_trial cut") == (i//10,i%10,FIRST+12*i,best),f"FPGA launch {i}")
        cycles = int(row["cycles"])
        require(cycles > 0, "invalid FPGA counter")
        if arm == "anechoic":
            actual = [int(lane["cycles"]) for lane in lanes[i*12:(i+1)*12]]
            require(min(actual)>0 and max(actual)==cycles, f"maximum of 12 independent counters {i}")
        ticks.append(cycles)
        waves.append((best,cycles/(1000*mhz),positive(row["host_ms"])))
    board_rounds = []
    for i, row in enumerate(read_rows(board/"requests.csv.gz", 1000)):
        best = max(w[0] for w in waves[i*10:(i+1)*10])
        cycles = sum(ticks[i*10:(i+1)*10])
        require(ints(row,"group first_trial cut sum_wave_cycles") == (i,FIRST+120*i,best,cycles),
                f"FPGA request aggregation {i}")
        require(best == gpu_rounds[i][0], f"two devices disagree on request {i}")
        board_rounds.append((best,cycles/(1000*mhz),positive(row["host_ms"])))
    results = []
    for device,width,samples in [("V80",120,board_rounds),("GH200",120,gpu_rounds),
                                  ("V80",12,waves[:1000]),("V80",12,waves)]:
        for target in TARGETS:
            p_hits = sum(c >= target for c,_,_ in samples)
            n = len(samples)
            p = p_hits/n
            mean_d = fmean(x[1] for x in samples)
            mean_h = fmean(x[2] for x in samples)
            repeats = (1.0 if p >= .99 else math.log(.01)/math.log1p(-p)) if p else None
            def ms(value):
                return "" if value is None else f"{value:.9f}"
            results.append(dict(steps=steps,cut=target,solver=arm,device=device,chains_per_request=width,
                requests=n,successes=p_hits,chains=n*width,
                success_95_low=f"{lower_success_limit(p_hits,n):.10f}",
                success_95_high=f"{1-lower_success_limit(n-p_hits,n):.10f}",
                successful_chains=sum(c>=target for c in cuts[:n*width]),
                device_ms=ms(mean_d),TTS99_device_ms=ms(mean_d*repeats if repeats is not None else None),
                TTS99_whole_device_ms=ms(mean_d*math.ceil(repeats) if repeats is not None else None),
                host_ms=ms(mean_h),TTS99_host_ms=ms(mean_h*repeats if repeats is not None else None)))
    return results


def serialize(rows):
    output = io.StringIO(newline="")
    writer=csv.DictWriter(output,fieldnames=list(rows[0]),lineterminator="\n")
    writer.writeheader()
    writer.writerows(rows)
    return output.getvalue()


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("--edges",type=Path,help="independently recompute all cuts from the pinned WK2000_1.rud")
    p.add_argument("--write",action="store_true",help="regenerate the complete machine-readable results in this directory")
    p.add_argument("--measurements-only",action="store_true",
                   help="check recorded computations and timings independently of the board restoration status")
    p.add_argument("--steps",nargs="+",type=int,choices=STEPS,default=STEPS)
    p.add_argument("--solver",nargs="+",choices=ARMS,default=ARMS)
    args=p.parse_args()
    selection=[(s,a) for s in STEPS for a in ARMS if s in args.steps and a in args.solver]
    require(not args.write or len(selection)==6, "publishing a table requires every arm and horizon")
    rows=[]
    with tempfile.TemporaryDirectory() as t:
        score = graph_scorer(args.edges,Path(t)) if args.edges else None
        for s,a in selection:
            rows.extend(assess(s,a,score,check_restoration=not args.measurements_only))
            print(f"{s:5d} steps, {a}: 120,000 paired endpoints and 1,000 request timings per device",flush=True)
    path=HERE/"results.csv"
    if args.write:
        path.write_text(serialize(rows))
    else:
        with path.open(newline="") as stream:
            original=[row for row in csv.DictReader(stream) if (int(row["steps"]),row["solver"]) in selection]
        require(serialize(rows)==serialize(original), "published results.csv differs")
    print(f"{len(rows)} results verified")

if __name__ == "__main__":
    main()
