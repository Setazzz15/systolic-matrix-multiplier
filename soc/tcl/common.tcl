# Shared helpers for the soc/tcl scripts. Each script writes soc/logs/<name>.log.
set ::soc_dir  [file dirname [file dirname [file normalize [info script]]]]
set ::proj_dir [get_property DIRECTORY [current_project]]
set ::proj_name [get_property NAME [current_project]]
file mkdir $::soc_dir/logs
proc soc_log_open {name} {
    set ::soc_logf [open $::soc_dir/logs/$name.log w]
    soc_log "== $name  [clock format [clock seconds]]"
}
proc soc_log {msg} { puts $::soc_logf $msg; flush $::soc_logf; puts $msg }
proc soc_log_close {} { close $::soc_logf }
# Run a script body; log the Tcl error and stack if it fails, and a final RESULT line either way.
proc soc_run {name body} {
    soc_log_open $name
    if {[catch {uplevel #0 $body} err]} {
        soc_log "RESULT: FAILED: $err"
        soc_log $::errorInfo
    } else {
        soc_log "RESULT: OK"
    }
    soc_log_close
}
# validate_bd_design has failed once on this PC with a transient "Spawn failed"; retry a few times.
proc soc_validate {{tries 3}} {
    for {set i 1} {$i <= $tries} {incr i} {
        if {![catch {validate_bd_design} msg]} { return 1 }
        soc_log "  validate attempt $i failed: [lindex [split $msg \n] 0]"
    }
    return 0
}
# The UART's real baud rate: AXI UART Lite divides the 12 MHz clock by 16 x a whole number.
proc soc_baud {} {
    if {[info exists ::soc_baud]} { return $::soc_baud }
    set f $::soc_dir/logs/uart_baud.txt
    if {[file exists $f]} { set fh [open $f r]; set b [string trim [read $fh]]; close $fh; return $b }
    return 57600
}
# Open the board's USB serial port in binary mode. FTDI bridges show up as \Device\VCPn.
proc soc_uart_open {} {
    set ports {}
    if {[info exists ::soc_com]} {
        set ports [list $::soc_com]
    } elseif {![catch {package require registry}]} {
        set key {HKEY_LOCAL_MACHINE\HARDWARE\DEVICEMAP\SERIALCOMM}
        catch { foreach name [registry values $key] { if {[string match -nocase *VCP* $name]} { lappend ports [registry get $key $name] } } }
    }
    if {![llength $ports]} { set ports {COM4} }
    set com [lindex $ports 0]
    set ch [open [format {\\.\%s} $com] r+]
    fconfigure $ch -mode [soc_baud],n,8,1 -handshake none -blocking 0 -translation binary -buffering none
    soc_log "  serial port $com at [soc_baud] baud"
    after 100
    catch {read $ch}
    return $ch
}
# Send bytes, then collect exactly n reply bytes (or give up after timeout_ms).
proc soc_xfer {ch data n timeout_ms} {
    if {[string length $data]} { puts -nonewline $ch $data; flush $ch }
    set reply ""
    set deadline [expr {[clock milliseconds] + $timeout_ms}]
    while {[string length $reply] < $n && [clock milliseconds] < $deadline} {
        if {[catch {append reply [read $ch [expr {$n - [string length $reply]}]]}]} { after 2 }
        if {[string length $reply] < $n} { after 2 }
    }
    return $reply
}
