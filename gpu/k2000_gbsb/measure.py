"""Build and rerun the paired K2000 comparison on one user-selected Hopper GPU."""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess

HERE = Path(__file__).resolve().parent
FIRST = 431100000
WIDTH = 120
STEPS = 21400
GRAPH_SHA256 = 'a3058db6cffdbb632bc46223958cc7f8dce17da22eb2e4bbed6f60f811e6c0e9'

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("graph", type=Path)
    parser.add_argument("output", type=Path, help="new directory for binaries, logs and measurements")
    parser.add_argument("--rounds", type=int, default=1000, help="1 to 1000 per algorithm")
    args = parser.parse_args()
    graph, dest = args.graph.resolve(), args.output.resolve()
    if not 1 <= args.rounds <= 1000:
        parser.error("--rounds must be between 1 and 1000")
    if hashlib.sha256(graph.read_bytes()).hexdigest() != GRAPH_SHA256:
        parser.error("unexpected K2000.bin digest")
    nvcc = os.environ.get("NVCC") or shutil.which("nvcc")
    if not nvcc:
        parser.error("set NVCC or put nvcc on PATH")
    dest.mkdir()
    env = os.environ.copy()
    env["CUBLAS_WORKSPACE_CONFIG"] = ":4096:8"
    for var, subdir in (("CUDA_CACHE_PATH","cuda-cache"),("TMPDIR","tmp")):
        path = dest / subdir
        path.mkdir()
        env[var] = str(path)
    def run(cmd):
        subprocess.run(list(map(str, cmd)), check=True, env=env)
    cuda = HERE / "cuda"
    an, gb = dest / "anechoic", dest / "gbsb"
    run([nvcc,"-std=c++17","-O3","-arch=sm_90","-DSCA_LANES=256",cuda/"anechoic/anneal.cu","-o",an])
    run([nvcc,"-std=c++17","-O3","-arch=sm_90","-Xcompiler=-ffp-contract=off",cuda/"gbsb/wide.cu","-lcublas","-o",gb])
    base = (HERE / "base_schedule.bin").read_bytes()
    if len(base) != 3650*16: raise ValueError("base table length")
    table = dest / "schedule.bin"
    table.write_bytes(b"".join(base[16*j:16*j+16] for j in (t*3649//21399 for t in range(STEPS))))
    for block, start in enumerate(range(0,args.rounds,250)):
        n = min(250,args.rounds-start)
        first = FIRST + start*WIDTH
        # The original wider experiment interleaved other settings. These are the
        # relative orders of the two reported configurations within its four blocks.
        order = ("anechoic", "gbsb") if block in (0,2,3) else ("gbsb", "anechoic")
        for name in order:
            d = dest / f"{name}_b{block}"
            if name == "anechoic":
                run([an,graph,table,STEPS,0,WIDTH,n,first,d])
            else:
                d.mkdir()
                run([gb,graph,first,n,d/"gb",STEPS,.196,1.25])

if __name__ == "__main__":
    main()
