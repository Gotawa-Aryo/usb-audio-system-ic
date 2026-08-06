`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 03.08.2026 12:08:47
// Design Name: 
// Module Name: rtl_digital_shifter
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


module rtl_digital_shifter(
        input  wire signed [17:0] A,
        output wire signed [17:0] S
    );
    
    assign S = A - 18'b11_1000_0000_0000_0000;
endmodule
