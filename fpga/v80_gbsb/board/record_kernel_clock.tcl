# Called with the routed design open. Use the programmed divider ratio rather
# than inverting Vivado's rounded 3-decimal PERIOD property for time conversion.
set kcell [expr {[llength [get_cells -quiet top_i/snowball]] ? "top_i/snowball" : "top_i/snowball0"}]
set kernel_clocks [lsort -unique [get_clocks -of_objects [get_pins $kcell/ap_clk]]]
if {[llength $kernel_clocks]!=1} {error "Ambiguous kernel clock"}
set mmcm [get_cells -hierarchical -filter {REF_NAME == MMCME5 && NAME =~ *usr_clk_wiz*}]
if {[llength $mmcm]!=1} {error "Ambiguous user clock generator"}
if {[lsort -unique [get_clocks -of_objects [get_pins $mmcm/CLKOUT0]]] ne $kernel_clocks} {
    error "Kernel is not driven by expected MMCM output"
}
set cips [get_ips top_cips_0]
if {[llength $cips]!=1} {error "CIPS configuration unavailable"}
set cips_config [get_property CONFIG.PS_PMC_CONFIG $cips]
set input_mhz [dict get $cips_config PMC_CRP_PL1_REF_CTRL_FREQMHZ]
set multiplier [get_property CLKFBOUT_MULT $mmcm]
set fraction [get_property CLKFBOUT_FRACT $mmcm]
set input_divider [get_property DIVCLK_DIVIDE $mmcm]
set output_divider [get_property CLKOUT0_DIVIDE $mmcm]
set fb $multiplier
if {$fraction!=0} {
    # Fractional MMCME5 feedback: accept it only if the primitive's (MULT, FRACT) reproduces the clock wizard's configured
    # multiplier exactly for one fractional resolution; the routed-period check below must still pass.
    set wiz [get_ips -quiet top_usr_clk_wiz_0]
    if {[llength $wiz]!=1} {error "Clock wizard configuration unavailable for fractional MMCM"}
    set wiz_mult [get_property CONFIG.CLKFBOUT_MULT $wiz]
    set fb ""
    foreach k {8 64} {
        if {abs($multiplier + double($fraction)/$k - $wiz_mult) < 1e-9} {set fb [expr {$multiplier + double($fraction)/$k}]; set frac_res $k; break}
    }
    if {$fb eq ""} {error "Fractional MMCM setting ($multiplier + $fraction/k) does not match the clock wizard multiplier $wiz_mult"}
    puts "FRACTIONAL_MMCM multiplier=$multiplier fraction=$fraction resolution=1/$frac_res effective=$fb"
}
set mhz [expr {double($input_mhz)*$fb/$input_divider/$output_divider}]
set period [get_property PERIOD [lindex $kernel_clocks 0]]
if {abs(1000.0/$mhz-$period)>0.002} {error "Configured clock disagrees with routed timing clock"}
set out [open $build_dir/kernel_clock.json w]
puts $out [format {{"requested_mhz":%s,"routed_period_ns":%s,"actual_mhz":%.9f,"clock":"%s","frequency_source":"Configured nominal CIPS clock and routed MMCM dividers; not an external frequency measurement","input_mhz":%.9f,"feedback_multiplier":%.9f,"input_divider":%d,"output_divider":%d}} $kernel_mhz $period $mhz [lindex $kernel_clocks 0] $input_mhz $fb $input_divider $output_divider]
close $out
puts "VERIFIED_KERNEL_NOMINAL_MHZ $mhz"
