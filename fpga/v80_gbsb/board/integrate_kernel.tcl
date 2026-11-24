# Integrate the 12-trajectory K2000 GbSB IP and timing monitor.
current_bd_instance /
set kernel_mhz $::env(KERNEL_MHZ)
set_property CONFIG.CLKOUT_REQUESTED_OUT_FREQUENCY "$kernel_mhz,[expr {2*$kernel_mhz}]" \
    [get_bd_cells clock_reset/usr_clk_wiz]

# NUM_ENGINES (default 1): independent copies of the same verified IP, each with its own AXI-Lite control window
# (BAR0 offset 0x01100000 + e*0x1000) and its own three masters into the shared HBM0_PC0 aperture.
set E [expr {[info exists ::env(NUM_ENGINES)] ? $::env(NUM_ENGINES) : 1}]
if {$E < 1 || 3*$E > 16} {error "NUM_ENGINES must be 1..5"}
set engines {}
if {$E == 1} {set engines {snowball}} else {for {set e 0} {$e < $E} {incr e} {lappend engines snowball$e}}
foreach n $engines {
    create_bd_cell -type ip -vlnv xilinx.com:hls:sca_v80:1.0 $n
    connect_bd_net [get_bd_pins clock_reset/clk_usr_0] [get_bd_pins $n/ap_clk]
    connect_bd_net [get_bd_pins clock_reset/resetn_usr_0_periph] [get_bd_pins $n/ap_rst_n]
}

# Management registers remain inside the existing 32 MiB PL aperture.
set_property CONFIG.NUM_MI 5 [get_bd_cells base_logic/pcie_slr0_mgmt_sc]
current_bd_instance /base_logic
create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 m_axi_snowball_ctrl
connect_bd_intf_net [get_bd_intf_pins pcie_slr0_mgmt_sc/M04_AXI] \
    [get_bd_intf_pins m_axi_snowball_ctrl]
current_bd_instance /
set ctrl_sc [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect snowball_ctrl_sc]
set_property -dict [list CONFIG.NUM_SI 1 CONFIG.NUM_MI $E CONFIG.NUM_CLKS 2] $ctrl_sc
connect_bd_intf_net [get_bd_intf_pins base_logic/m_axi_snowball_ctrl] \
    [get_bd_intf_pins snowball_ctrl_sc/S00_AXI]
set e 0
foreach n $engines {
    connect_bd_intf_net [get_bd_intf_pins snowball_ctrl_sc/[format M%02d_AXI $e]] [get_bd_intf_pins $n/s_axi_control]
    incr e
}
connect_bd_net [get_bd_pins cips/pl0_ref_clk] [get_bd_pins snowball_ctrl_sc/aclk]
connect_bd_net [get_bd_pins clock_reset/clk_usr_0] [get_bd_pins snowball_ctrl_sc/aclk1]
connect_bd_net [get_bd_pins clock_reset/resetn_pl_ic] [get_bd_pins snowball_ctrl_sc/aresetn]

# Adapt the three HLS master widths to one 256-bit NoC input at the kernel clock.
set mem_sc [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect snowball_mem_sc]
set_property -dict [list CONFIG.NUM_SI [expr {3*$E}] CONFIG.NUM_MI 1 CONFIG.NUM_CLKS 1] $mem_sc
set si 0
foreach n $engines {
    for {set i 0} {$i < 3} {incr i} {
        connect_bd_intf_net [get_bd_intf_pins $n/m_axi_gmem$i] [get_bd_intf_pins snowball_mem_sc/[format S%02d_AXI $si]]
        incr si
    }
}
connect_bd_net [get_bd_pins clock_reset/clk_usr_0] [get_bd_pins snowball_mem_sc/aclk]
connect_bd_net [get_bd_pins clock_reset/resetn_usr_0_ic] [get_bd_pins snowball_mem_sc/aresetn]
set_property -dict [list CONFIG.NUM_SI 5 CONFIG.NUM_CLKS 6] [get_bd_cells axi_noc_cips]
set_property -dict [list \
    CONFIG.DATA_WIDTH 256 \
    CONFIG.CATEGORY pl \
    CONFIG.CONNECTIONS {HBM0_PORT0 {read_bw {2000} write_bw {500} read_avg_burst {16} write_avg_burst {16}}} \
    ] [get_bd_intf_pins axi_noc_cips/S04_AXI]
set_property CONFIG.ASSOCIATED_BUSIF S04_AXI [get_bd_pins axi_noc_cips/aclk5]
connect_bd_intf_net [get_bd_intf_pins snowball_mem_sc/M00_AXI] [get_bd_intf_pins axi_noc_cips/S04_AXI]
connect_bd_net [get_bd_pins clock_reset/clk_usr_0] [get_bd_pins axi_noc_cips/aclk5]

# Host staging uses a dedicated PCIe BAR window onto HBM0_PC0. Kernel timing
# excludes these transfers. BAR0 retains its management mapping.
set cpm [get_property CONFIG.CPM_CONFIG [get_bd_cells cips]]
foreach {key value} {
    CPM_PCIE1_PF0_BAR2_QDMA_ENABLED 1
    CPM_PCIE1_PF0_BAR2_QDMA_64BIT 1
    CPM_PCIE1_PF0_BAR2_QDMA_PREFETCHABLE 1
    CPM_PCIE1_PF0_BAR2_QDMA_SCALE Megabytes
    CPM_PCIE1_PF0_BAR2_QDMA_SIZE 16
    CPM_PCIE1_PF0_BAR2_QDMA_TYPE AXI_Bridge_Master
    CPM_PCIE1_PF0_PCIEBAR2AXIBAR_QDMA_2 0x0000004000000000
} {dict set cpm $key $value}
set_property CONFIG.CPM_CONFIG $cpm [get_bd_cells cips]

set e 0
foreach n $engines {
    foreach master {cips/CPM_PCIE_NOC_0 cips/CPM_PCIE_NOC_1} {
        assign_bd_address -offset [format 0x%012x [expr {0x020101100000 + $e*0x1000}]] -range 0x00001000 \
            -target_address_space [get_bd_addr_spaces $master] \
            [get_bd_addr_segs $n/s_axi_control/Reg] -force
    }
    foreach g {gmem0 gmem1 gmem2} {
        assign_bd_address -offset 0x004000000000 -range 0x40000000 \
            -target_address_space [get_bd_addr_spaces $n/Data_m_axi_$g] \
            [get_bd_addr_segs axi_noc_cips/S04_AXI/HBM0_PC0] -force
    }
    incr e
}
