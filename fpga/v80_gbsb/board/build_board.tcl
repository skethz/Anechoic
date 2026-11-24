set root $::env(TASK_ROOT)
set task_root $root
set kernel_mhz $::env(KERNEL_MHZ)
set src_dir $::env(AVED_ROOT)/hw/amd_v80_gen5x8_25.1/src
set board_tag board_${kernel_mhz}mhz
if {[info exists ::env(BOARD_TAG)]} {set board_tag $::env(BOARD_TAG)}
if {![regexp {^[a-zA-Z0-9_]+$} $board_tag]} {error "Invalid build tag"}
set build_dir $root/build/$board_tag
set snowball_ip_repo $root/build/iprepo
if {[info exists ::env(SNOWBALL_IP_REPO)]} {set snowball_ip_repo $::env(SNOWBALL_IP_REPO)}
set bd_name top
set design_name amd_v80_gen5x8_25.1
set_param general.maxThreads 8
create_project prj $build_dir -part xcv80-lsva4737-2MHP-e-S -force
set_property target_language Verilog [current_project]
set core [ipx::open_core $snowball_ip_repo/sca_v80/component.xml]
ipx::update_checksums $core
ipx::save_core $core
ipx::unload_core $core
set_property ip_repo_paths [list $src_dir/iprepo $snowball_ip_repo] [current_project]
update_ip_catalog
create_bd_design top
source $src_dir/bd/create_bd_design.tcl
create_root_design ""
# v6 and later pass their own integration script (default: the v5.x HLS-only engine integration).
source [expr {[info exists ::env(INTEGRATE_TCL)] ? $::env(INTEGRATE_TCL) : "$root/scripts/integrate_kernel.tcl"}]
validate_bd_design
save_bd_design
write_bd_tcl -force $build_dir/integrated_bd.tcl
generate_target all [get_files top.bd]
set wrappers [make_wrapper -files [get_files top.bd] -top]
add_files -norecurse $wrappers
set_property top top_wrapper [current_fileset]
update_compile_order -fileset sources_1
report_compile_order -fileset sources_1 -file $build_dir/compile_order.rpt
foreach name {impl.xdc impl.pins.xdc} {
    import_files -fileset constrs_1 -norecurse $src_dir/constraints/$name
    set_property -dict {used_in_synthesis false processing_order NORMAL} [get_files *$name]
}
# Optional per-engine floorplan (implementation only): PBLOCK_XDC confines each replicated engine to its own SLR.
if {[info exists ::env(PBLOCK_XDC)]} {
    import_files -fileset constrs_1 -norecurse $::env(PBLOCK_XDC)
    set_property -dict {used_in_synthesis false processing_order NORMAL} [get_files *[file tail $::env(PBLOCK_XDC)]]
}
foreach {step name} {
    OPT_DESIGN.TCL.POST opt.post.tcl
    PLACE_DESIGN.TCL.PRE place.pre.tcl
} {
    import_files -fileset utils_1 -norecurse $src_dir/constraints/$name
    set_property STEPS.$step [get_files *$name] [get_runs impl_1]
}
import_files -fileset utils_1 -norecurse $root/scripts/write_device_image_pre.tcl
set_property STEPS.WRITE_DEVICE_IMAGE.TCL.PRE [get_files *write_device_image_pre.tcl] [get_runs impl_1]
set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE Explore [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE ExploreWithAggressiveHoldFix [get_runs impl_1]
set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE Explore [get_runs impl_1]
if {[info exists ::env(INCREMENTAL_DCP)]} {
    set_property AUTO_INCREMENTAL_CHECKPOINT false [get_runs impl_1]
    set_property INCREMENTAL_CHECKPOINT $::env(INCREMENTAL_DCP) [get_runs impl_1]
}
source $root/scripts/implement_board.tcl
