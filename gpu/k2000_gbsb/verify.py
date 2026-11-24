"""Recalculate round success and empirical TTS99, optionally checking every final cut."""
import argparse
import csv
import functools
import gzip
import hashlib
import json
import math
from pathlib import Path
import statistics

HERE = Path(__file__).resolve().parent
ARM_NAMES = ("anechoic","gbsb")
TARGET, WIDTH, FIRST = 33337, 120, 431100000

def summarize(rows, arm):
    hits = sum(int(r[arm+"_winning_cut"]) >= TARGET for r in rows)
    chain_hits = sum(int(r[arm+"_hits33337"]) for r in rows)
    t = statistics.fmean(float(r[arm+"_device_ms"]) for r in rows)
    if hits == 0:
        repeats = math.inf
    elif hits >= .99*len(rows):
        repeats = 1.0
    else:
        repeats = math.log(.01)/math.log1p(-hits/len(rows))
    return hits,chain_hits,t,t*repeats

def make_scorer(path):
    data=path.read_bytes()
    if hashlib.sha256(data).hexdigest()!="a3058db6cffdbb632bc46223958cc7f8dce17da22eb2e4bbed6f60f811e6c0e9":
        raise ValueError("unexpected K2000.bin")
    n=2000
    mask=(1<<n)-1
    couplings=[int.from_bytes(data[12+256*i:12+256*(i+1)],"little") & mask for i in range(n)]
    @functools.lru_cache(maxsize=None)
    def score(part):
        other=mask^part
        negative_j_cut=0
        active=part
        while active:
            bit=active & -active
            negative_j_cut+=(couplings[bit.bit_length()-1] & other).bit_count()
            active-=bit
        return part.bit_count()*other.bit_count()-2*negative_j_cut
    def checked(bits):
        part=int.from_bytes(bits,"little")
        if part>mask: raise ValueError("nonzero padding spins")
        return score(part if not part&1 else part^mask)
    return checked

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--graph",type=Path,help="independently score all 240,000 stored endpoints (Python ≥3.10)")
    args=parser.parse_args()
    records=HERE/"records"
    with (records/"rounds.csv").open(newline="") as f:
        rows=list(csv.DictReader(f))
    if len(rows)!=1000 or any(int(r["round"])!=i or int(r["first_trial"])!=FIRST+WIDTH*i for i,r in enumerate(rows)):
        raise ValueError("invalid paired request IDs")
    published=json.loads((records/"results.json").read_text())["33337"]
    results={}
    for label,group in (("first_500",rows[:500]),("next_500",rows[500:]),("all_1000",rows)):
        for arm in ARM_NAMES:
            hits,chains,t,tts=summarize(group,arm)
            ref=published[label][arm]
            if (hits,chains)!=(ref["round_hits"],ref["trajectory_hits"]) or not math.isclose(t,ref["device_ms"]) or not math.isclose(tts,ref["tts_ms"]):
                raise ValueError((arm,label,"summary differs"))
            print(f"{label:10} {arm:8} {hits}/{len(group)} rounds, {chains}/{len(group)*WIDTH} chains, mean {t:.3f} ms, TTS99 {tts:.3f} ms")
            if label=="all_1000": results[arm]=tts
    print(f"TTS99 ratio GbSB/Anechoic = {results['gbsb']/results['anechoic']:.4f}")
    if args.graph:
        score=make_scorer(args.graph)
        for arm in ARM_NAMES:
            for block in range(4):
                with gzip.open(records/f"{arm}_b{block}.spins.gz","rb") as f:
                    for row in rows[250*block:250*(block+1)]:
                        states=f.read(WIDTH*256)
                        if len(states)!=WIDTH*256: raise ValueError("short endpoint record")
                        cuts=[score(states[k:k+256]) for k in range(0,len(states),256)]
                        if max(cuts)!=int(row[arm+"_winning_cut"]) or sum(c>=TARGET for c in cuts)!=int(row[arm+"_hits33337"]):
                            raise ValueError((arm,row["round"],"cut mismatch"))
                    if f.read(1): raise ValueError("extra endpoints")
            print(f"{arm}: all 120,000 endpoint scores verified against signed graph")
if __name__=="__main__":
    main()
