#!/usr/bin/env python3
"""Regenerate the O1 ablation table from simulation logs and routed utilization reports."""
import argparse
import hashlib
import re
from pathlib import Path
from statistics import mean

ROOT = Path(__file__).resolve().parent
DESIGNS = {
    "stream": "Eight extractors and four copies with overlapping updates (reference)",
    "cap4": "Four row grants, eight extractors and four copies",
    "matched4": "Four extractors and two copies per bank",
    "barrier": "Wait for all eight decision groups",
    "wide": "Wide lane comparator",
    "brammux": "BRAM address mux after registers",
    "skid": "Direct AXI input",
    "fanout": "Default broadcast fanout constraints",
    "rngdecode": "RNG-enable decoding after registers",
    "score": "Earlier score tree",
}
RESOURCES = ("CLB LUTs", "Registers", "Block RAM Tile", "URAM", "DSP Slices")
TRIALS = 16
STEPS = 280
WORDS = (32 + 2 + STEPS) * TRIALS


def require(condition, message):
    if not condition:
        raise ValueError(message)


def verify_files():
    manifest = ROOT / "SHA256SUMS"
    for line in manifest.read_text().splitlines():
        digest, name = line.split("  ", 1)
        file = ROOT / name
        require(hashlib.sha256(file.read_bytes()).hexdigest() == digest, f"Digest mismatch: {name}")


def cycles(path):
    log = path.read_text()
    require(f"DONE: {WORDS} words, 0 errors" in log, f"Incomplete output check: {path}")
    require(not any(x in log for x in ("MISMATCH", "TIMEOUT", "FATAL")), f"Simulator failure: {path}")
    edges = re.findall(r"^trial (start|out): cycle (\d+)$", log, re.M)
    require([e for e, _ in edges] == ["start", "out"] * TRIALS, f"Invalid trial boundaries: {path}")
    counts = [int(edges[i+1][1]) - int(edges[i][1]) for i in range(0, len(edges), 2)]
    require(min(counts) > 0, f"Invalid cycle count: {path}")
    return counts


def check_inputs():
    inputs = ROOT / "inputs"
    beats, words = map(int, (inputs / "counts.txt").read_text().split())
    stimulus = (inputs / "stim.hex").read_text().splitlines()
    expected = [int(x, 16) for x in (inputs / "expect.hex").read_text().splitlines()]
    require(len(stimulus) == beats == 33050 and len(expected) == words == WORDS, "Input or output length")
    logs = (ROOT / "logs/reference.log").read_text()
    trials = re.findall(r"trial (\d+): cut (\d+) flips (\d+)", logs)
    require(len(trials) == TRIALS, "Reference trial count")
    for index, (seed, cut, flips) in enumerate(trials):
        offset = index * (STEPS + 34)
        require(int(seed) == 42700000 + index, "Reference trial IDs")
        require(expected[offset+32:offset+34] == [int(cut), int(flips)], "Reference cut or flips")


def resources(directory):
    util = (directory / "util_final.rpt").read_text()
    require("Physopt postRoute" in util and "xcv80-lsva4737-2MHP-e-S" in util, f"Unexpected implementation: {directory}")
    route = (directory / "route_final.rpt").read_text()
    def nets(name):
        match = re.search(re.escape("# of " + name) + r"\.*\s*:\s*(\d+)", route)
        require(match is not None, f"Missing routing status: {name}")
        return int(match.group(1))
    require(nets("nets with routing errors") == 0 and nets("routable nets") == nets("fully routed nets") > 0,
            f"Incomplete routing: {directory}")
    counts = []
    for name in RESOURCES:
        match = re.search(r"^\|\s*" + re.escape(name) + r"\s*\|\s*(\d+)\s*\|", util, re.M)
        require(match is not None, f"Missing utilization: {directory}/{name}")
        counts.append(int(match.group(1)))
    return counts


def render(rtl, routed):
    samples = {key: cycles(rtl / (key + ".log")) for key in DESIGNS}
    for monitor, design in (("cap8", "stream"), ("cap8_barrier", "barrier")):
        require(cycles(rtl / (monitor + ".log")) == samples[design], f"Monitor mismatch: {design}")
    avg = {key: mean(values) for key, values in samples.items()}
    area = {key: resources(routed / key) for key in DESIGNS if key != "cap4"}
    lines = [
        "# Single-core RTL ablations on K2000",
        "",
        "Mean cycles from SEED entry to OUT entry over the same 16 echo-corrected O1 starts. "
        "Resource counts come from final out-of-context V80 routes at a 250 MHz target. "
        "The four-grant control holds all eight queues and four dual-port copies per bank fixed in simulation.",
        "",
        "| Design | Mean cycles/anneal | LUTs | FFs | BRAM tiles | URAMs | DSPs |",
        "|---|---:|---:|---:|---:|---:|---:|",
    ]
    for key, label in DESIGNS.items():
        values = [f"{x:,}" for x in area[key]] if key in area else ["—"] * len(RESOURCES)
        lines.append(f"| {label} | {avg[key]:,.2f} | " + " | ".join(values) + " |")
    lines += [
        "",
        "Each reduction uses the control mean as its denominator. Resource differences are the reference count minus the control count.",
        "",
        "| Change from control to reference | Cycle reduction | ΔLUTs | ΔFFs | ΔBRAM tiles | ΔURAMs | ΔDSPs |",
        "|---|---:|---:|---:|---:|---:|---:|",
    ]
    for key, label in (("cap4","Raise only the row-read limit from four to eight per cycle"),
                       ("matched4","Increase extractors from four to eight and copies per bank from two to four"),
                       ("barrier","Start field updates as each group finishes, with eight rows/cycle fixed")):
        reduction = 100 * (1 - avg["stream"] / avg[key])
        if key in area:
            delta = [a-b for a, b in zip(area["stream"], area[key])]
            cells = [f"{x:+,}" if x else "0" for x in delta]
        else:
            cells = ["—"] * len(RESOURCES)
        lines.append(f"| {label} | {reduction:.2f}% | " + " | ".join(cells) + " |")
    lines += ["", "All simulations checked 5,024 output words against the C++ reference. "
              "See the [inputs, logs and reproduction instructions](README.md)."]
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rtl-logs", type=Path, default=ROOT / "logs/rtl")
    parser.add_argument("--route-reports", type=Path, default=ROOT / "logs/route")
    parser.add_argument("--print-table", action="store_true")
    args = parser.parse_args()
    verify_files()
    check_inputs()
    table = render(args.rtl_logs, args.route_reports)
    require(table == (ROOT / "TABLE.md").read_text(), "Regenerated table differs from TABLE.md")
    if args.print_table:
        print(table, end="")
    else:
        print("Verified the 16 reference trials, 12 RTL logs, nine routed resource reports and TABLE.md.")


if __name__ == "__main__":
    main()
