# Building and running the GbSB V80 implementation

The measured AVED design has one 250 MHz kernel, one shared matrix engine and twelve concurrent trajectories. Each launch starts core 0 and reads its single 64-bit start-to-done counter. The seven opening comment lines in the archived host source describe the predecessor's replicated engines, flags and traces. The measured host uses the positional arguments shown below. Its `main` function implements the launch and timing procedure. The HLS top name `sca_v80` is the existing shell interface name. [Measured host source](../src/host_gbsb.cpp)

## Build

Use Linux, AMD Vitis and Vivado 2025.1, the Xilinx AVED 25.1 design at commit `839b4ad6a75433ab6a43f9f95790a61c2b85bb16`, an AVED checkout with the licensed SMBus 1.1 IP in its board IP repository, and the AMI API library. Supply the vendor toolchain, licenses and IP as required by their distributors. The AVED firmware build also requires its R5 cross toolchain. Set `AMI_LIB` when the library is outside `/usr/local/lib`. [AMD AVED reference](https://github.com/Xilinx/AVED/tree/839b4ad6a75433ab6a43f9f95790a61c2b85bb16)

From the root of this repository, run the following after sourcing both 2025.1 tool environments and setting `AVED_ROOT`. Choose a fresh and sufficiently large build directory. The script runs HLS C simulation and RTL co-simulation, packages the instrumented IP, builds the host, routes the board, checks setup and hold timing and packages the image with management firmware.

```bash
python3 data/fetch_data.py --only k2000
bash fpga/v80_gbsb/board/build.sh data/k2000/K2000.bin /path/to/new-build
```

The shell integration connects three kernel AXI masters to a 256-bit NoC input. The management interface resides at BAR0 offset `0x01100000`. The published host selects PCIe BDF `01:00.0`. For another BDF, change the argument of `ami_dev_find` before building the host. A new place-and-route run can have a different logic UUID and resource report. Use the UUID and clock from that build's `build/gbsb250/image_manifest.json`.

## Measure

Use your board's normal image-programming procedure to load the built image and confirm its logic UUID. The graph transfer and the first unmeasured twelve-trajectory warm-up load the resident couplings. Each measured request then runs ten consecutive launches. Each launch returns all twelve endpoints and a winner. Below, `BUILD` names the completed build directory. A one-request functional check uses `1` in place of `1000`. For the complete experiment, keep the count at 1,000 for all three schedules.

```bash
GRAPH=$(realpath data/k2000/K2000.bin)
SRC=$(realpath fpga/v80_gbsb/src)
UUID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["logic_uuid"])' "$BUILD/build/gbsb250/image_manifest.json")
MHZ=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["clock"]["actual_mhz"])' "$BUILD/build/gbsb250/image_manifest.json")
for steps in 21400 1000 3650; do
    "$BUILD/build/host_sca_gbsb" "$GRAPH" "$UUID" "$MHZ" 431100000 1000 \
        "$BUILD/measured_$steps" "$SRC/first_request_$steps.bin" "$steps"
done
```

Each output directory must be new. It contains the physical counter and host time per launch, the corresponding requests, signed cuts per chain, and all endpoint bits. The host checks every returned cut against the signed graph. It checks the first 120 endpoint bytestrings against a separately acquired GH200 reference. The full-cohort offline comparison covers every endpoint. [Measurement table](../TABLE.md) · [Verification procedure](../README.md)

## Functional check without an FPGA

```bash
c++ -std=c++14 -O2 -ffp-contract=off fpga/v80_gbsb/src/{gbsb_kernel.cpp,testbench.cpp} -o /tmp/gbsb-csim
/tmp/gbsb-csim data/k2000/K2000.bin fpga/v80_gbsb/src/gold.bin
```

This checks all twelve final states, signed cuts and winner outputs at each of four stopping points. The stored vectors are independent reference outputs.
