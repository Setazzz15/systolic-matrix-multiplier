namespace eval ::matrix_console {
    variable root [file dirname [file normalize [info script]]]
    if {![info exists port]} { variable port "" }
}

# Run once to add the new files to the project open in Vivado.
proc matrix_setup {} {
    set root $::matrix_console::root
    if {![string equal -nocase [file normalize [get_property DIRECTORY [current_project]]] $root]} {
        error "Open the Matrix_multiplier project before running matrix_setup."
    }
    set rtl [file join $root Matrix_multiplier.srcs sources_1 new matrix_uart_tx.sv]
    set xdc [file join $root cmod_matrix.xdc]
    foreach {fileset path} [list sources_1 $rtl constrs_1 $xdc] {
        if {![llength [get_files -quiet $path]]} { add_files -norecurse -fileset $fileset $path }
    }
    set_property top fpga_top [get_filesets sources_1]

}

proc matrix_stop {} {
    if {$::matrix_console::port ne ""} {
        close $::matrix_console::port
        set ::matrix_console::port ""
    }
}

# Each 8-digit hexadecimal word is one signed 32-bit result.
proc ::matrix_console::print_line {line} {
    if {![regexp {^[0-9A-Fa-f]{32}$} $line]} { return }
    set values {}
    foreach word [regexp -all -inline {[0-9A-Fa-f]{8}} $line] {
        scan $word %llx value
        if {$value >= 0x80000000} { set value [expr {$value - 0x100000000}] }
        lappend values $value
    }
    lassign $values c00 c01 c10 c11
    variable last_result
    set last_result [format {C = [[%d, %d], [%d, %d]]} $c00 $c01 $c10 $c11]
    # Publish serial callbacks through Vivado's message system so the GUI shows them.
    send_msg_id Matrix-1 INFO $last_result
}

proc matrix_last {} {
    if {[info exists ::matrix_console::last_result]} { return $::matrix_console::last_result }
    return "Waiting for a matrix. Press and release BTN1."
}

proc ::matrix_console::read_port {} {
    variable port
    if {[catch {
        while {[gets $port line] >= 0} { print_line $line }
        if {[eof $port]} { matrix_stop }
    } message]} {
        # The FTDI bridge can report a transient framing error during FPGA configuration.
        if {![catch {fconfigure $port -lasterror} flags] &&
            ([lsearch -exact $flags BREAK] >= 0 || [lsearch -exact $flags FRAME] >= 0)} { return }
        catch {matrix_stop}
        puts "Matrix serial connection closed ($message)"
    }
}

proc matrix_listen {com} {
    if {![regexp -nocase {^COM[0-9]+$} $com]} { error "Enter a Windows port such as COM5." }
    matrix_stop
    set path [format {\\.\%s} [string toupper $com]]
    set ch [open $path r+]
    if {[catch {
        fconfigure $ch -mode 115200,n,8,1 -handshake none -blocking 0 -translation lf -encoding ascii
        set ::matrix_console::port $ch
        fileevent $ch readable ::matrix_console::read_port
    } message]} {
        close $ch
        set ::matrix_console::port ""
        error $message
    }
    puts "Listening on $com. Press Start on the Cmod A7. Use matrix_stop to disconnect."
}
