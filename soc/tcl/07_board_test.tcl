# Phase 4 board test from Vivado's Tcl Console, playing the role the Python script will play:
# ping, self-test, upload weights and an image, then ask for conv1 rows in all three modes.
# Every reply is appended to soc/logs/board_rows.bin for checking against the reference.
source [file join [file dirname [file normalize [info script]]] common.tcl]
soc_run 07_board_test {
    proc soc_file_bytes {path} { set f [open $path rb]; set d [read $f]; close $f; return $d }
    proc soc_sum {data} { binary scan $data cu* b; set s 0; foreach x $b { incr s $x }; return [expr {$s & 255}] }

    set ch [soc_uart_open]
    set out [open $::soc_dir/logs/board_rows.bin wb]
    if {[catch {
        set r [soc_xfer $ch "P" 4 2000]
        soc_log "ping: '$r'"
        if {$r ne "MXC2"} { error "the firmware did not answer the ping" }

        puts -nonewline $ch "S"; flush $ch
        set line ""
        set deadline [expr {[clock milliseconds] + 5000}]
        while {[string first "\n" $line] < 0 && [clock milliseconds] < $deadline} { append line [read $ch]; after 5 }
        soc_log "selftest: [string trim $line]"

        foreach {cmd file} {W w_q.bin I img_q.bin} {
            set data [soc_file_bytes $::soc_dir/test/$file]
            set t0 [clock milliseconds]
            set r [soc_xfer $ch $cmd$data 2 20000]
            binary scan $r a1cu ack sum
            soc_log "upload $file: [string length $data] bytes, ack '$ack', checksum [expr {$sum == [soc_sum $data] ? "ok" : "WRONG"}], [expr {[clock milliseconds] - $t0}] ms"
            if {$ack ne "K" || $sum != [soc_sum $data]} { error "upload of $file failed" }
        }

        # {mode row nfp}: all 28 rows with the engine, then one partial row in each slow mode.
        set jobs {}
        for {set y 0} {$y < 28} {incr y} { lappend jobs [list 2 $y 16] }
        lappend jobs {1 5 2} {0 9 1}
        set t_all [clock milliseconds]
        foreach job $jobs {
            lassign $job mode row nfp
            set t0 [clock milliseconds]
            set r [soc_xfer $ch [binary format a1c3 R [list $mode $row $nfp]] 3592 60000]
            if {[string length $r] != 3592} { error "row reply too short: [string length $r] bytes (mode $mode row $row)" }
            puts -nonewline $out $r
            binary scan $r a1cucuiu tag m y cycles
            if {$mode != 2 || $row == 0 || $row == 27} {
                soc_log "mode $m row $y: $cycles clocks of computing, [expr {[clock milliseconds] - $t0}] ms including transfer"
            }
        }
        soc_log "all [llength $jobs] rows: [expr {[clock milliseconds] - $t_all}] ms"
    } err]} {
        close $out; close $ch
        error $err
    }
    close $out
    close $ch
}
