`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 11/20/2026 03:02:21 PM
// Design Name: 
// Module Name: pe
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


module pe(
    input logic clk,
    input logic rst,
    input logic signed [7:0] A_in,
    input logic valid_a,
    input logic signed [7:0] B_in,
    input logic valid_b,
    output logic signed [7:0] A_out,
    output logic valid_a_out,
    output logic signed [7:0] B_out,
    output logic valid_b_out,
    output logic signed [31:0] sum_out
    );

    
    always_ff @(posedge clk) begin 
    
        if (rst) begin
            sum_out <= '0;
            A_out <= '0;
            valid_a_out <= 1'b0;
            B_out <= '0;
            valid_b_out <= 1'b0;
        end
        
        else begin
            valid_a_out <= valid_a;
            valid_b_out <= valid_b;
            A_out <= A_in;
            B_out <= B_in;
            
            if (valid_a && valid_b) 
                sum_out <= sum_out + A_in * B_in;
                
        end
    end
            
            
    
    
    
    
    
    
    
endmodule
