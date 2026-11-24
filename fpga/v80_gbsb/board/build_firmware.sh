#!/usr/bin/env bash
set -euo pipefail
: "${XILINX_VITIS:?source the Vitis 2025.1 settings first}"
export PATH="${XILINX_VITIS%/Vitis}/gnu/armr5/lin/gcc-arm-none-eabi/bin:$PATH"
command -v armr5-none-eabi-gcc >/dev/null
export KERNEL_MHZ=${KERNEL_MHZ:-250}
board_tag=${BOARD_TAG:-board_${KERNEL_MHZ}mhz}
[[ "$board_tag" =~ ^[a-zA-Z0-9_]+$ ]]
amc_build_root=${AMC_BUILD_ROOT:-$TASK_ROOT/build/AMC}
xsa="$TASK_ROOT/build/$board_tag/amd_v80_gen5x8_25.1.xsa"
test -s "$xsa"
python3 - "$xsa" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as archive:
    assert archive.testzip() is None, 'Damaged XSA archive'
    assert any(name.endswith('.hwh') for name in archive.namelist()), 'XSA has no hardware handoff'
PY
if [ ! -d "$amc_build_root" ]; then
  cp -a "$AVED_ROOT/fw/AMC" "$amc_build_root"
fi
cd "$amc_build_root"
bash scripts/build.sh \
  -os freertos10_xilinx -profile v80 -xsa "$xsa"
# The upstream script can return zero after a piped build failure; check output.
test -s build/amc.elf
python3 scripts/gen_fpt.py -f scripts/fpt.json
test -s fpt.bin
cp build/amc.elf "$TASK_ROOT/build/$board_tag/amc.elf"
cp fpt.bin "$TASK_ROOT/build/$board_tag/fpt.bin"
