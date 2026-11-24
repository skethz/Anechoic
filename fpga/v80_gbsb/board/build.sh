#!/usr/bin/env bash
# Build the measured 250 MHz GbSB design in a new user-selected directory.
set -euo pipefail
if [[ $# != 2 ]]; then
    echo "Usage: bash build.sh K2000.bin NEW_BUILD_DIRECTORY" >&2
    exit 2
fi
: "${AVED_ROOT:?set AVED_ROOT to Xilinx AVED commit 839b4ad6a75433ab6a43f9f95790a61c2b85bb16}"
: "${XILINX_VITIS:?source Vitis 2025.1 settings64.sh}"
: "${XILINX_VIVADO:?source Vivado 2025.1 settings64.sh}"
pkg=$(cd "$(dirname "$0")/.." && pwd)
export AVED_ROOT=$(realpath "$AVED_ROOT")
graph=$(realpath "$1")
mkdir "$2"
export TASK_ROOT=$(cd "$2" && pwd)
export GBSB_ROOT="$TASK_ROOT/hls_source" GBSB_GRAPH="$TASK_ROOT/data/K2000.bin"
export NUM_ENGINES=1 SCA_VARIANT=gbsb KERNEL_MHZ=250 BOARD_TAG=gbsb250 POST_ROUTE_OPT=1
export SNOWBALL_IP_REPO="$TASK_ROOT/build/instrumented" INTEGRATE_TCL="$TASK_ROOT/scripts/integrate_kernel.tcl"
export AMC_BUILD_ROOT="$TASK_ROOT/build/amc" FIRMWARE_STATUS_FILE=results/firmware_exit_status
export XILINX_LOCAL_USER_DATA=no TMPDIR="$TASK_ROOT/tmp" TMP="$TASK_ROOT/tmp" TEMP="$TASK_ROOT/tmp"
export XDG_CACHE_HOME="$TASK_ROOT/cache" XDG_STATE_HOME="$TASK_ROOT/state" XDG_CONFIG_HOME="$TASK_ROOT/config"
export PYTHONDONTWRITEBYTECODE=1
unset INCREMENTAL_DCP PBLOCK_XDC
cd "$TASK_ROOT"
mkdir -p "$GBSB_ROOT" build data results scripts logs tmp cache state config
cp "$pkg"/src/{gbsb_kernel.cpp,testbench.cpp,build.tcl,cosim.tcl,gold.bin} "$GBSB_ROOT/"
cp "$pkg"/board/{*.tcl,*.py,build_firmware.sh,package_image.sh} scripts/
test -s "$AVED_ROOT/hw/amd_v80_gen5x8_25.1/src/iprepo/smbus_v1_1/component.xml"
test -s "${AMI_LIB:-/usr/local/lib/libami.a}"
cp "$graph" "$GBSB_GRAPH"
echo "a3058db6cffdbb632bc46223958cc7f8dce17da22eb2e4bbed6f60f811e6c0e9  data/K2000.bin" | sha256sum -c -
ulimit -s unlimited
(
    cd "$GBSB_ROOT"
    "$XILINX_VITIS/bin/vitis-run" --mode hls --tcl build.tcl > "$TASK_ROOT/logs/hls_gbsb.log" 2>&1
    test -s hls/solution/impl/ip/component.xml
    grep -Fq 'CSim done with 0 errors' "$TASK_ROOT/logs/hls_gbsb.log"
    echo 0 > "$TASK_ROOT/results/hls_gbsb_exit_status"
    "$XILINX_VITIS/bin/vitis-run" --mode hls --tcl cosim.tcl > "$TASK_ROOT/logs/cosim_gbsb.log" 2>&1
    grep -Fq '*** C/RTL co-simulation finished: PASS ***' "$TASK_ROOT/logs/cosim_gbsb.log"
    echo 0 > "$TASK_ROOT/results/cosim_gbsb_exit_status"
)
ln -s "$GBSB_ROOT/hls" build/hls_sca_gbsb
python3 scripts/prepare_ip.py
driver=$(find "$GBSB_ROOT/hls/solution/impl/misc/drivers" -name xsca_v80_hw.h -print -quit)
test -s "$driver"
g++ -std=c++17 -O3 -mpopcnt -DSCA_LANES=256 -include build/sca_timer_offsets_gbsb.h \
    -I"$(dirname "$driver")" -I"$pkg/../v80_sca/k2000_paired/source" \
    -I"$AVED_ROOT/sw/AMI/api/include" "$pkg/src/host_gbsb.cpp" \
    "${AMI_LIB:-/usr/local/lib/libami.a}" -pthread -o build/host_sca_gbsb
"$XILINX_VIVADO/bin/vivado" -mode batch -source scripts/build_board.tcl -log logs/build.log -journal logs/build.jou
test -s "build/$BOARD_TAG/prj.runs/impl_1/top_wrapper.pdi"
echo 0 > "results/${BOARD_TAG}_exit_status"
bash scripts/build_firmware.sh
echo 0 > "$FIRMWARE_STATUS_FILE"
bash scripts/package_image.sh
test -s "build/$BOARD_TAG/image_manifest.json"
