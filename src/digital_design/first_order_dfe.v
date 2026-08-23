`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: first_order_dfe
//
// Block 1.4 "Delta-Sigma DAC Modulator" of Figure 3, "XLR8_2026_Chipathon
// Schematic Review". Port names follow that figure.
//
// First-order delta-sigma modulator. WR_DATA is a 16-bit SIGNED PCM sample, the
// format UAC 1.0 delivers, so 16'h0000 is silence and the full-scale range is
// -32768 .. +32767. The 1-bit output density for a steady input x settles at
//
//     d(x) = (x + 32768) / 65535
//
// so silence gives a 50 % duty bitstream. Running at 60 MHz against a 48 kHz
// sample rate gives the 1250x oversampling quoted in the Technical Specification.
//
// MODULATOR_OUT leaves the chip on DAC_MOD_OUT_L and is strapped on the board to
// DAC_FB_IN_L, which drives the analog low-pass filter (block 1.5).
//////////////////////////////////////////////////////////////////////////////////


module first_order_dfe(
        input  wire         SYS_CLK_60M,
        input  wire         RESET_N,
        input  wire  [15:0] WR_DATA,
        output wire         MODULATOR_OUT
    );

    wire [17:0] diff_sig;
    wire [17:0] add_sig;
    reg  [17:0] reg_sig;
    wire [17:0] ddc_sig;

    // 16-bit signed sample widened to the 18-bit integrator width
    rtl_difference_block diff_1 (
        .A({{2{WR_DATA[15]}}, WR_DATA}),        // input wire [17 : 0] A
        .B(ddc_sig),                            // input wire [17 : 0] B
        .S(diff_sig)                            // output wire [17 : 0] S
    );

    rtl_adder_block add_1 (
        .A(diff_sig),   // input wire [17 : 0] A
        .B(reg_sig),    // input wire [17 : 0] B
        .S(add_sig)     // output wire [17 : 0] S
    );

    always @(posedge SYS_CLK_60M or negedge RESET_N) begin
        if (!RESET_N) begin
            reg_sig <= 18'h0_0000;
        end else begin
            reg_sig <= add_sig;
        end
    end

    // 1-bit feedback DAC: -32768 when the integrator is negative, +32767 when it is not
    assign ddc_sig = reg_sig[17] ? 18'h3_8000 : 18'h0_7FFF;

    assign MODULATOR_OUT = RESET_N ? (reg_sig[17] ? 1'b0 : 1'b1) : 1'b0;
endmodule
