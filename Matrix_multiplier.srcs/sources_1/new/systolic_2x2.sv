`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 11/20/2026 03:49:30 PM
// Design Name: 
// Module Name: systolic_2x2
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module systolic_2x2(
    input logic clk,
    input logic rst,
    input logic signed [7:0] A_in_row0,A_in_row1,B_in_col0,B_in_col1,
    input logic valid_a_row0,valid_a_row1,valid_b_col0,valid_b_col1,
    output logic signed [31:0] PE_00_sum,PE_01_sum,PE_10_sum,PE_11_sum

    );
    
    logic signed [7:0] a_00_to_01, a_10_to_11;
    logic signed [7:0] b_00_to_10, b_01_to_11;
    logic valid_a_00_to_01, valid_a_10_to_11;
    logic valid_b_00_to_10, valid_b_01_to_11;
    
    
    pe pe00(
        .clk (clk),
        .rst         (rst),
        .A_in        (A_in_row0),
        .valid_a     (valid_a_row0),
        .B_in        (B_in_col0),
        .valid_b     (valid_b_col0),
        .A_out       (a_00_to_01),
        .valid_a_out (valid_a_00_to_01),
        .B_out       (b_00_to_10),
        .valid_b_out (valid_b_00_to_10),
        .sum_out     (PE_00_sum)
        );
        
    pe pe01(
        .clk (clk),
        .rst         (rst),
        .A_in        (a_00_to_01),
        .valid_a     (valid_a_00_to_01),
        .B_in        (B_in_col1),
        .valid_b     (valid_b_col1),
        .A_out       (),
        .valid_a_out (),
        .B_out       (b_01_to_11),
        .valid_b_out (valid_b_01_to_11),
        .sum_out     (PE_01_sum)
        );
        
      pe pe10(
        .clk (clk),
        .rst         (rst),
        .A_in        (A_in_row1),
        .valid_a     (valid_a_row1),
        .B_in        (b_00_to_10),
        .valid_b     (valid_b_00_to_10),
        .A_out       (a_10_to_11),
        .valid_a_out (valid_a_10_to_11),
        .B_out       (),
        .valid_b_out (),
        .sum_out     (PE_10_sum)
        ); 
        
      pe pe11(
        .clk (clk),
        .rst         (rst),
        .A_in        (a_10_to_11),
        .valid_a     (valid_a_10_to_11),
        .B_in        (b_01_to_11),
        .valid_b     (valid_b_01_to_11),
        .A_out       (),
        .valid_a_out (),
        .B_out       (),
        .valid_b_out (),
        .sum_out     (PE_11_sum)
        );  
        
    
endmodule
