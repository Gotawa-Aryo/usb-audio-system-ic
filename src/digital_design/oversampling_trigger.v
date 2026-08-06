`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 12.06.2026 16:56:05
// Design Name: 
// Module Name: oversampling_trigger
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


module oversampling_trigger(
        input  wire clk60mhz,
        input  wire reset_n,
        output wire sig48khz
    );
    
    reg  [10:0] counter;
    
    always @(posedge clk60mhz) begin
        if (!reset_n) begin
            counter = 11'h000;
        end else begin
            if (sig48khz) begin
                counter = 11'h000;
            end else begin
                counter = counter + 11'h001;
            end
        end
    end
    
    assign sig48khz = (counter == 11'd1249);
endmodule
