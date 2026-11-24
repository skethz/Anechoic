set r $::env(GBSB_ROOT)
open_project $r/hls
open_solution solution -flow_target vitis
cosim_design -rtl verilog -trace_level none -argv "$::env(GBSB_GRAPH) $r/gold.bin"
exit
