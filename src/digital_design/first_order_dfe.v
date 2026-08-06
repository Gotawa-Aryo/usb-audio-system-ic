`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 12.06.2026 05:23:00
// Design Name: 
// Module Name: first_order_dfe
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


module first_order_dfe(
        input  wire  [15:0] digital_in,
        input  wire         reset_n,
        input  wire         clk,
        output wire         bitstream_out
    );
    
    wire [17:0] diff_sig;
    wire [17:0] add_sig;
    reg  [17:0] reg_sig;
    wire [17:0] ddc_sig;
    
    rtl_difference_block diff_1 (
        .A({{2{digital_in[15]}}, digital_in}),  // input wire [17 : 0] A
        .B(ddc_sig),                            // input wire [17 : 0] B
        .S(diff_sig)                            // output wire [17 : 0] S
    );
    
    rtl_adder_block add_1 (
        .A(diff_sig),   // input wire [17 : 0] A
        .B(reg_sig),    // input wire [17 : 0] B
        .S(add_sig)     // output wire [17 : 0] S
    );
    
    always @(posedge clk) begin
        if (!reset_n) begin
            reg_sig = 18'h0_0000;
        end else begin
            reg_sig = add_sig;
        end
    end
    
    assign ddc_sig = reg_sig[17] ? 18'h3_8000 : 18'h0_7FFF;
    
    assign bitstream_out = reset_n ? (reg_sig[17] ? 1'b0 : 1'b1) : 1'b0;
endmodule
