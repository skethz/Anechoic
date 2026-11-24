set r $::env(GBSB_ROOT)
open_project $r/hls
set_top sca_v80
add_files $r/gbsb_kernel.cpp -cflags "-std=c++14 -ffp-contract=off"
add_files -tb $r/testbench.cpp -cflags "-std=c++14 -ffp-contract=off"
open_solution solution -flow_target vitis
set_part xcv80-lsva4737-2MHP-e-S
create_clock -period 4.0 -name default
config_compile -unsafe_math_optimizations=false
config_export -format ip_catalog -rtl verilog
set test_args "$::env(GBSB_GRAPH) $r/gold.bin"
csim_design -clean -argv $test_args
csynth_design
export_design -format ip_catalog -rtl verilog
exit
