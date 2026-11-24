# Report run status after 03_build.
source [file join [file dirname [file normalize [info script]]] common.tcl]
soc_run 03b_status {
    foreach r [get_runs] {
        soc_log "[format %-45s $r] [get_property STATUS $r]  progress [get_property PROGRESS $r]"
    }
    set bit $::proj_dir/$::proj_name.runs/impl_1/matrix_soc_wrapper.bit
    soc_log "bitstream exists: [file exists $bit]"
    if {[get_property PROGRESS [get_runs impl_1]] eq "100%"} {
        open_run impl_1
        report_utilization -file $::soc_dir/logs/utilization.rpt
        report_timing_summary -file $::soc_dir/logs/timing_summary.rpt
        soc_log "WNS = [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]] ns"
    }
}
