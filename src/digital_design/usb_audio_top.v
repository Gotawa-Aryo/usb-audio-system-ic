
//--------------------------------------------------------------------------------------------------------
// Module  : usb_audio_input_top
// Type    : synthesizable, IP's top
// Standard: Verilog 2001 (IEEE1364-2001)
// Function: A USB Full Speed (12Mbps) device, acting as a USB Audio Class 1.0 headphone
//           (host-to-device audio only). The capture path of the original IP has been
//           removed: this chip has no audio input pin, and the descriptors declare the
//           Basic Audio Device Headphone topology.
//--------------------------------------------------------------------------------------------------------

module usb_audio_top #(
    parameter DEBUG = "FALSE"         // whether to output USB debug info, "TRUE" or "FALSE"
) (
    input  wire        rstn,          // active-low reset, reset when rstn=0 (USB will unplug when reset), normally set to 1
    input  wire        clk,           // 60MHz is required
    // USB signals
    output wire        usb_dp_pull,   // connect to USB D+ by an 1.5k resistor
    inout              usb_dp,        // USB D+
    inout              usb_dn,        // USB D-
    // USB reset output
    output wire        usb_rstn,      // 1: connected , 0: disconnected (when USB cable unplug, or when system reset (rstn=0))
    // Left-channel PCM stream out to the FIFO Buffer (block 1.2 of Figure 3).
    // The chip only drives one analog channel, so only the left channel leaves this block.
    output wire        wr_en_l,       // WR_EN_L : write strobe, high for 1 cycle per sample
    output wire [15:0] data_l,        // DATA_L  : 16-bit signed mono PCM, valid when wr_en_l=1
    output wire        wr_commit_l,   // the packet those samples came from passed CRC16
    output wire        wr_abort_l,    // it did not - the FIFO must discard them
    // Frame marker for the Control Unit (block 1.3), which locks the sample clock to it.
    output wire        sof_out,       // 1 cycle pulse at each USB start-of-frame (1 kHz)
    // debug output info, only for USB developers, can be ignored for normally use. Please set DEBUG="TRUE" to enable these signals
    output wire        debug_en,      // when debug_en=1 pulses, a byte of debug info appears on debug_data
    output wire [ 7:0] debug_data,    //
    output wire        debug_uart_tx  // debug_uart_tx is the signal after converting {debug_en,debug_data} to UART (format: 115200,8,n,1). If you want to transmit debug info via UART, you can use this signal. If you want to transmit debug info via other custom protocols, please ignore this signal and use {debug_en,debug_data}.
);


wire       sof;

wire [7:0] out_data;      // data from USB device core (host-to-device)
wire       out_valid;
wire       out_commit;    // the packet out_data came from passed CRC16
wire       out_abort;     // it did not




//-------------------------------------------------------------------------------------------------------------------------------------
// audio output (host-to-device) : convert byte-stream to 16-bit mono PCM
//   The stream is mono, so a sample is two bytes: LSB then MSB. o_pcm_cnt tracks which of
//   the two is arriving and is re-zeroed on SOF, so a short or corrupt packet cannot leave
//   the byte phase inverted for the rest of the stream.
//-------------------------------------------------------------------------------------------------------------------------------------
reg         o_pcm_cnt = 1'b0;    // 0 = expecting LSB, 1 = expecting MSB
reg  [15:0] o_pcm     = 16'h0;   // 16-bit signed mono sample
reg         o_pcm_en  = 1'b0;    // when o_pcm_en=1, o_pcm valid
always @ (posedge clk or negedge usb_rstn)
    if (~usb_rstn) begin
        o_pcm_cnt <= 1'b0;
        o_pcm     <= 16'h0;
        o_pcm_en  <= 1'b0;
    end else begin
        o_pcm_en <= 1'b0;
        if (sof | out_abort) begin                    // new frame, or a rejected packet
            o_pcm_cnt <= 1'b0;                        // drop any half-assembled sample
        end else if (out_valid) begin
            o_pcm_cnt <= ~o_pcm_cnt;
            o_pcm     <= {out_data, o_pcm[15:8]};     // shift in from the high byte down
            o_pcm_en  <= o_pcm_cnt;                   // a full sample every 2 bytes
        end
    end



//-------------------------------------------------------------------------------------------------------------------------------------
// Feature Unit ID2 : Mute on Master, Volume on Center Front
//   BADD 5.3.3.1.10 requires both controls on a Headphone device, and 5.4.2.1 requires
//   SET_CUR/GET_CUR on Mute plus CUR/MIN/MAX/RES on Volume. Volume is a signed 16-bit
//   value in 1/256 dB units, as defined by Audio 1.0. The signal path is mono, so there
//   is a single Volume channel (Center Front, channel 1) - BADD Table 5-5.
//-------------------------------------------------------------------------------------------------------------------------------------
localparam [ 7:0] FU_ID       = 8'h02;
localparam [ 7:0] CS_MUTE     = 8'h01;
localparam [ 7:0] CS_VOLUME   = 8'h02;
localparam [ 7:0] REQ_SET_CUR = 8'h01;
localparam [ 7:0] REQ_GET_CUR = 8'h81;
localparam [ 7:0] REQ_GET_MIN = 8'h82;
localparam [ 7:0] REQ_GET_MAX = 8'h83;
localparam [ 7:0] REQ_GET_RES = 8'h84;

localparam [15:0] VOL_MIN = 16'hC000;      // -64.00 dB
localparam [15:0] VOL_MAX = 16'h0000;      //   0.00 dB
localparam [15:0] VOL_RES = 16'h0100;      //   1.00 dB per step
localparam [15:0] VOL_DEF = 16'hF000;      // -16.00 dB out of the box (BADD 4)

wire [63:0] ep00_setup_cmd;
wire [ 8:0] ep00_resp_idx;
wire [ 7:0] ep00_data_out;
wire        ep00_data_valid;
wire [ 8:0] ep00_data_idx;
reg  [ 7:0] ep00_resp;

wire [ 7:0] fu_rtype = ep00_setup_cmd[ 7: 0];
wire [ 7:0] fu_req   = ep00_setup_cmd[15: 8];
wire [ 7:0] fu_cn    = ep00_setup_cmd[23:16];   // wValue low  : channel number
wire [ 7:0] fu_cs    = ep00_setup_cmd[31:24];   // wValue high : control selector
wire [ 7:0] fu_unit  = ep00_setup_cmd[47:40];   // wIndex high : addressed unit

wire fu_get = (fu_rtype == 8'hA1) && (fu_unit == FU_ID);   // class, interface, device-to-host
wire fu_set = (fu_rtype == 8'h21) && (fu_unit == FU_ID);   // class, interface, host-to-device

reg         mute_master = 1'b0;
reg  [15:0] volume      = VOL_DEF;

wire [15:0] vol_sel = volume;

// GET responses, indexed by ep00_resp_idx exactly like the descriptor ROM
always @ (*) begin
    ep00_resp = 8'h00;
    if (fu_get) begin
        if (fu_cs == CS_MUTE) begin
            if (fu_req == REQ_GET_CUR)
                ep00_resp = {7'h0, mute_master};
        end else if (fu_cs == CS_VOLUME) begin
            case (fu_req)
                REQ_GET_CUR : ep00_resp = (ep00_resp_idx == 9'd0) ? vol_sel[7:0] : vol_sel[15:8];
                REQ_GET_MIN : ep00_resp = (ep00_resp_idx == 9'd0) ? VOL_MIN[7:0] : VOL_MIN[15:8];
                REQ_GET_MAX : ep00_resp = (ep00_resp_idx == 9'd0) ? VOL_MAX[7:0] : VOL_MAX[15:8];
                REQ_GET_RES : ep00_resp = (ep00_resp_idx == 9'd0) ? VOL_RES[7:0] : VOL_RES[15:8];
                default     : ep00_resp = 8'h00;
            endcase
        end
    end
end

// SET_CUR consumes the control OUT data stage
always @ (posedge clk or negedge usb_rstn)
    if (~usb_rstn) begin
        mute_master <= 1'b0;
        volume      <= VOL_DEF;
    end else if (ep00_data_valid && fu_set && (fu_req == REQ_SET_CUR)) begin
        if (fu_cs == CS_MUTE) begin
            if (ep00_data_idx == 9'd0)
                mute_master <= ep00_data_out[0];
        end else if (fu_cs == CS_VOLUME) begin
            if (ep00_data_idx == 9'd0) volume[ 7:0] <= ep00_data_out;
            else                       volume[15:8] <= ep00_data_out;
        end
    end



//-------------------------------------------------------------------------------------------------------------------------------------
// audio output (host-to-device) : left-channel stream out to the FIFO Buffer (block 1.2)
//   Samples are handed over as they are decoded, at the USB packet burst rate. Smoothing
//   that burst into a steady 48 ksps stream is the FIFO Buffer's job - Figure 3 shows one
//   buffer, and it is block 1.2. The 512-entry bufo array that used to sit here did the
//   same work a second time, and was 92 % of the chip's sequential cells.
//-------------------------------------------------------------------------------------------------------------------------------------
assign sof_out = sof;

assign wr_en_l     = o_pcm_en;
assign wr_commit_l = out_commit;
assign wr_abort_l  = out_abort;
assign data_l  = mute_master ? 16'h0000 : o_pcm;         // Mute Control gates the stream



//-------------------------------------------------------------------------------------------------------------------------------------
// USB full-speed core
//-------------------------------------------------------------------------------------------------------------------------------------
usbfs_core_top  #(
    .DESCRIPTOR_DEVICE  ( {  //  18 bytes available
        144'h12_01_00_02_00_00_00_20_9A_FB_9A_FB_00_01_01_02_00_01
    } ),
    .DESCRIPTOR_STR1    ( {  //  64 bytes available
        160'h14_03_54_00_65_00_61_00_6D_00_20_00_58_00_4C_00_52_00_38_00,     // "Team XLR8"
        352'h0
    } ),
    .DESCRIPTOR_STR2    ( {  //  64 bytes available
        240'h1E_03_58_00_4C_00_52_00_38_00_20_00_55_00_53_00_42_00_20_00_41_00_75_00_64_00_69_00_6F_00,   // "XLR8 USB Audio"
        272'h0
    } ),
    .DESCRIPTOR_STR3    ( {  //  64 bytes available
        304'h26_03_58_00_4C_00_52_00_38_00_20_00_48_00_65_00_61_00_64_00_70_00_68_00_6F_00_6E_00_65_00_20_00_4F_00_75_00_74_00,   // "XLR8 Headphone Out"
        208'h0
    } ),
    //-------------------------------------------------------------------------------------------------
    // Configuration block: USB-IF Basic Audio Device, Headphone topology HT1 (BADD section 5).
    //   Input Terminal ID1 (USB Streaming) -> Feature Unit ID2 -> Output Terminal ID3 (Headphones)
    // Mono, because the chip drives one analog channel. Declaring stereo made the host send
    // a right channel that was decoded and thrown away; mono halves the packet to 96 bytes and
    // lets the host do the downmix, so both channels of the source are actually heard.
    // wTotalLength = 111 = 9+9+41+9+9+7+11+9+7; class-specific AC block = 41 = 9+12+11+9.
    //-------------------------------------------------------------------------------------------------
    .DESCRIPTOR_CONFIG  ( {  // 512 bytes available
        72'h09_02_6F_00_02_01_00_80_32,               // configuration: 2 interfaces, bus powered, 100mA = one unit load (BADD 4.1)
        72'h09_04_00_00_00_01_01_01_02,               // standard AC interface, 0 endpoints, bInterfaceProtocol=0x01 M_HP_HT1
        72'h09_24_01_00_01_29_00_01_01,               // class-specific AC header, bcdADC=0x0100, wTotalLength=41, 1 streaming interface
        96'h0C_24_02_01_01_01_00_01_04_00_00_00,      // Input  Terminal ID1, USB Streaming (0x0101), mono, Center Front
        88'h0B_24_06_02_01_02_01_00_02_00_00,         // Feature Unit ID2 from ID1: Mute on Master, Volume on Center Front (BADD Table 5-5)
        72'h09_24_03_03_02_03_00_02_00,               // Output Terminal ID3, Headphones (0x0302), sourced from ID2
        72'h09_04_01_00_00_01_02_00_03,               // AS interface 1, alt 0: zero bandwidth (BADD 5.3.3.3.1)
        72'h09_04_01_01_01_01_02_00_03,               // AS interface 1, alt 1: one isochronous endpoint
        56'h07_24_01_01_00_01_00,                     // class-specific AS general: links Terminal ID1, bDelay=0, PCM
        88'h0B_24_02_01_01_02_10_01_80_BB_00,         // type I format: mono, 2 byte subframe, 16 bit, 48000 Hz
        72'h09_05_01_0D_60_00_01_00_00,               // endpoint 0x01 OUT, isochronous + synchronous (0x0D), 96 bytes, 1 per frame
        56'h07_25_01_00_00_00_00,                     // class-specific isochronous endpoint, no controls (BADD Table 5-20)
        3208'h0
    } ),
    .DESCRIPTOR_CONFIG_LEN ( 10'd111       ),
    .EP01_ISOCHRONOUS   ( 1                ),
    .DEBUG              ( DEBUG            )
) usbfs_core_i (
    .rstn               ( rstn             ),
    .clk                ( clk              ),
    .usb_dp_pull        ( usb_dp_pull      ),
    .usb_dp             ( usb_dp           ),
    .usb_dn             ( usb_dn           ),
    .usb_rstn           ( usb_rstn         ),
    .sot                (                  ),
    .sof                ( sof              ),
    .ep00_setup_cmd     ( ep00_setup_cmd   ),
    .ep00_resp_idx      ( ep00_resp_idx    ),
    .ep00_resp          ( ep00_resp        ),
    .ep00_data_out      ( ep00_data_out    ),
    .ep00_data_valid    ( ep00_data_valid  ),
    .ep00_data_idx      ( ep00_data_idx    ),
    .ep01_data          ( out_data         ),
    .ep01_valid         ( out_valid        ),
    .ep01_commit        ( out_commit       ),
    .ep01_abort         ( out_abort        ),
    .debug_en           ( debug_en         ),
    .debug_data         ( debug_data       ),
    .debug_uart_tx      ( debug_uart_tx    )
);


endmodule
