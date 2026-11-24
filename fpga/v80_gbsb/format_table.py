"""Format the measured rows as a four-way comparison with a separate native-width control."""
import argparse
import csv
from pathlib import Path

HERE = Path(__file__).resolve().parent


def render(records):
    rows = {(int(r["steps"]),int(r["cut"]),r["solver"],r["device"],int(r["chains_per_request"]),int(r["requests"])):r for r in records}
    if len(rows) != 48:
        raise ValueError("six complete solver/horizon cohorts are required")
    def value(r):
        hits = f'{int(r["successes"]):,}/{int(r["requests"]):,}'
        return f'{float(r["TTS99_device_ms"]):,.2f} ({hits})' if r["TTS99_device_ms"] else f'— ({hits})'
    lines=["# Anechoic and GbSB on the same V80 and the same GH200","",
           "Each entry gives fractional device TTS₉₉ in milliseconds, followed by successful requests / measured requests. "
           "Every request at width 120 charges all 120 trajectories. V80 executes ten consecutive launches of twelve, "
           "while GH200 processes 120 in one batch. A request succeeds if its best final signed cut reaches the threshold.",""]
    for cut in (33337,33004):
        suffix = "best-known K2000 cut" if cut==33337 else "99% of the best-known K2000 cut, rounded up"
        lines += [f"## Target ≥{cut:,} ({suffix})","",
                "| Steps per chain | Anechoic V80 | Anechoic GH200 | GbSB V80 | GbSB GH200 |","|---:|---:|---:|---:|---:|"]
        for st in (1000,3650,21400):
            vals=[value(rows[st,cut,a,d,120,1000]) for a in ("anechoic","gbsb") for d in ("V80","GH200")]
            lines.append("| "+ " | ".join([f"{st:,}"]+vals)+" |")
        lines.append("")
    long_v = rows[21400,33337,"anechoic","V80",120,1000]
    long_g = rows[21400,33337,"anechoic","GH200",120,1000]
    saturated = ", ".join(f'{float(rows[n,33004,"anechoic","V80",12,10000]["TTS99_device_ms"]):.3f}' for n in (1000,3650,21400))
    sat_gbsb = ", ".join(f'{float(rows[n,33004,"gbsb","V80",12,10000]["TTS99_device_ms"]):,.2f}' for n in (1000,3650,21400))
    lines += [
        f'**Timing boundary.** At 21,400 steps and cut 33,337, Anechoic device TTS₉₉ was {float(long_v["TTS99_device_ms"]):.2f} ms on V80 '
        f'and {float(long_g["TTS99_device_ms"]):.2f} ms on GH200. Elapsed through host return, the ordering reversed to '
        f'{float(long_v["TTS99_host_ms"]):.2f} ms on V80 (all 120 endpoints) and {float(long_g["TTS99_host_ms"]):.2f} ms on GH200 (one winner). '
        'V80 device counters omit staggered engine starts, polling and readback, gaps between launches, and the host reduction of ten winners. '
        'GH200 times the 120-chain winner selection on the device. Charging whole requests at this target gives '
        f'{float(long_v["TTS99_whole_device_ms"]):.2f} ms and {float(long_g["TTS99_whole_device_ms"]):.2f} ms of device time, respectively.',"",
        '**Request width.** All 120-chain requests reached 33,004. GbSB also reached 33,337 on every 21,400-step request. '
        'In these cells fractional TTS₉₉ equals one full request time. At cut 33,004, the native twelve-chain V80 TTS₉₉ values across all 10,000 launches, in step order, '
        f'were {saturated} ms for Anechoic and {sat_gbsb} ms for GbSB, one tenth of the width-120 times. The paired GH200 runs all used width 120.',""]
    rare = rows[1000,33337,"gbsb","GH200",120,1000]
    rare_interval = f'{100*float(rare["success_95_low"]):.3f}% to {100*float(rare["success_95_high"]):.3f}%'
    lines += ["The two algorithms received identical initial spin signs for each chain ID. For each algorithm and schedule, offline comparison of the original captures found that all "
              "120,000 final bitmaps agreed between devices. A dash indicates zero observed successes and an unavailable finite TTS estimate. "
              f'For GbSB at 1,000 steps and cut 33,337, {rare["successes"]}/1,000 successes give an exact 95% request-success interval of {rare_interval}. '
              "At zero successes, the two-sided exact 95% upper confidence limit is 0.368% for 1,000 requests and 0.0369% for 10,000. GbSB’s pump update depends on the selected horizon M through 1/(M−t) from the first step. The three rows therefore evaluate different schedules.","",
              "## Native V80 control at cut ≥33,337","",
              "Each observation below is a single physical twelve-chain launch. The first 1,000 launches form a chronological "
              "subset of the 10,000 launches. Each 120-chain request above contains ten of these launches.","",
              "| Steps per chain | Anechoic, first 1,000 | GbSB, first 1,000 | Anechoic, all 10,000 | GbSB, all 10,000 |",
              "|---:|---:|---:|---:|---:|"]
    for st in (1000,3650,21400):
        vals=[value(rows[st,33337,a,"V80",12,n]) for n in (1000,10000) for a in ("anechoic","gbsb")]
        lines.append("| "+" | ".join([f"{st:,}"]+vals)+" |")
    grouped_ratio=float(rows[21400,33337,"gbsb","V80",120,1000]["TTS99_device_ms"])/float(long_v["TTS99_device_ms"])
    native_ratio=float(rows[21400,33337,"gbsb","V80",12,10000]["TTS99_device_ms"])/float(rows[21400,33337,"anechoic","V80",12,10000]["TTS99_device_ms"])
    lines += ["","Both V80 implementations ran at nominal 250 MHz. At 21,400 steps, the twelve-engine Anechoic image used 74.07% of LUTs "
              "and 88.69% of block RAM tiles. The GbSB image used one matrix core with twelve trajectory lanes, 7.23% of LUTs and "
              "2.04% of block RAM tiles. These percentages include the board shell. At cut 33,337 and 21,400 steps, the GbSB-to-Anechoic V80 TTS₉₉ ratio "
              f'was {grouped_ratio:.1f} at width 120 and {native_ratio:.1f} across all native launches. These ratios describe the two ports at their different resource allocations. '
              "[Routed resources and timing](hardware.json)","",
              "At 3,650 steps, the table uses the GH200 run that alternated the two solvers in successive blocks. In an earlier run on "
              "the same shared GPU, Anechoic produced the same 258 successful requests and 91.89 ms device TTS₉₉, versus 61.11 ms here. "
              "Both runs invoked the same executable path. This spread at 3,650 steps exceeds the V80–GH200 difference at 21,400 steps. "
              "The device ordering at 21,400 steps describes this acquisition. "
              "[Earlier acquisition](../v80_sca/k2000_paired/records/3650/results.json)","",
              "Goto et al. report 9.61 ms TTS₉₉ on their Intel Agilex 7 implementation at cut 33,337, with 989 successes in "
              "1,000 single-trajectory runs. Their 9.61 ms is faster than every cut-33,337 TTS₉₉ measured here. Its request width, datapath and clock differ from these ports. "
              "[GbSB, Table I](https://journals.aps.org/prapplied/pdf/10.1103/2qd9-x6v8#page=5)","",
              "The machine-readable results include mean device and host times, fractional and whole-request device TTS₉₉, "
              "request and chain success counts, exact 95% intervals for request success, and both cut thresholds for the native-width control. "
              "[All results](results.csv) · [Protocol and reproduction](README.md)",""]
    return "\n".join(lines)


if __name__=="__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write",action="store_true")
    args=parser.parse_args()
    with (HERE/"results.csv").open(newline="") as stream:
        report=render(list(csv.DictReader(stream)))
    path=HERE/"TABLE.md"
    if args.write:
        path.write_text(report)
    elif path.read_text()!=report:
        raise SystemExit("TABLE.md differs from the measured CSV")
    else:
        print("TABLE.md matches all 48 measured CSV rows")
