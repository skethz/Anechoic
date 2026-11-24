# The implementation worker opens a checkpoint in a fresh in-memory project.
# Restore the repository paths used by the unmodified official AVED UUID hook.
set snowball_ip_repo $::env(TASK_ROOT)/build/iprepo
if {[info exists ::env(SNOWBALL_IP_REPO)]} {set snowball_ip_repo $::env(SNOWBALL_IP_REPO)}
set_property ip_repo_paths [list \
    $::env(AVED_ROOT)/hw/amd_v80_gen5x8_25.1/src/iprepo \
    $snowball_ip_repo] [current_project]
source $::env(AVED_ROOT)/hw/amd_v80_gen5x8_25.1/src/constraints/write_device_image.pre.tcl
