set root [file normalize [lindex $argv 0]]
set arm [lindex $argv 1]
if {$arm ni {brammux score skid fanout rngdecode}} {error "unknown architecture"}
set out [file join $root $arm]
set_param general.maxThreads 4
puts "Matched experiment, [version -short], [clock format [clock seconds] -gmt 1]"
read_verilog [file join $out sca_core.v]
synth_design -top sca_core -part xcv80-lsva4737-2MHP-e-S -mode out_of_context
create_clock -period 4.000 -name clk [get_ports clk]
report_utilization -file [file join $out util_synth.rpt]
report_utilization -hierarchical -hierarchical_depth 3 -file [file join $out hier_synth.rpt]
write_checkpoint -force [file join $out synth.dcp]
create_pblock pb
resize_pblock [get_pblocks pb] -add {CLOCKREGION_X2Y5:CLOCKREGION_X4Y7}
add_cells_to_pblock [get_pblocks pb] -top
opt_design
place_design -directive Explore
phys_opt_design -directive AggressiveExplore
route_design -directive Explore
proc capture {dir label} {
    report_route_status -file [file join $dir route_${label}.rpt]
    report_timing_summary -max_paths 10 -file [file join $dir timing_${label}.rpt]
    report_utilization -file [file join $dir util_${label}.rpt]
    report_utilization -hierarchical -hierarchical_depth 3 -file [file join $dir hier_${label}.rpt]
    set f [open [file join $dir slack_${label}.txt] w]
    set setup [get_property SLACK [get_timing_paths -setup -max_paths 1]]
    set hold [get_property SLACK [get_timing_paths -hold -max_paths 1]]
    puts $f "setup_ns $setup"
    puts $f "hold_ns $hold"
    close $f
    write_checkpoint -force [file join $dir ${label}.dcp]
}
capture $out before_postroute_physopt
phys_opt_design -directive AggressiveExplore
capture $out final
puts "OOC_DONE $arm"
exit
