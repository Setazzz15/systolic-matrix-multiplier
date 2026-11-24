# Phase 1: make matrix_soc buildable and give the CPU a program and a serial port.
#   - back up the block design and project file
#   - Systolic_NxN.vh -> Systolic_NxN.sv (same contents, proper extension)
#   - block RAM: 64 KB, Stand Alone mode so it can load soc/fw/firmware.coe
#   - AXI UART Lite at 0x2000_0000 on the USB serial pins
#   - HDL wrapper as top, SoC constraints, full-system testbench
source [file join [file dirname [file normalize [info script]]] common.tcl]
soc_run 01_update_bd {
    set bd_file [get_files matrix_soc.bd]

    soc_log "STEP backup"
    set bk $::soc_dir/backup
    if {![file exists $bk]} {
        file mkdir $bk
        file copy -force $bd_file $bk/matrix_soc.bd
        file copy -force $::proj_dir/$::proj_name.xpr $bk/$::proj_name.xpr
    }

    soc_log "STEP rename Systolic_NxN.vh to .sv"
    set vh [get_files -quiet *Systolic_NxN.vh]
    if {[llength $vh]} {
        set vh_path [lindex $vh 0]
        set sv_path [file join [file dirname $vh_path] Systolic_NxN.sv]
        file copy -force $vh_path $sv_path
        remove_files $vh
        add_files -norecurse -fileset sources_1 $sv_path
        soc_log "  project now uses $sv_path (the .vh file is left on disk, unused)"
    }
    update_compile_order -fileset sources_1

    soc_log "STEP open block design"
    open_bd_design $bd_file
    catch {update_module_reference [get_ips -quiet matrix_soc_AXIMatrix_bd_0_0]} msg
    soc_log "  module reference refresh: $msg"

    soc_log "STEP block RAM address range 64K"
    set seg [get_bd_addr_segs -quiet picorv32_axi_0/mem_axi/SEG_axi_bram_ctrl_0_Mem0]
    if {![llength $seg]} {
        set seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces picorv32_axi_0/mem_axi] -filter {NAME =~ *bram*}]
    }
    soc_log "  segment: $seg"
    set_property range 64K $seg

    soc_log "STEP block RAM stand-alone with init file"
    set bram [get_bd_cells axi_bram_ctrl_0_bram]
    set coe $::soc_dir/fw/firmware.coe
    set_property CONFIG.use_bram_block {Stand_Alone} $bram
    set_property -dict [list \
        CONFIG.Memory_Type {Single_Port_RAM} \
        CONFIG.Enable_32bit_Address {true} \
        CONFIG.Use_Byte_Write_Enable {true} \
        CONFIG.Byte_Size {8} \
        CONFIG.Write_Width_A {32} \
        CONFIG.Read_Width_A {32} \
        CONFIG.Write_Depth_A {16384} \
        CONFIG.Register_PortA_Output_of_Memory_Primitives {false} \
        CONFIG.Use_RSTA_Pin {true} \
        CONFIG.EN_SAFETY_CKT {false} \
        CONFIG.Load_Init_File {true} \
        CONFIG.Coe_File $coe \
        CONFIG.Fill_Remaining_Memory_Locations {true} \
    ] $bram
    foreach p {use_bram_block Write_Depth_A Write_Width_A Enable_32bit_Address Load_Init_File Coe_File} {
        soc_log "  $p = [get_property CONFIG.$p $bram]"
    }

    soc_log "STEP AXI UART Lite"
    if {![llength [get_bd_cells -quiet axi_uartlite_0]]} {
        set_property CONFIG.NUM_MI {3} [get_bd_cells smartconnect_0]
        set u [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_uartlite axi_uartlite_0]
        if {[catch {set_property CONFIG.C_BAUDRATE {57600} $u} msg]} {
            soc_log "  57600 baud rejected ($msg); using 9600"
            set_property CONFIG.C_BAUDRATE {9600} $u
        }
        connect_bd_intf_net [get_bd_intf_pins smartconnect_0/M02_AXI] [get_bd_intf_pins axi_uartlite_0/S_AXI]
        connect_bd_net [get_bd_ports sysclk] [get_bd_pins axi_uartlite_0/s_axi_aclk]
        connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] [get_bd_pins axi_uartlite_0/s_axi_aresetn]
        create_bd_port -dir O uart_rxd_out
        create_bd_port -dir I uart_txd_in
        connect_bd_net [get_bd_pins axi_uartlite_0/tx] [get_bd_ports uart_rxd_out]
        connect_bd_net [get_bd_ports uart_txd_in] [get_bd_pins axi_uartlite_0/rx]
        assign_bd_address -target_address_space [get_bd_addr_spaces picorv32_axi_0/mem_axi] \
            -offset 0x20000000 -range 64K [get_bd_addr_segs axi_uartlite_0/S_AXI/Reg] -force
    }
    soc_log "  UART baud = [get_property CONFIG.C_BAUDRATE [get_bd_cells axi_uartlite_0]]"

    soc_log "STEP address map"
    catch {
        foreach s [get_bd_addr_segs -of_objects [get_bd_addr_spaces picorv32_axi_0/mem_axi]] {
            soc_log "  [get_property NAME $s]  offset [get_property offset $s]  range [get_property range $s]"
        }
    }

    soc_log "STEP validate and save"
    validate_bd_design
    save_bd_design

    soc_log "STEP generate output products"
    generate_target all $bd_file

    soc_log "STEP HDL wrapper as top"
    make_wrapper -files $bd_file -top
    set wrapper $::proj_dir/$::proj_name.gen/sources_1/bd/matrix_soc/hdl/matrix_soc_wrapper.v
    if {![file exists $wrapper]} {
        set wrapper [lindex [concat \
            [glob -nocomplain $::proj_dir/$::proj_name.gen/sources_1/bd/matrix_soc/hdl/matrix_soc_wrapper.*] \
            [glob -nocomplain $::proj_dir/$::proj_name.srcs/sources_1/bd/matrix_soc/hdl/matrix_soc_wrapper.*]] 0]
    }
    soc_log "  wrapper: $wrapper"
    if {![llength [get_files -quiet matrix_soc_wrapper.v]]} { add_files -norecurse -fileset sources_1 $wrapper }
    set_property top matrix_soc_wrapper [get_filesets sources_1]
    update_compile_order -fileset sources_1

    soc_log "STEP constraints"
    if {![llength [get_files -quiet cmod_soc.xdc]]} { add_files -norecurse -fileset constrs_1 $::soc_dir/cmod_soc.xdc }
    catch {set_property is_enabled false [get_files -quiet cmod_matrix.xdc]}

    soc_log "STEP testbench"
    if {![llength [get_files -quiet tb_matrix_soc.sv]]} { add_files -norecurse -fileset sim_1 $::soc_dir/sim/tb_matrix_soc.sv }
    set_property top tb_matrix_soc [get_filesets sim_1]
    set_property top_lib xil_defaultlib [get_filesets sim_1]
    update_compile_order -fileset sim_1
    soc_log "  design top: [get_property top [get_filesets sources_1]]   sim top: [get_property top [get_filesets sim_1]]"
}
