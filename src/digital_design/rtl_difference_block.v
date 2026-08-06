`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 03.08.2026 12:03:00
// Design Name: 
// Module Name: rtl_difference_block
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


module rtl_difference_block(
        input  wire signed [17:0] A,
        input  wire signed [17:0] B,
        output wire signed [17:0] S
    );
    
    assign S = A - B;
endmodule
