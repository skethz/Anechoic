#!/usr/bin/env python3
"""Rebuild the stored stimulus, replay RTL simulations, or rerun the original Vivado routes."""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess

from verify import DESIGNS, ROOT, cycles, require, resources

ROUTED = [name for name in DESIGNS if name != "cap4"]
MONITORS = {"cap4": (4, 0), "cap8": (8, 0), "cap8_barrier": (8, 1)}


def run(args, directory, logfile=None):
    print(" ".join(map(str, args)), flush=True)
    if logfile is None:
        subprocess.run(args, cwd=directory, check=True)
    else:
        with logfile.open("w") as out:
            subprocess.run(args, cwd=directory, stdout=out, stderr=subprocess.STDOUT, check=True)


def replay_inputs(dest, graph):
    graph = graph.resolve()
    digest = "a3058db6cffdbb632bc46223958cc7f8dce17da22eb2e4bbed6f60f811e6c0e9"
    require(hashlib.sha256(graph.read_bytes()).hexdigest() == digest, "Unexpected K2000.bin")
    src = ROOT / "src/reference"
    executable = dest / "gen_vectors"
    run([os.environ.get("CXX", "c++"), "-O3", "-std=c++17", "-DSCA_LANES=256", "-I", src,
         src / "gen_vectors.cpp", "-o", executable], dest)
    run([executable, graph, dest, "O1", "42700000", "16"], dest, dest / "reference.log")
    for name in ("stim.hex", "counts.txt", "expect.hex"):
        require((dest / name).read_bytes() == (ROOT / "inputs" / name).read_bytes(), name)
    require((dest / "reference.log").read_bytes() == (ROOT / "logs/reference.log").read_bytes(), "reference.log")
    print("All inputs and reference outputs reproduced byte for byte.")


def replay_rtl(dest, names, jobs):
    src = ROOT / "src"
    for file in ("stim.hex", "expect.hex", "counts.txt"):
        shutil.copyfile(ROOT / "inputs" / file, dest / file)
    compiled = set()
    for name in names:
        design = "capped" if name in MONITORS else name
        obj = dest / ("obj_" + design)
        if design not in compiled:
            if design == "capped":
                tb = "tb_capped.v"
            elif design in ("stream", "wide", "barrier"):
                tb = "tb_core.v"
            else:
                tb = "tb_protocol.v"
            run(["verilator", "--binary", "--timing", "-Wno-fatal", "--top-module", "tb", "-j", str(jobs),
                 "--Mdir", obj, src / tb, src / "designs" / design / "sca_core.v"],
                dest, dest / ("build_" + design + ".log"))
            compiled.add(design)
        flags = []
        if name in MONITORS:
            width, barrier = MONITORS[name]
            flags = [f"+WIDTH={width}", f"+BARRIER={barrier}"]
        record = name + ".log"
        run([obj / "Vtb", *flags], dest, dest / record)
        require(cycles(dest / record) == cycles(ROOT / "logs/rtl" / record),
                f"Per-trial cycle mismatch: {name}")
        print(f"Matched all 16 cycle counts and 5,024 output words for {name}.", flush=True)


def replay_routes(dest, names):
    for name in names:
        route = "route_controls.tcl"
        if name in ("stream", "barrier"):
            route = "route.tcl"
        elif name == "matched4":
            route = "route_width.tcl"
        elif name == "wide":
            route = "route_wide.tcl"
        work = dest / name
        work.mkdir()
        shutil.copyfile(ROOT / "src/designs" / name / "sca_core.v", work / "sca_core.v")
        run(["vivado", "-mode", "batch", "-notrace", "-source", ROOT / "scripts" / route,
             "-tclargs", dest, name], work, work / "run.log")
        require(resources(work) == resources(ROOT / "logs/route" / name), f"Routed resource counts differ: {name}")
        print(f"Matched routed utilization for {name}.", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    for mode in ("inputs", "rtl", "route"):
        p = sub.add_parser(mode)
        p.add_argument("output", type=Path, help="new scratch directory")
        if mode == "inputs":
            p.add_argument("graph", type=Path, help="packed benchmark K2000.bin")
        else:
            choices = list(dict.fromkeys([*DESIGNS, *MONITORS])) if mode == "rtl" else ROUTED
            p.add_argument("--design", action="append", choices=choices, help="repeat to select several designs")
            if mode == "rtl":
                p.add_argument("--jobs", type=int, default=4, help="parallel compiler jobs per simulation")
    args = parser.parse_args()
    dest = args.output.resolve()
    dest.mkdir(parents=True, exist_ok=False)
    if args.action == "inputs":
        replay_inputs(dest, args.graph)
    elif args.action == "rtl":
        replay_rtl(dest, args.design or list(dict.fromkeys([*DESIGNS, *MONITORS])), args.jobs)
    else:
        replay_routes(dest, args.design or ROUTED)


if __name__ == "__main__":
    main()
