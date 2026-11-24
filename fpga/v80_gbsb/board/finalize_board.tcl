open_run impl_1
set active [get_cells -hierarchical -filter {NAME =~ *perf_active_reg && IS_SEQUENTIAL == 1}]
set running [get_cells -hierarchical -filter {NAME =~ *perf_counter_reg* && IS_SEQUENTIAL == 1}]
set completed [get_cells -hierarchical -filter {NAME =~ *perf_completed_reg* && IS_SEQUENTIAL == 1}]
set E [expr {[info exists ::env(NUM_ENGINES)] ? $::env(NUM_ENGINES) : 1}]
if {[llength $active]!=$E || [llength $running]!=64*$E || [llength $completed]!=64*$E} {
    error "Timing-monitor state was not retained (expected $E monitors)"
}
foreach a $active {
    set startpoints [all_fanin -flat -startpoints_only -only_cells -to [get_pins $a/D]]
    if {[lsearch -glob $startpoints *int_ap_start_reg*]<0} {
        error "Timer active flag $a has no start-register input; refusing an inert counter"
    }
}
set timer_record [open $build_dir/timer_structure.json w]
puts $timer_record "{\"engines\":$E,\"running_bits\":64,\"completed_bits\":64,\"active_has_start_register_in_fanin\":true}"
close $timer_record
report_timing_summary -delay_type min_max -report_unconstrained -check_timing_verbose -file $build_dir/routed_timing.rpt
report_route_status -file $build_dir/route_status.rpt
report_utilization -file $build_dir/utilization.rpt
report_clocks -file $build_dir/clocks.rpt
source $root/scripts/record_kernel_clock.tcl
report_drc -file $build_dir/drc.rpt
set skew [report_bus_skew -return_string]
set f [open $build_dir/bus_skew.rpt w]
puts $f $skew
close $f
if {[regexp {\(VIOLATED\)} $skew]} {error "Bus skew constraints violated"}
exec python3 $root/scripts/check_timing_report.py $build_dir/routed_timing.rpt
set setup_paths [get_timing_paths -delay_type max -max_paths 1]
set hold_paths [get_timing_paths -delay_type min -max_paths 1]
if {[llength $setup_paths]!=1 || [llength $hold_paths]!=1} {error "Missing timing paths"}
set setup_slack [get_property SLACK $setup_paths]
set hold_slack [get_property SLACK $hold_paths]
puts "SNOWBALL_ROUTED_SLACK setup=$setup_slack hold=$hold_slack"
if {$setup_slack<0 || $hold_slack<0} {error "Full-board timing has not closed; image generation stopped"}
close_design
launch_runs impl_1 -to_step write_device_image -jobs 2
wait_on_runs impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {error "Image generation failed"}
puts "SNOWBALL_BOARD_IMAGE_READY $build_dir"
close_project
exit
