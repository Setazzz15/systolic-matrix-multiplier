`timescale 1ns / 1ps

module systolic_controller #(
    parameter int N     = 2,  // Physical array has N rows and N columns of PEs.
    parameter int K_MAX = 75,  // Maximum number of products per PE in one job.
    localparam int K_WIDTH = $clog2(K_MAX + 1)
) (
    input  logic clk,
    input  logic rst,
    input  logic start,
    input  logic [K_WIDTH-1:0] k_len,

    input  logic signed [7:0] A [0:N-1][0:K_MAX-1],
    input  logic signed [7:0] B [0:K_MAX-1][0:N-1],

    output logic busy,
    output logic done,
    output logic signed [31:0] C [0:N-1][0:N-1]
);

    // Save the operands and length together when a job starts.
    logic signed [7:0] a_reg [0:N-1][0:K_MAX-1];
    logic signed [7:0] b_reg [0:K_MAX-1][0:N-1];
    logic [K_WIDTH-1:0] k_active;

    // The last product travels N-1 steps right and N-1 steps down
    // before the bottom-right PE has both operands.
    localparam int DRAIN_STEPS = 2 * (N - 1);
    localparam int MAX_DONE_COUNT = K_MAX + DRAIN_STEPS;
    logic [$clog2(MAX_DONE_COUNT + 1)-1:0] counter;

    // One A lane enters each row from the left.
    // One B lane enters each column from the top.
    logic signed [7:0] a_lane [0:N-1];
    logic signed [7:0] b_lane [0:N-1];
    logic lane_valid [0:N-1];

    logic accept_start;
    logic array_rst;

    assign accept_start = start && !busy && (k_len >= 1) && (k_len <= K_MAX);
    assign array_rst    = rst || accept_start;

    Systolic_NxN #(
        .N(N)
    ) NxNarray (
        .clk     (clk),
        .rst     (array_rst),
        .a_in    (a_lane),
        .valid_a (lane_valid),
        .b_in    (b_lane),
        .valid_b (lane_valid),
        .PE      (C)
    );

    always_ff @(posedge clk) begin
        if (rst) begin
            busy       <= 1'b0;
            done       <= 1'b0;
            counter    <= '0;
            k_active   <= '0;
            lane_valid <= '{default: 1'b0};
        end else begin
            // done pulses for one clock when the entire output tile is ready.
            done <= 1'b0;

            if (accept_start) begin
                a_reg      <= A;
                b_reg      <= B;
                k_active   <= k_len;
                counter    <= '0;
                busy       <= 1'b1;
                lane_valid <= '{default: 1'b0};

            end else if (busy) begin
                for (int i = 0; i < N; i++) begin
                    int k;

                    // Lane i starts i clocks after lane 0.
                    // At counter=2, lane 0 sends term 2, lane 1 sends term 1.
                    k = int'(counter) - i;

                    if (k >= 0 && k < int'(k_active)) begin
                        a_lane[i]     <= a_reg[i][k];
                        b_lane[i]     <= b_reg[k][i];
                        lane_valid[i] <= 1'b1;
                    end else begin
                        // Data on this lane is ignored whenever valid is low.
                        lane_valid[i] <= 1'b0;
                    end
                end

                // The lane values above are registered. The PEs sample them
                // on the following edge. At this count, the bottom-right PE
                // registers its final sum on the same edge that raises done.
                if (int'(counter) == int'(k_active) + DRAIN_STEPS) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                end else begin
                    counter <= counter + 1'b1;
                end
            end
        end
    end

endmodule