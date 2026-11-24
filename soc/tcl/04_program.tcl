# Load the bitstream into the connected Cmod A7 (volatile: gone at power-off, flash untouched).
source [file join [file dirname [file normalize [info script]]] common.tcl]
soc_run 04_program {
    set bit $::proj_dir/$::proj_name.runs/impl_1/matrix_soc_wrapper.bit
    if {![file exists $bit]} { error "no bitstream at $bit" }
    open_hw_manager
    catch {connect_hw_server} msg;  soc_log "connect_hw_server: $msg"
    catch {open_hw_target} msg;     soc_log "open_hw_target: $msg"
    set dev [lindex [get_hw_devices xc7a35t*] 0]
    if {$dev eq ""} { error "no xc7a35t device found on the cable: [get_hw_devices]" }
    current_hw_device $dev
    set_property PROGRAM.FILE $bit $dev
    set_property PROBES.FILE {} $dev
    program_hw_devices $dev
    refresh_hw_device $dev
    soc_log "programmed $dev with $bit"
}
