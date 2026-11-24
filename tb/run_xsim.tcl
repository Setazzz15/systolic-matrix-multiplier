# Run tb_systolic_controller in the Vivado simulator (xsim) without touching the project.
# In the Vivado Tcl Console:
#     source C:/Users/Sebastian/Matrix_multiplier/tb/run_xsim.tcl
# Everything it writes goes to tb/xsim_work. The verdict is printed at the end and is the
# last "TB ..." line of tb/xsim_work/xsim.log.
set tb_dir  [file dirname [file normalize [info script]]]
set rtl_dir [file join [file dirname $tb_dir] Matrix_multiplier.srcs sources_1 new]
set vec_dir [file join $tb_dir vectors]
# Work in tb/xsim_work. If a process from an earlier run still holds files there, use the
# next free folder (xsim_work_2, xsim_work_3, ...).
set work ""
foreach suffix {"" _2 _3 _4 _5 _6 _7 _8 _9} {
    set candidate [file join $tb_dir xsim_work$suffix]
    if {[catch {
        file mkdir $candidate
        foreach f {run_xsim.bat run_all.bat compile.log elaborate.log xsim.log xsim_stdout.log done.txt} {
            file delete -force [file join $candidate $f]
        }
        close [open [file join $candidate run_xsim.bat] w]
    }]} { continue }
    set work $candidate
    break
}
if {$work eq ""} { error "tb: every xsim_work folder is locked by another process. Restart the PC or end leftover cmd.exe/xsim.exe processes." }
puts "tb: working in $work"

# The vectors come from the NumPy reference. Generate them if they are not there yet.
if {![file exists [file join $vec_dir vec_n8.mem]]} {
    puts "tb: generating vectors with python gen_vectors.py"
    if {[catch {exec python [file join $tb_dir gen_vectors.py]} msg]} {
        error "tb: could not run gen_vectors.py ($msg). Run it yourself: python tb/gen_vectors.py"
    }
}

set bin [file nativename [file join $::env(XILINX_VIVADO) bin]]

# The simulator step. It runs in tb/xsim_work and the testbench finds ../vectors by itself
# (a VEC_DIR=... argument does not survive the nested .bat calls: cmd splits it at the "=").
# Some Vivado installs have no bin/xsim.bat; soc/tcl/02_sim.tcl found
# that starting xsim through loader.bat works on this PC, so do the same when it is missing.
set fh [open [file join $work run_xsim.bat] w]
puts $fh "@echo off"
if {[file exists [file join $::env(XILINX_VIVADO) bin xsim.bat]]} {
    puts $fh "call \"$bin\\xsim.bat\" tb_sc -runall -log xsim.log"
} else {
    puts $fh "call \"$bin\\setupEnv.bat\""
    puts $fh "set \"RDI_PROG=xsim\""
    puts $fh "set \"RDI_USE_JDK21=1\""
    puts $fh "set \"_RDI_NEEDS_PYTHON=True\""
    puts $fh "call \"$bin\\loader.bat\" -exec xsim tb_sc -runall -log xsim.log"
}
close $fh

set fh [open [file join $work run_all.bat] w]
puts $fh "@echo off"
puts $fh "cd /d \"[file nativename $work]\""
puts $fh "set \"PATH=$bin;%PATH%\""
puts $fh "call xvlog --relax --sv \"[file join $rtl_dir pe.sv]\" \"[file join $rtl_dir Systolic_NxN.sv]\" \"[file join $rtl_dir systolic_controller.sv]\" \"[file join $tb_dir tb_systolic_controller.sv]\" > compile.log 2>&1"
puts $fh "call xelab --relax tb_systolic_controller -s tb_sc > elaborate.log 2>&1"
puts $fh "cmd /c run_xsim.bat > xsim_stdout.log 2>&1"
puts $fh "echo finished > done.txt"
close $fh

# Start it in the background and watch the log. On this PC xsim prints its result and then
# does not exit, and a plain "exec" would freeze the Tcl Console until it does.
puts "tb: compiling and simulating, about 15 seconds"
set pid [exec cmd.exe /c [file nativename [file join $work run_all.bat]] &]

proc tb_read_verdict {work} {
    set verdict ""
    set lines {}
    foreach name {xsim.log xsim_stdout.log} {
        set path [file join $work $name]
        if {[catch {open $path r} fh]} { continue }
        foreach line [split [read $fh] \n] {
            if {[string match "PASS N=*" $line] || [string match "FAIL N=*" $line] || [string match "ERROR*" $line]} { lappend lines $line }
            if {[string match "TB *" $line]} { set verdict $line }
        }
        close $fh
        if {$verdict ne ""} { break }
        set lines {}
    }
    return [list $verdict $lines]
}

set verdict ""
set lines {}
set deadline [expr {[clock seconds] + 180}]
while {[clock seconds] < $deadline} {
    after 500
    lassign [tb_read_verdict $work] verdict lines
    if {$verdict ne ""} { break }
    # The batch file finished without a verdict: compile or elaboration failed.
    if {[file exists [file join $work done.txt]]} { lassign [tb_read_verdict $work] verdict lines; break }
}

# Give the simulator a few seconds to exit by itself, then stop the processes this script started.
set waited 0
while {![file exists [file join $work done.txt]] && $waited < 10} { after 500; incr waited }
if {![file exists [file join $work done.txt]]} {
    catch {exec taskkill /F /T /PID [lindex $pid 0]}
}

foreach line $lines { puts $line }
if {$verdict eq ""} {
    set verdict "TB FAIL: no verdict found. Read compile.log, elaborate.log and xsim_stdout.log in $work"
}
puts $verdict
