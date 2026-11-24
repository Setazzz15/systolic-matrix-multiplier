# Speed-up: run the whole design at 48 MHz instead of the board's 12 MHz.
#   - Clocking Wizard (an MMCM inside the FPGA) multiplies the 12 MHz crystal clock up to 48 MHz
#   - every block that used sysclk now uses the wizard's output
#   - the wizard's "locked" output tells the reset block when the new clock is stable
#   - at 48 MHz the UART can run at 230400 baud
source [file join [file dirname [file normalize [info script]]] common.tcl]
soc_run 08_clock_48mhz {
    set bd_file [get_files matrix_soc.bd]

    soc_log "STEP backup"
    set bk $::soc_dir/backup_before_48mhz
    if {![file exists $bk]} {
        file mkdir $bk
        file copy -force $bd_file $bk/matrix_soc.bd
        file copy -force $::proj_dir/$::proj_name.xpr $bk/$::proj_name.xpr
    }

    soc_log "STEP open block design"
    if {[catch {open_bd_design $bd_file} msg]} { soc_log "  retrying: $msg"; open_bd_design $bd_file }
    set u [get_bd_cells axi_uartlite_0]

    if {![llength [get_bd_cells -quiet clk_wiz_0]]} {
        soc_log "STEP UART to a rate that is valid at both clock speeds"
        set_property CONFIG.C_BAUDRATE {57600} $u

        soc_log "STEP clocking wizard 12 -> 48 MHz"
        set cw [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz clk_wiz_0]
        set_property -dict [list \
            CONFIG.PRIM_IN_FREQ {12.000} \
            CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {48.000} \
            CONFIG.USE_RESET {false} \
            CONFIG.USE_LOCKED {true} \
        ] $cw

        set net [get_bd_nets -of_objects [get_bd_ports sysclk]]
        set loads {}
        foreach p [get_bd_pins -of_objects $net] {
            if {[get_property DIR $p] eq "I"} { lappend loads [get_property PATH $p] }
        }
        soc_log "  blocks moved to the 48 MHz clock: $loads"
        delete_bd_objs $net
        connect_bd_net [get_bd_ports sysclk] [get_bd_pins clk_wiz_0/clk_in1]
        foreach p $loads { connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins $p] }

        soc_log "STEP locked -> reset block"
        set lock_pin [get_bd_pins proc_sys_reset_0/dcm_locked]
        disconnect_bd_net [get_bd_nets -of_objects $lock_pin] $lock_pin
        connect_bd_net [get_bd_pins clk_wiz_0/locked] $lock_pin
    }

    soc_log "STEP validate at 48 MHz"
    if {![soc_validate 3]} { error "block design does not validate with the clocking wizard" }
    catch { soc_log "  wizard output: [get_property CONFIG.FREQ_HZ [get_bd_pins clk_wiz_0/clk_out1]] Hz" }

    soc_log "STEP faster UART"
    set chosen ""
    foreach want {230400 115200 57600} {
        if {[get_property CONFIG.C_BAUDRATE $u] == $want} { set chosen $want; break }
        if {![catch {set_property CONFIG.C_BAUDRATE $want $u} msg] && [soc_validate 2]} { set chosen $want; break }
        soc_log "  $want not accepted"
    }
    set nominal [get_property CONFIG.C_BAUDRATE $u]
    set divider [expr {int(round(48000000.0 / (16 * $nominal)))}]
    set actual  [expr {48000000 / (16 * $divider)}]
    # Use the standard name when the real rate is within 1 percent of it.
    set pc_baud [expr {abs($actual - $nominal) * 100 < $nominal ? $nominal : $actual}]
    soc_log "  UART setting $nominal, divider $divider, real baud rate $actual, PC should use $pc_baud"
    set fh [open $::soc_dir/logs/uart_baud.txt w]; puts $fh $pc_baud; close $fh
    set fh [open $::soc_dir/logs/clock_hz.txt w]; puts $fh 48000000; close $fh

    soc_log "STEP save and generate"
    save_bd_design
    generate_target all $bd_file
    catch {make_wrapper -files $bd_file -top}
    soc_log "  design top: [get_property top [get_filesets sources_1]]   sim top: [get_property top [get_filesets sim_1]]"
}
