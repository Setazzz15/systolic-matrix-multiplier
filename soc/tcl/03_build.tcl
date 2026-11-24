# Synthesize, implement and write the bitstream for matrix_soc_wrapper. Returns at once;
# progress is in <project>.runs/*/runme.log and the result is impl_1/matrix_soc_wrapper.bit.
source [file join [file dirname [file normalize [info script]]] common.tcl]
soc_run 03_build {
    update_compile_order -fileset sources_1
    soc_log "top = [get_property top [get_filesets sources_1]]"
    if {[llength [get_runs -quiet synth_1]]} { reset_run synth_1 }
    launch_runs impl_1 -to_step write_bitstream -jobs 8
    soc_log "launched impl_1 to write_bitstream"
}
