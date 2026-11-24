`timescale 1ns / 1ps

module systolic_2x2_tst;
    logic clk = 1'b0;
    logic rst;
    logic signed [7:0] A_in_row0, A_in_row1, B_in_col0, B_in_col1;
    logic valid_a_row0, valid_a_row1, valid_b_col0, valid_b_col1;
    logic signed [31:0] PE_00_sum, PE_01_sum, PE_10_sum, PE_11_sum;

    // A nonzero value on an invalid lane should have no effect on any sum.
    localparam logic signed [7:0] INVALID_DATA = 8'sd99;

    systolic_2x2 dut (
        .clk(clk),
        .rst(rst),
        .A_in_row0(A_in_row0),
        .A_in_row1(A_in_row1),
        .B_in_col0(B_in_col0),
        .B_in_col1(B_in_col1),
        .valid_a_row0(valid_a_row0),
        .valid_a_row1(valid_a_row1),
        .valid_b_col0(valid_b_col0),
        .valid_b_col1(valid_b_col1),
        .PE_00_sum(PE_00_sum),
        .PE_01_sum(PE_01_sum),
        .PE_10_sum(PE_10_sum),
        .PE_11_sum(PE_11_sum)
    );

    always #5 clk = ~clk;

    task automatic drive_inputs(
        input logic signed [7:0] a_row0, a_row1, b_col0, b_col1,
        input logic [3:0] lane_valid
    );
        A_in_row0 = a_row0;
        A_in_row1 = a_row1;
        B_in_col0 = b_col0;
        B_in_col1 = b_col1;
        // Valid bits follow the same lane order as the data arguments.
        {valid_a_row0, valid_a_row1, valid_b_col0, valid_b_col1} = lane_valid;
    endtask

    task automatic check_sums(
        input string phase,
        input logic signed [31:0] expected_00, expected_01, expected_10, expected_11
    );
        if (PE_00_sum !== expected_00)
            $fatal(1, "%s: PE00 expected %0d, got %0d", phase, expected_00, PE_00_sum);
        if (PE_01_sum !== expected_01)
            $fatal(1, "%s: PE01 expected %0d, got %0d", phase, expected_01, PE_01_sum);
        if (PE_10_sum !== expected_10)
            $fatal(1, "%s: PE10 expected %0d, got %0d", phase, expected_10, PE_10_sum);
        if (PE_11_sum !== expected_11)
            $fatal(1, "%s: PE11 expected %0d, got %0d", phase, expected_11, PE_11_sum);
    endtask

    initial begin
        rst = 1'b1;
        drive_inputs(0, 0, 0, 0, 4'b0000);
        @(negedge clk);
        check_sums("Initial reset", 0, 0, 0, 0);
        rst = 1'b0;

        // A = [[2, 3], [-3, 1]], B = [[4, 1], [5, 2]]
        // Drive at each falling edge and check after the intervening rising edge.

        // Edge 1: A00 and B00 meet at PE00.
        drive_inputs(2, INVALID_DATA, 4, INVALID_DATA, 4'b1010);
        @(negedge clk);
        check_sums("Feed edge 1", 8, 0, 0, 0);

        // Edge 2: PE00 finishes, and PE01 and PE10 start.
        drive_inputs(3, -3, 5, 1, 4'b1111);
        @(negedge clk);
        check_sums("Feed edge 2", 23, 2, -12, 0);

        // Edge 3: PE01 and PE10 finish, and PE11 starts.
        drive_inputs(INVALID_DATA, 1, INVALID_DATA, 2, 4'b0101);
        @(negedge clk);
        check_sums("Feed edge 3", 23, 8, -7, -3);

        // Edge 4: the last operands are already inside the array.
        drive_inputs(INVALID_DATA, INVALID_DATA, INVALID_DATA, INVALID_DATA, 4'b0000);
        @(negedge clk);
        check_sums("Final result", 23, 8, -7, -1);

        @(negedge clk);
        check_sums("Idle cycle holds the result", 23, 8, -7, -1);

        rst = 1'b1;
        @(negedge clk);
        check_sums("Reset after multiplication", 0, 0, 0, 0);

        $display("PASS: systolic_2x2 produced [[23, 8], [-7, -1]] and passed all timing and reset checks.");
        $finish;
    end
endmodule
