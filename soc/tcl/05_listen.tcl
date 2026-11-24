# Capture whatever the firmware prints on the USB serial port for a few seconds into soc/logs/uart.txt.
# Optional globals before sourcing:  set soc_com COM4 ; set soc_baud 250000 ; set soc_seconds 6
source [file join [file dirname [file normalize [info script]]] common.tcl]
soc_run 05_listen {
    set seconds [expr {[info exists ::soc_seconds] ? $::soc_seconds : 6}]
    set ch [soc_uart_open]
    set data [soc_xfer $ch "" 100000 [expr {1000 * $seconds}]]
    close $ch
    soc_log "  received [string length $data] bytes"
    set out [open $::soc_dir/logs/uart.txt wb]; puts -nonewline $out $data; close $out
    foreach l [split $data "\n"] { if {[string trim $l] ne ""} { soc_log "  | [string trim $l]" } }
}
