//--------------------------------------------------------------------------------------------------------
// Module  : fpga_top_usb_audio
// Type    : synthesizable, ic top
// Standard: Verilog 2001 (IEEE1364-2001)
// Function: USB Audio Class device whose received samples are forwarded into an async FIFO.
//           No DAC/I2S output (out of scope) - the FIFO read side is left available for a
//           downstream consumer to drain at its own clock rate.
//--------------------------------------------------------------------------------------------------------

module ic_top_usb_audio (
    input  wire         clk60mhz,       // connect to a 60MHz clock source
    input  wire         reset_n,        // external reset circuit
    output wire         usb_dp_pull,    // connect to USB D+ by an 1.5k resistor
    output wire         bitstream_out,  // connect to AFE (LPF, buffer, and power amplifier)
    inout               usb_dp,         // connect to USB D+
    inout               usb_dn          // connect to USB D-
);

    wire        sig48khz;
    wire [31:0] digital_sig;
    wire [17:0] digital_sig_shifted;
    wire [15:0] audio_data;
    
    //-------------------------------------------------------------------------------------------------------------------------------------
    // USB-UAC device + async FIFO
    //   The FIFO read side is left idle (rd_en = 0) at the top level - a future consumer
    //   (DAC, DSP, network sink, etc.) can be wired in here. For now the FIFO fills and
    //   holds the most recent samples, which is exactly what we want for the merge test.
    //-------------------------------------------------------------------------------------------------------------------------------------
    wire [15:0] audio_l, audio_r;            // USB-UAC loopback wires (mic <- speaker)
    wire        buffer_empty;
    
    usb_audio_top #(
        .DEBUG           ( "FALSE"             )
    ) u_usb_audio (
        .rstn            ( 1'b1                ),
        .clk             ( clk60mhz            ),
        // USB signals
        .usb_dp_pull     ( usb_dp_pull         ),
        .usb_dp          ( usb_dp              ),
        .usb_dn          ( usb_dn              ),
        .usb_rstn        ( usb_rstn_w          ),
        // UAC audio data
        .audio_en        (                     ),
        .audio_lo        ( audio_l             ),
        .audio_ro        ( audio_r             ),
        .audio_li        (                     ),
        .audio_ri        (                     ),
        // Async FIFO read side
        .fifo_rd_clk     ( clk60mhz            ),
        .fifo_rd_rstn    ( reset_n             ),
        .fifo_rd_en      ( sig48khz            ),
        .fifo_rd_data    ( digital_sig         ),
        .fifo_rd_empty   ( buffer_empty        ),
        // Debug
        .debug_en        (                     ),
        .debug_data      (                     ),
        .debug_uart_tx   (                     )
    );
    
    assign audio_data = buffer_empty ? 16'h8000 : {digital_sig_shifted[17], digital_sig_shifted[14:0]};

    oversampling_trigger the_trigger(
        .clk60mhz        ( clk60mhz            ),
        .reset_n         ( reset_n             ),
        .sig48khz        ( sig48khz            )
    );
    
    rtl_digital_shifter shifter_1 (
        .A({{2{digital_sig[15]}}, digital_sig}),    // input wire [17 : 0] A
        .S(digital_sig_shifted)                     // output wire [17 : 0] S
    );
    
    first_order_dfe the_dfe(
        .digital_in      ( audio_data          ),
        .reset_n         ( reset_n             ),
        .clk             ( clk60mhz            ),
        .bitstream_out   ( bitstream_out       )
    );

endmodule