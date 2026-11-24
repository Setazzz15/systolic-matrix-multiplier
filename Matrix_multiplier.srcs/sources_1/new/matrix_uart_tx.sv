`timescale 1ns / 1ps

// Stream four signed 32-bit results as a line of 32 hex digits over USB serial.
module matrix_uart_tx (
    input logic clk, rst, done,
    input logic signed [31:0] C [0:1][0:1],
    output wire tx
);
    localparam int CLOCKS_PER_BIT = 104; // 12 MHz / 115200, rounded
    logic [$clog2(CLOCKS_PER_BIT)-1:0] baud_count;
    logic [9:0] frame; // Transmit from bit 0: start, eight data bits, then stop.
    logic [3:0] bits_left;
    logic [127:0] payload;
    logic [5:0] digits_left;
    logic sending_line;
    wire [3:0] digit = payload[127:124];
    wire [7:0] hex_char = (digit < 10) ? (8'h30 + digit) : (8'h41 + digit - 8'd10);
    assign tx = frame[0];

    always_ff @(posedge clk) begin
        if (rst) begin
            frame        <= '1; // UART idles high.
            bits_left    <= '0;
            baud_count   <= '0;
            sending_line <= 1'b0;
            digits_left  <= '0;
            payload      <= '0;
        end else if (done) begin
            // Capture all entries together, in row order.
            payload      <= {C[0][0], C[0][1], C[1][0], C[1][1]};
            digits_left  <= 6'd32;
            sending_line <= 1'b1;
            // Start a fresh line even if a reset interrupted the previous message.
            frame        <= {1'b1, 8'h0a, 1'b0};
            bits_left    <= 4'd10;
            baud_count   <= '0;
        end else if (bits_left != 0) begin
            if (baud_count == CLOCKS_PER_BIT - 1) begin
                frame      <= {1'b1, frame[9:1]};
                bits_left  <= bits_left - 1'b1;
                baud_count <= '0;
            end else begin
                baud_count <= baud_count + 1'b1;
            end
        end else if (sending_line) begin
            bits_left <= 4'd10;
            if (digits_left != 0) begin
                frame       <= {1'b1, hex_char, 1'b0};
                payload     <= {payload[123:0], 4'b0};
                digits_left <= digits_left - 1'b1;
            end else begin
                frame        <= {1'b1, 8'h0a, 1'b0};
                sending_line <= 1'b0;
            end
        end
    end
endmodule
