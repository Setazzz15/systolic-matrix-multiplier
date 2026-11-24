# Full-system behavioral simulation in batch mode (the GUI simulator has hung on this PC before).
# Writes soc_compile.log, soc_elaborate.log, soc_xsim.log and soc_sim_done.txt in the xsim folder.
source [file join [file dirname [file normalize [info script]]] common.tcl]
soc_run 02_sim {
    soc_log "STEP export simulation scripts"
    catch {close_sim -quiet}
    launch_simulation -scripts_only
    set sim_dir $::proj_dir/$::proj_name.sim/sim_1/behav/xsim
    soc_log "  sim dir: $sim_dir   files: [lsort [glob -nocomplain -tails -directory $sim_dir *.bat]]"
    foreach f {soc_compile.log soc_elaborate.log soc_xsim.log soc_sim_done.txt} { file delete -force $sim_dir/$f }

    # This Vivado install has no bin/xsim.bat, so start the simulator through loader.bat,
    # the same way as the batch command that was found to work earlier.
    set bin [file nativename $::env(XILINX_VIVADO)/bin]
    set fh [open $sim_dir/run_xsim.bat w]
    puts $fh "@echo off"
    puts $fh "call \"$bin\\setupEnv.bat\""
    puts $fh "set \"RDI_PROG=xsim\""
    puts $fh "set \"RDI_USE_JDK21=1\""
    puts $fh "set \"_RDI_NEEDS_PYTHON=True\""
    puts $fh "call \"$bin\\loader.bat\" -exec xsim tb_matrix_soc_behav -runall -log soc_xsim.log"
    close $fh

    set bat $sim_dir/run_soc_sim.bat
    set fh [open $bat w]
    puts $fh "@echo off"
    puts $fh "cd /d \"[file nativename $sim_dir]\""
    puts $fh "set \"PATH=[file nativename $::env(XILINX_VIVADO)/bin];%PATH%\""
    puts $fh "cmd /c compile.bat > soc_compile.log 2>&1"
    puts $fh "cmd /c elaborate.bat > soc_elaborate.log 2>&1"
    puts $fh "cmd /c run_xsim.bat > soc_xsim_stdout.log 2>&1"
    puts $fh "echo finished > soc_sim_done.txt"
    close $fh
    soc_log "STEP start $bat in the background"
    exec cmd.exe /c [file nativename $bat] &
}
