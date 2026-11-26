# Single-core RTL ablations on K2000

Mean cycles from SEED entry to OUT entry over the same 16 echo-corrected O1 starts. Resource counts come from final out-of-context V80 routes at a 250 MHz target. The four-grant control holds all eight queues and four dual-port copies per bank fixed in simulation.

| Design | Mean cycles/anneal | LUTs | FFs | BRAM tiles | URAMs | DSPs |
|---|---:|---:|---:|---:|---:|---:|
| Eight extractors and four copies with overlapping updates (reference) | 12,195.75 | 148,780 | 132,809 | 258 | 66 | 282 |
| Four row grants, eight extractors and four copies | 17,577.50 | — | — | — | — | — |
| Four extractors and two copies per bank | 18,298.81 | 128,082 | 126,648 | 258 | 2 | 282 |
| Wait for all eight decision groups | 13,468.31 | 148,838 | 132,168 | 258 | 66 | 282 |
| Wide lane comparator | 12,195.75 | 152,162 | 146,983 | 258 | 66 | 282 |
| BRAM address mux after registers | 12,195.75 | 149,056 | 132,325 | 258 | 66 | 282 |
| Direct AXI input | 12,195.75 | 148,899 | 131,275 | 258 | 66 | 282 |
| Default broadcast fanout constraints | 12,195.75 | 146,669 | 116,261 | 258 | 66 | 282 |
| RNG-enable decoding after registers | 12,195.75 | 148,540 | 132,242 | 258 | 66 | 282 |
| Earlier score tree | 12,191.75 | 149,785 | 128,187 | 258 | 66 | 282 |

Each reduction uses the control mean as its denominator. Resource differences are the reference count minus the control count.

| Change from control to reference | Cycle reduction | ΔLUTs | ΔFFs | ΔBRAM tiles | ΔURAMs | ΔDSPs |
|---|---:|---:|---:|---:|---:|---:|
| Raise only the row-read limit from four to eight per cycle | 30.62% | — | — | — | — | — |
| Increase extractors from four to eight and copies per bank from two to four | 33.35% | +20,698 | +6,161 | 0 | +64 | 0 |
| Start field updates as each group finishes, with eight rows/cycle fixed | 9.45% | -58 | +641 | 0 | 0 | 0 |

All simulations checked 5,024 output words against the C++ reference. See the [inputs, logs and reproduction instructions](README.md).
