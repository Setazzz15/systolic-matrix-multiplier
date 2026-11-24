module Systolic_NxN #(
    parameter int N = 2)(
    input logic clk,
    input logic rst,
    input logic signed [7:0] a_in [0:N-1],
    input logic valid_a [0:N-1],
    input logic signed [7:0] b_in [0:N-1],
    input logic valid_b [0:N-1],
    output logic signed [31:0] PE [0:N-1][0:N-1]
    );
    
    logic signed [7:0] a_next [0:N-1][0:N];
    logic signed [7:0] b_next [0:N][0:N-1];
    logic valid_a_next [0:N-1][0:N];
    logic valid_b_next [0:N][0:N-1];
    
    
    //assign the a_in to the entire left col 
    generate 
        for (genvar r = 0; r < N; r++) begin : left_col
            assign a_next[r][0] = a_in[r];
            assign valid_a_next[r][0] = valid_a[r];
        end
    
    //assign the b_in to the entire first top row 
        for (genvar c = 0; c < N; c++) begin : top_row
            assign b_next[0][c] = b_in[c];
            assign valid_b_next[0][c] = valid_b[c];
        end
        
     for (genvar r = 0; r < N; r++) begin: rows
        for (genvar c = 0; c < N; c++) begin : cols
            pe peNxN(
                .clk         (clk),
                .rst         (rst),
                .A_in        (a_next[r][c]),
                .valid_a     (valid_a_next[r][c]),
                .B_in        (b_next[r][c]),
                .valid_b     (valid_b_next[r][c]),
                .A_out       (a_next[r][c+1]),
                .valid_a_out (valid_a_next[r][c+1]),
                .B_out       (b_next[r+1][c]),
                .valid_b_out (valid_b_next[r+1][c]),
                .sum_out     (PE[r][c])
             );
       end
    end
    endgenerate
endmodule
   