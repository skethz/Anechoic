write_hw_platform -force -fixed -minimal $build_dir/amd_v80_gen5x8_25.1.xsa
report_ip_status -file $build_dir/ip_status.rpt
puts "SNOWBALL_BOARD_OUTPUTS_GENERATED"
launch_runs synth_1 -jobs 2
wait_on_runs synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {error "Board synthesis failed"}
launch_runs impl_1 -to_step route_design -jobs 2
wait_on_runs impl_1
if {[get_property STATUS [get_runs impl_1]] ne "route_design Complete!"} {error "Board routing failed"}
# Optional (POST_ROUTE_OPT=1, used from v6 on): post-route phys_opt as a run step before the timing gate in
# finalize_board.tcl (Vivado 2025.1: enable the step, then -next_step).
if {[info exists ::env(POST_ROUTE_OPT)] && $::env(POST_ROUTE_OPT)} {
    set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
    set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]
    launch_runs impl_1 -next_step -jobs 2
    wait_on_runs impl_1
    puts "SNOWBALL_POST_ROUTE_STATUS [get_property STATUS [get_runs impl_1]]"
    if {![string match "*Post-Route*Complete*" [get_property STATUS [get_runs impl_1]]]} {error "Post-route phys_opt failed"}
}
source $root/scripts/finalize_board.tcl
