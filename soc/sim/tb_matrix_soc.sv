`timescale 1ns / 1ps
// Full-system testbench for the matrix_soc block design.
// It only drives the clock and reset, then listens to the UART pin like a PC would.
//   firmware v1 prints test lines and finally "END ALL PASS"
//   firmware v2 prints "SELFTEST PASS ..." and then "READY"
module tb_matrix_soc;
    logic sysclk = 1'b0;
    logic ext_reset_in_0 = 1'b1;   // BTN0 held down at power-up
    logic uart_txd_in = 1'b1;      // PC -> FPGA line idles high
    wire  uart_rxd_out;            // FPGA -> PC

    always #41.667 sysclk = ~sysclk;             // 12 MHz
    initial #2000 ext_reset_in_0 = 1'b0;         // release the button after 2 us

    matrix_soc_wrapper dut (
        .sysclk         (sysclk),
        .ext_reset_in_0 (ext_reset_in_0),
        .uart_rxd_out   (uart_rxd_out),
        .uart_txd_in    (uart_txd_in)
    );

    // UART receiver. The first character sent is 'S' (0x53): its start bit is followed
    // by a 1, so the first low pulse lasts exactly one bit. Measure it instead of assuming a baud rate.
    realtime bit_time = 0;
    string   line = "";
    logic [7:0] ch;
    bit      selftest_ok = 0;
    initial begin
        realtime t0;
        @(negedge ext_reset_in_0);
        wait (uart_rxd_out === 1'b1);
        @(negedge uart_rxd_out); t0 = $realtime;
        @(posedge uart_rxd_out); bit_time = $realtime - t0;
        $display("[%0t] UART bit time %0.1f ns (about %0d baud)", $time, bit_time, int'(1.0e9 / bit_time));
        #(bit_time * 0.5);                         // middle of data bit 0, which we already know is 1
        ch[0] = 1'b1;
        for (int i = 1; i < 8; i++) begin #(bit_time); ch[i] = uart_rxd_out; end
        #(bit_time);                               // stop bit
        line = {line, string'(ch)};
        forever begin
            @(negedge uart_rxd_out);
            #(bit_time * 1.5);
            for (int i = 0; i < 8; i++) begin ch[i] = uart_rxd_out; #(bit_time); end
            if (ch == 8'h0a) begin
                $display("[%0t] UART: %s", $time, line);
                if (line.len() >= 13 && line.substr(0, 12) == "SELFTEST PASS") selftest_ok = 1;
                if (line == "READY" || (line.len() >= 3 && line.substr(0, 2) == "END")) begin
                    if (line == "END ALL PASS" || (line == "READY" && selftest_ok)) $display("tb_matrix_soc PASS");
                    else $display("tb_matrix_soc FAIL");
                    $finish;
                end
                line = "";
            end else if (ch != 8'h0d) line = {line, string'(ch)};
        end
    end

    initial begin
        #900ms;
        $display("tb_matrix_soc TIMEOUT, partial line: %s", line);
        $finish;
    end
endmodule
