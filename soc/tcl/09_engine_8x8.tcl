# Speed-up: the conv1 engine now drives an 8 x 8 systolic array (64 PEs) instead of 2 x 2.
# conv1_engine.sv was replaced on disk (the 2 x 2 version is kept in soc/backup_before_8x8/).
# The block design only needs to re-read the module and regenerate.
source [file join [file dirname [file normalize [info script]]] common.tcl]
soc_run 09_engine_8x8 {
    set bd_file [get_files matrix_soc.bd]
    soc_log "STEP open block design"
    if {[catch {open_bd_design $bd_file} msg]} { soc_log "  retrying: $msg"; open_bd_design $bd_file }
    soc_log "STEP re-read AXIConv_bd and what is inside it"
    catch {update_module_reference [get_ips -quiet matrix_soc_AXIConv_bd_0_0]} msg
    soc_log "  $msg"
    soc_log "STEP validate"
    if {![soc_validate 3]} { error "block design does not validate with the 8 x 8 engine" }
    soc_log "STEP save and generate"
    save_bd_design
    generate_target all $bd_file
    catch {make_wrapper -files $bd_file -top}
    soc_log "  design top: [get_property top [get_filesets sources_1]]   sim top: [get_property top [get_filesets sim_1]]"
}
