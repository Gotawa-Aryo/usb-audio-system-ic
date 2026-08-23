//--------------------------------------------------------------------------------------------------------
// Module  : ic_top_usb_audio
// Type    : synthesizable, ic top (digital submodule)
// Standard: Verilog 2001 (IEEE1364-2001)
// Function: XLR8 USB-to-Audio system, digital submodule.
//
//           Pin names, directions and internal block structure follow
//           "XLR8_2026_Chipathon Schematic Review":
//             Table 1  - Pin information
//             Figure 1 - XLR8 chip interface
//             Figure 3 - Internal construction of the USB-to-audio system
//
//           Figure 3 divides the chip along the DIGITAL / ANALOG boundary. This netlist is
//           everything on the digital side of that line:
//
//             1.1  USB Interface             -> usb_audio_top
//             1.2  FIFO Buffer               -> async_fifo, 16-bit
//             1.3  Control Unit              -> oversampling_trigger
//             1.4  Delta-Sigma DAC Modulator -> first_order_dfe
//
//           The analog submodule (1.5 Low-Pass Filter, 1.6 Power Amplifier) together with
//           its pins DAC_FB_IN_L and AUDIO_OUT_L is not part of this netlist. On the board
//           DAC_MOD_OUT_L is strapped back to DAC_FB_IN_L (Figure 2), which is what makes
//           the digital and analog halves independently replaceable.
//--------------------------------------------------------------------------------------------------------

module ic_top_usb_audio (
`ifdef USE_POWER_PINS
    inout  wire         VDD,            // [P] Positive power supply input
    inout  wire         VSS,            // [P] Ground reference
`endif
    output wire         USB_DP_PULL,    // [D] Control signal for enabling the 1.5 kOhm pull-up on USB D+
    inout               USB_DP,         // [D] USB Full-Speed D+ differential data line
    inout               USB_DN,         // [D] USB Full-Speed D- differential data line
    input  wire         SYS_CLK_60M,    // [D] Main 60 MHz system clock input
    output wire         DAC_MOD_OUT_L,  // [D] Left channel Delta-Sigma DAC modulator output bitstream
    input  wire         RESET_N         // [D] Active-low system global reset input
);

    //----------------------------------------------------------------------------------------------------
    // 1.1  USB Interface
    //      UAC 1.0 full-speed device. Emits the left-channel 16-bit signed PCM stream as
    //      {WR_EN_L, DATA_L} for the FIFO Buffer.
    //----------------------------------------------------------------------------------------------------
    wire        usb_rstn;               // 1 = enumerated, 0 = unplugged or held in reset
    wire        wr_en_l;                // Figure 3: USB Interface -> FIFO Buffer WR_EN
    wire [15:0] data_l;                 // Figure 3: USB Interface -> FIFO Buffer WR_DATA
    wire        sof;                    // USB Interface -> Control Unit, frame marker
    wire        wr_commit_l;            // the packet those samples came from passed CRC16
    wire        wr_abort_l;             // it did not - the FIFO discards them

    usb_audio_top #(
        .DEBUG           ( "FALSE"             )
    ) u_usb_audio (
        .rstn            ( RESET_N             ),   // Figure 3 routes RESET_N into every digital block
        .clk             ( SYS_CLK_60M         ),
        // USB signals
        .usb_dp_pull     ( USB_DP_PULL         ),
        .usb_dp          ( USB_DP              ),
        .usb_dn          ( USB_DN              ),
        .usb_rstn        ( usb_rstn            ),
        // Left-channel PCM stream out to the FIFO Buffer
        .wr_en_l         ( wr_en_l             ),
        .data_l          ( data_l              ),
        .wr_commit_l     ( wr_commit_l         ),
        .wr_abort_l      ( wr_abort_l          ),
        // Frame marker to the Control Unit
        .sof_out         ( sof                 ),
        // Debug
        .debug_en        (                     ),
        .debug_data      (                     ),
        .debug_uart_tx   (                     )
    );

    //----------------------------------------------------------------------------------------------------
    // 1.3  Control Unit
    //      Generates SIG_48K, the 48 kHz sample tick that drains the FIFO Buffer.
    //      The endpoint declares Isochronous Synchronous, so the tick is locked to the USB
    //      frame rather than free-running: 48 ticks per SOF interval, however long the host
    //      makes that interval. With no SOF it falls back to 60 MHz / 1250 = 48 kHz exactly.
    //
    //      The SOF connection from block 1.1 is not drawn in Figure 3; the figure needs
    //      updating to match.
    //----------------------------------------------------------------------------------------------------
    wire sig_48k;

    oversampling_trigger u_control_unit (
        .SYS_CLK_60M     ( SYS_CLK_60M         ),
        .RESET_N         ( RESET_N             ),
        .SOF             ( sof                 ),
        .SIG_48K         ( sig_48k             )
    );

    //----------------------------------------------------------------------------------------------------
    // 1.2  FIFO Buffer
    //      Absorbs the USB packet burst and is drained at exactly 48 kHz by the Control Unit.
    //      Writes are speculative until the packet's CRC16 is known: WR_COMMIT publishes them,
    //      WR_ABORT rewinds a packet that failed, so corrupt audio never reaches the modulator.
    //      This is now the only audio buffer in the chip. One 192-byte packet carries 48
    //      samples, so 128 entries is roughly 2.7 frames: enough for a whole packet to land
    //      before the drain starts, plus margin for host jitter.
    //      Both ports run off SYS_CLK_60M - the design is single-clock-domain (Technical
    //      Specification) and the gray-coded pointers are the "internal synchronization
    //      mechanism" that decouples the write and read strobes.
    //----------------------------------------------------------------------------------------------------
    wire [15:0] rd_data;
    wire        rd_empty;

    async_fifo #(
        .DATA_WIDTH      ( 16                  ),   // Figure 3: DATA_L / WR_DATA / RD_DATA are 16-bit
        .ADDR_WIDTH      ( 7                   )    // 128 entries, about 2.7 frames
    ) u_fifo_buffer (
        .wr_clk          ( SYS_CLK_60M         ),
        .wr_rst_n        ( RESET_N             ),
        .wr_en           ( wr_en_l             ),
        .wr_data         ( data_l              ),
        .wr_commit       ( wr_commit_l         ),   // publish only after CRC16 checks out
        .wr_abort        ( wr_abort_l          ),   // rewind a packet that failed
        .wr_full         (                     ),   // async_fifo drops writes while full
        .rd_clk          ( SYS_CLK_60M         ),
        .rd_rst_n        ( RESET_N             ),
        .rd_en           ( sig_48k             ),
        .rd_data         ( rd_data             ),
        .rd_empty        ( rd_empty            )
    );

    //----------------------------------------------------------------------------------------------------
    // 1.4  Delta-Sigma DAC Modulator
    //      Figure 3 takes RD_DATA straight into WR_DATA - no scaling or offset block in
    //      between. The modulator interprets WR_DATA as a 16-bit SIGNED sample, which is
    //      exactly the format UAC 1.0 delivers, so silence is 16'h0000.
    //----------------------------------------------------------------------------------------------------
    wire [15:0] modulator_in = rd_empty ? 16'h0000 : rd_data;   // underflow -> silence, not a DC rail

    first_order_dfe u_dac_modulator (
        .SYS_CLK_60M     ( SYS_CLK_60M         ),
        .RESET_N         ( RESET_N             ),
        .WR_DATA         ( modulator_in        ),
        .MODULATOR_OUT   ( DAC_MOD_OUT_L       )
    );

endmodule
