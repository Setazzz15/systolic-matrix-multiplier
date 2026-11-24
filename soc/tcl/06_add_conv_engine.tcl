# Phase 4: add the conv1 engine (hardware-fed systolic array) to matrix_soc.
#   - conv1_engine.sv, AXIConv.sv, AXIConv_bd.v added to the project
#   - AXIConv_bd on SmartConnect M03 at 0x3000_0000
#   - UART raised from 57600 to 250000 baud if the IP accepts it
#   - block RAM initialised with firmware version 2 (soc/fw2/firmware_v2.coe)
source [file join [file dirname [file normalize [info script]]] common.tcl]
soc_run 06_add_conv_engine {
    set bd_file [get_files matrix_soc.bd]
    set src_dir $::proj_dir/$::proj_name.srcs/sources_1/new

    soc_log "STEP backup"
    set bk $::soc_dir/backup_before_phase4
    if {![file exists $bk]} {
        file mkdir $bk
        file copy -force $bd_file $bk/matrix_soc.bd
        file copy -force $::proj_dir/$::proj_name.xpr $bk/$::proj_name.xpr
    }

    soc_log "STEP add RTL"
    foreach f {conv1_engine.sv AXIConv.sv AXIConv_bd.v} {
        if {![llength [get_files -quiet $f]]} { add_files -norecurse -fileset sources_1 $src_dir/$f }
    }
    update_compile_order -fileset sources_1

    soc_log "STEP open block design"
    open_bd_design $bd_file

    soc_log "STEP conv1 engine on SmartConnect M03"
    if {![llength [get_bd_cells -quiet AXIConv_bd_0]]} {
        set_property CONFIG.NUM_MI {4} [get_bd_cells smartconnect_0]
        create_bd_cell -type module -reference AXIConv_bd AXIConv_bd_0
        connect_bd_intf_net [get_bd_intf_pins smartconnect_0/M03_AXI] [get_bd_intf_pins AXIConv_bd_0/s_axi]
        connect_bd_net [get_bd_ports sysclk] [get_bd_pins AXIConv_bd_0/s_axi_aclk]
        connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] [get_bd_pins AXIConv_bd_0/s_axi_aresetn]
        assign_bd_address -target_address_space [get_bd_addr_spaces picorv32_axi_0/mem_axi] \
            -offset 0x30000000 -range 4K [get_bd_addr_segs AXIConv_bd_0/s_axi/reg0] -force
    } else {
        catch {update_module_reference [get_ips -quiet matrix_soc_AXIConv_bd_0_0]}
    }

    soc_log "STEP firmware version 2 in block RAM"
    set_property CONFIG.Coe_File $::soc_dir/fw2/firmware_v2.coe [get_bd_cells axi_bram_ctrl_0_bram]
    soc_log "  Coe_File = [get_property CONFIG.Coe_File [get_bd_cells axi_bram_ctrl_0_bram]]"

    soc_log "STEP validate with the engine"
    if {![soc_validate 3]} { error "block design does not validate after adding the engine" }

    soc_log "STEP faster UART"
    # 12 MHz / (16 x 3) = 250000 baud exactly. The IP only offers standard names, and 230400 is the
    # one that rounds to a divider of 3. The PC must then open the port at 250000.
    set u [get_bd_cells axi_uartlite_0]
    set old_baud [get_property CONFIG.C_BAUDRATE $u]
    set want [expr {[info exists ::soc_nominal_baud] ? $::soc_nominal_baud : 230400}]
    if {$old_baud != $want} {
        if {[catch {set_property CONFIG.C_BAUDRATE $want $u} msg] || ![soc_validate 2]} {
            soc_log "  $want baud not accepted; staying at $old_baud"
            set_property CONFIG.C_BAUDRATE $old_baud $u
            if {![soc_validate 3]} { error "block design does not validate after restoring the baud rate" }
        }
    }
    set nominal [get_property CONFIG.C_BAUDRATE $u]
    set divider [expr {int(round(12000000.0 / (16 * $nominal)))}]
    set actual  [expr {12000000 / (16 * $divider)}]
    soc_log "  UART setting $nominal, divider $divider, real baud rate $actual"
    set fh [open $::soc_dir/logs/uart_baud.txt w]; puts $fh $actual; close $fh

    soc_log "STEP address map"
    catch {
        foreach s [get_bd_addr_segs -of_objects [get_bd_addr_spaces picorv32_axi_0/mem_axi]] {
            soc_log "  [get_property NAME $s]  offset [get_property offset $s]  range [get_property range $s]"
        }
    }

    soc_log "STEP save and generate"
    save_bd_design
    generate_target all $bd_file
    catch {make_wrapper -files $bd_file -top}
    update_compile_order -fileset sources_1
    update_compile_order -fileset sim_1
    soc_log "  design top: [get_property top [get_filesets sources_1]]   sim top: [get_property top [get_filesets sim_1]]"
}
