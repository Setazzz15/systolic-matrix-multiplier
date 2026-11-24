`timescale 1ns / 1ps

module fpga_top (
    input  logic       sysclk, // Cmod A7 12 MHz clock
    input  logic [1:0] btn,    // btn[0] resets, btn[1] starts a multiplication
    output logic [1:0] led,    // led[0] means pass, led[1] means fail
    output wire        uart_rxd_out // FPGA transmit pin on the USB serial bridge
);
    // Repeat the original three operand pairs 25 times for a 75-term dot product.
    localparam int JOB_K = 75;
    localparam logic [$clog2(JOB_K + 1)-1:0] K_LEN = JOB_K;
    localparam logic signed [7:0] A_PATTERN [0:1][0:2] =
        '{'{1, 2, 3}, '{-1, 0, 2}};
    localparam logic signed [7:0] B_PATTERN [0:2][0:1] =
        '{'{1, 2}, '{3, 4}, '{5, 6}};

    wire signed [7:0] A_TEST [0:1][0:JOB_K-1];
    wire signed [7:0] B_TEST [0:JOB_K-1][0:1];

    for (genvar k = 0; k < JOB_K; k++) begin : demo_terms
        for (genvar i = 0; i < 2; i++) begin : demo_lanes
            assign A_TEST[i][k] = A_PATTERN[i][k % 3];
            assign B_TEST[k][i] = B_PATTERN[k % 3][i];
        end
    end

    // Both buttons arrive asynchronously. Sample each through two flip-flops.
    // Initializing the reset bit high also resets the design after configuration.
    (* ASYNC_REG = "TRUE" *) logic [1:0] btn_meta = 2'b01;
    (* ASYNC_REG = "TRUE" *) logic [1:0] btn_sync = 2'b01;
    always_ff @(posedge sysclk) begin
        btn_meta <= btn;
        btn_sync <= btn_meta;
    end
    wire rst = btn_sync[0];

    // Accept a change after 10 ms at 12 MHz so switch bounce can't launch extra jobs.
    localparam int DEBOUNCE_CYCLES = 120_000;
    logic [$clog2(DEBOUNCE_CYCLES)-1:0] stable_count;
    logic start_button_down;
    logic start;
    always_ff @(posedge sysclk) begin
        if (rst) begin
            stable_count      <= '0;
            start_button_down <= 1'b0;
            start             <= 1'b0;
        end else begin
            start <= 1'b0;
            if (btn_sync[1] == start_button_down) begin
                stable_count <= '0;
            end else if (stable_count == DEBOUNCE_CYCLES - 1) begin
                stable_count      <= '0;
                start_button_down <= btn_sync[1];
                start             <= btn_sync[1]; // One pulse on a press.
            end else begin
                stable_count <= stable_count + 1'b1;
            end
        end
    end

    logic busy, done;
    logic signed [31:0] C [0:1][0:1];
    systolic_controller #(.N(2), .K_MAX(JOB_K)) controller (
        .clk   (sysclk),
        .rst   (rst),
        .start (start),
        .k_len (K_LEN),
        .A     (A_TEST),
        .B     (B_TEST),
        .busy  (busy),
        .done  (done),
        .C     (C)
    );

    // A debounced button can start a new job only after the previous line has been sent.
    matrix_uart_tx result_uart (
        .clk  (sysclk),
        .rst  (rst),
        .done (done),
        .C    (C),
        .tx   (uart_rxd_out)
    );

    // The controller pulses done for one clock. Keep the verdict visible
    // until reset or the next accepted start.
    always_ff @(posedge sysclk) begin
        if (rst || (start && !busy))
            led <= 2'b00;
        else if (done) begin
            // Each dot product is 25 times its original three-term result.
            if (C[0][0] == 550 && C[0][1] == 700 &&
                C[1][0] == 225 && C[1][1] == 250)
                led <= 2'b01;
            else
                led <= 2'b10;
        end
    end
endmodule
