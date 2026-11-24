`timescale 1ns / 1ps

module Systolic_NxN_tst;
    localparam int MAX_N = 4;
    logic clk = 1'b0;
    wire [MAX_N:1] case_done;

    always #5 clk = ~clk;

    for (genvar size = 1; size <= MAX_N; size++) begin : sizes
        systolic_nxn_case #(.N(size)) test_case (
            .clk(clk),
            .done(case_done[size])
        );
    end

    initial begin
        wait (&case_done);
        $display("PASS: Systolic_NxN passed for N=1 through N=%0d.", MAX_N);
        $finish;
    end
endmodule

module systolic_nxn_case #(
    parameter int N = 2
) (
    input  logic clk,
    output logic done
);
    // Feed cycles start at 0. The last term reaches PE[N-1][N-1] here.
    localparam int LAST_CYCLE = 3 * (N - 1);

    logic rst;
    logic signed [7:0] a_in [0:N-1];
    logic signed [7:0] b_in [0:N-1];
    logic valid_a [0:N-1];
    logic valid_b [0:N-1];
    wire signed [31:0] pe_sum [0:N-1][0:N-1];

    logic signed [7:0] matrix_a [0:N-1][0:N-1];
    logic signed [7:0] matrix_b [0:N-1][0:N-1];

    Systolic_NxN #(.N(N)) dut (
        .clk     (clk),
        .rst     (rst),
        .a_in    (a_in),
        .valid_a (valid_a),
        .b_in    (b_in),
        .valid_b (valid_b),
        .PE      (pe_sum)
    );

    task automatic drive_lanes(input int cycle);
        for (int lane = 0; lane < N; lane++) begin
            int k;
            k = cycle - lane;
            if (k >= 0 && k < N) begin
                a_in[lane] = matrix_a[lane][k];
                b_in[lane] = matrix_b[k][lane];
                valid_a[lane] = 1'b1;
                valid_b[lane] = 1'b1;
            end else begin
                // Nonzero data makes unintended multiplies visible during idle cycles.
                a_in[lane] = -8'sd53;
                b_in[lane] = 8'sd29;
                valid_a[lane] = 1'b0;
                valid_b[lane] = 1'b0;
            end
        end
    endtask

    task automatic check_sums(input string phase, input int cycle);
        for (int r = 0; r < N; r++) begin
            for (int c = 0; c < N; c++) begin
                int expected;
                expected = 0;
                for (int k = 0; k < N; k++) begin
                    // Including input skew, term k reaches PE[r][c] on cycle k+r+c.
                    if (r + c + k <= cycle)
                        expected += int'(matrix_a[r][k]) * int'(matrix_b[k][c]);
                end
                if (pe_sum[r][c] !== expected)
                    $fatal(1, "N=%0d %s cycle=%0d PE[%0d][%0d] expected %0d, got %0d",
                           N, phase, cycle, r, c, expected, pe_sum[r][c]);
            end
        end
    endtask

    initial begin
        done = 1'b0;
        rst = 1'b1;
        drive_lanes(-1);
        for (int r = 0; r < N; r++) begin
            for (int c = 0; c < N; c++) begin
                matrix_a[r][c] = 8'(5*r + 3*c - 7);
                matrix_b[r][c] = 8'(2*r - 4*c + 3);
            end
        end

        @(negedge clk);
        check_sums("initial reset", -1);
        rst = 1'b0;

        // Drive on falling edges. The DUT samples on the following rising edge.
        for (int cycle = 0; cycle <= LAST_CYCLE; cycle++) begin
            drive_lanes(cycle);
            @(negedge clk);
            check_sums("matrix multiply", cycle);
        end

        drive_lanes(-1);
        @(negedge clk);
        check_sums("idle hold", LAST_CYCLE);

        rst = 1'b1;
        @(negedge clk);
        check_sums("final reset", -1);

        $display("PASS: N=%0d, checked all %0d PEs on each feed cycle.", N, N*N);
        done = 1'b1;
    end
endmodule
