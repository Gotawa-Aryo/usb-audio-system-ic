
//--------------------------------------------------------------------------------------------------------
// Module  : usbfs_transaction
// Type    : synthesizable, IP's sub module
// Standard: Verilog 2001 (IEEE1364-2001)
// Function: USB device transaction level controller
//--------------------------------------------------------------------------------------------------------
// ep00_setup_cmd structure:
// |  wLength  |  wIndex   |  wValue   |  bRequest  |  bmRequestType                      |
// |  wLength  |  wIndex   |  wValue   |  bRequest  |  Direction  |  Type   |  Recipient  |
// |  [63:48]  |  [47:32]  |  [31:16]  |  [15:8]    |  [7]        |  [6:5]  |  [4:0]      |
//--------------------------------------------------------------------------------------------------------

module usbfs_transaction #(
    parameter [ 18*8-1:0] DESCRIPTOR_DEVICE = 0,                  // 18 byte capacity
    parameter [ 64*8-1:0] DESCRIPTOR_STR1   = 0,                  // 64 byte capacity
    parameter [ 64*8-1:0] DESCRIPTOR_STR2   = 0,                  // 64 byte capacity
    parameter [ 64*8-1:0] DESCRIPTOR_STR3   = 0,                  // 64 byte capacity
    parameter [ 64*8-1:0] DESCRIPTOR_STR4   = 0,                  // 64 byte capacity
    parameter [512*8-1:0] DESCRIPTOR_CONFIG = 0,                  // 512 byte capacity
    parameter       [9:0] DESCRIPTOR_CONFIG_LEN = 10'd512,        // bytes actually used; the rest of the mux folds away
    parameter       [7:0] EP00_MAXPKTSIZE   = 8'h20,              // endpoint 00 (control endpoint) packet byte length.
    parameter             EP01_ISOCHRONOUS  = 0                   // endpoint 01 is ISOCHRONOUS ?
) (
    input  wire        rstn,
    input  wire        clk,
    // RX packet-level signals
    input  wire [ 3:0] rp_pid,
    input  wire [ 3:0] rp_endp,
    input  wire        rp_byte_en,
    input  wire [ 7:0] rp_byte,
    input  wire        rp_fin,
    input  wire        rp_okay,
    // TX packet-level signals (device NEVER send token and special packet)
    output reg         tp_sta,
    output reg  [ 3:0] tp_pid,
    input  wire        tp_byte_req,
    output reg  [ 7:0] tp_byte,
    output reg         tp_fin_n,
    // 
    output reg         sot,            // detect a start of USB-transfer
    output reg         sof,            // detect a start of USB-frame
    // endpoint 0 (control endpoint) command response interface
    output reg  [63:0] ep00_setup_cmd,
    output reg  [ 8:0] ep00_resp_idx,
    input  wire [ 7:0] ep00_resp,
    // endpoint 0 OUT data stage (the bytes that follow a SETUP with a host-to-device
    // data phase, e.g. an audio class SET_CUR). ep00_data_idx counts within the stage.
    output reg  [ 7:0] ep00_data_out,
    output reg         ep00_data_valid,
    output reg  [ 8:0] ep00_data_idx,
    // endpoint 0x01 data output (the only non-control endpoint this device declares)
    output reg  [ 7:0] ep01_data,
    output reg         ep01_valid,
    // Packet validity for endpoint 0x01. Payload bytes are forwarded on ep01_valid as they
    // arrive, before the CRC16 is known, so the consumer must treat them as speculative:
    // ep01_commit pulses when the packet checked out, ep01_abort when it did not.
    output reg         ep01_commit,
    output reg         ep01_abort
);



initial tp_sta   = 1'b0;
initial tp_pid   = 4'h0;
initial tp_byte  = 8'h0;
initial tp_fin_n = 1'b0;
initial sot = 1'b0;
initial sof = 1'b0;
initial ep00_setup_cmd = 64'h0;
initial ep00_resp_idx  = 9'h0;
initial ep01_data   = 8'h0;
initial ep01_valid  = 1'b0;
initial ep01_commit = 1'b0;
initial ep01_abort  = 1'b0;



localparam [3:0] PID_OUT    = 4'h1;
localparam [3:0] PID_IN     = 4'h9;
localparam [3:0] PID_SETUP  = 4'hD;
localparam [3:0] PID_SOF    = 4'h5;
localparam [3:0] PID_DATA0  = 4'h3;
localparam [3:0] PID_DATA1  = 4'hB;
//localparam [3:0] PID_DATA2  = 4'h7;  // unused in USB 1.1
//localparam [3:0] PID_MDATA  = 4'hF;  // unused in USB 1.1
localparam [3:0] PID_ACK    = 4'h2;
localparam [3:0] PID_NAK    = 4'hA;
//localparam [3:0] PID_STALL  = 4'hE;  // unused in this USB 1.1 device core
//localparam [3:0] PID_NYET   = 4'h6;  // unused in USB 1.1



reg [ 9:0] tp_cnt = 10'h0;

reg [ 3:0] endp = 4'h0;

reg        ep00_setup = 1'b0;
reg [ 8:0] ep00_data_cnt = 9'h0;
reg [15:0] ep00_total = 16'h0;
reg [ 7:0] ep00_data  = 8'h0;
reg        ep00_data1 = 1'b0;

// Endpoint 0 is the only IN endpoint. A headphone has nothing to send.



//-------------------------------------------------------------------------------------------------------------------------------------
// main
//-------------------------------------------------------------------------------------------------------------------------------------
always @ (posedge clk or negedge rstn)
    if (~rstn) begin
        tp_sta   <= 1'b0;
        tp_pid   <= 4'h0;
        tp_byte  <= 8'h0;
        tp_fin_n <= 1'b0;
        
        tp_cnt <= 10'h0;
        endp   <= 4'h0;
        ep00_setup <= 1'b0;
        ep00_total <= 16'h0;
        ep00_data1 <= 1'b0;
        
        ep00_resp_idx <= 9'h0;
    end else begin
        tp_sta <= 1'b0;
        if (rp_fin & rp_okay) begin                                                                  // recv a packet
            if         (rp_pid == PID_SETUP) begin                                                   //   recv SETUP token
                endp <= rp_endp;                                                                     //
                if (rp_endp == 4'd0) begin                                                           //
                    ep00_setup <= 1'b1;                                                              //
                    ep00_data1 <= 1'b1;                                                              //
                end                                                                                  //
            end else if (rp_pid == PID_OUT) begin                                                    //   recv OUT token
                endp <= rp_endp;                                                                     //
                if (rp_endp == 4'd0)                                                                 //
                    ep00_setup <= 1'b0;                                                              //
            end else if (rp_pid == PID_IN) begin                                                     //   recv IN token
                endp <= rp_endp;                                                                     //
                tp_sta <= 1'b1;                                                                      //
                tp_pid <= PID_NAK;                                                                   //     send NAK by default
                tp_cnt <= 10'h0;                                                                     //     send len = 0 by default
                if (rp_endp == 4'd0) begin                                                           //     if IN ENDP=0
                    ep00_setup <= 1'b0;                                                              //
                    tp_pid <= ep00_data1 ? PID_DATA1 : PID_DATA0;                                    //       send DATA1 or DATA0
                    if (ep00_total >= {8'h0,EP00_MAXPKTSIZE}) begin                                  //
                        tp_cnt <= {2'h0, EP00_MAXPKTSIZE};                                           //
                        ep00_total <= ep00_total - {8'h0,EP00_MAXPKTSIZE};                           //
                    end else begin                                                                   //
                        tp_cnt <= {2'h0, ep00_total[7:0]};                                           //
                        ep00_total <= 16'h0;                                                         //
                    end                                                                              //
                end                                                                                  //     IN to any other endpoint stays NAKed
            end else if ( rp_pid == PID_ACK ) begin                                                  //    recv ACK handshake
                if (endp == 4'd0)
                    ep00_data1 <= ~ep00_data1;                                                       //       DATA0/1 flop
            end else if (rp_pid == PID_DATA0 || rp_pid == PID_DATA1) begin                           //   recv packet is DATA0 or DATA1
                if (endp == 4'd0) begin                                                              //     previous token (OUT or setup) is endpoint 00 
                    ep00_total <= 16'h0;                                                             //
                    if (ep00_setup) begin                                                            //       if last token = SETUP, device has received a 8byte SETUP command
                        if (ep00_setup_cmd[7])                                                       //
                            ep00_total <= ep00_setup_cmd[63:48];                                     //
                        ep00_resp_idx <= 9'h0;                                                       //
                    end
                end                                                                                  //
                tp_sta <= 1'b1;                                                                      //       send ACK by default
                tp_pid <= PID_ACK;                                                                   //       send ACK by default
                if (endp == 4'd1 && EP01_ISOCHRONOUS)                                                //     if this recv data packet corresponds to a ISOCHRONOUS OUT endpoint.
                    tp_sta <= 1'b0;                                                                  //       do not send ACK.
            end                                                                                      //
        end                                                                                          //
        if (tp_byte_req) begin
            tp_fin_n <= 1'b0;
            if ( (tp_cnt != 10'h0) && (endp == 4'd0) ) begin
                tp_cnt <= tp_cnt - 10'd1;
                tp_fin_n <= 1'b1;
                tp_byte <= ep00_data;
                ep00_resp_idx <= ep00_resp_idx + 9'd1;
            end
        end
    end




//-------------------------------------------------------------------------------------------------------------------------------------
// response IN data on endpoint 0 (control endpoint)
//-------------------------------------------------------------------------------------------------------------------------------------
localparam [31:0] DESCRIPTOR_STR0 = 32'h04_03_09_04;

always @ (posedge clk)
    casex(ep00_setup_cmd[31:0])
        32'hXXXX_08_80  : ep00_data <= (ep00_resp_idx>=  9'd1) ? 8'h00 : 8'h01;                                                   // GetConfiguration -> response configuration 1
        32'h01XX_06_80  : ep00_data <= (ep00_resp_idx>= 9'd18) ? 8'h00 : DESCRIPTOR_DEVICE[ (18 - 1 - ep00_resp_idx) * 8 +: 8 ];  // GetDescriptor -> response device descriptor
        32'h02XX_06_80  : ep00_data <= (ep00_resp_idx>=DESCRIPTOR_CONFIG_LEN) ? 8'h00 : DESCRIPTOR_CONFIG[ (512- 1 - ep00_resp_idx) * 8 +: 8 ];  // GetDescriptor -> response configuration descriptor
        32'h0300_06_80  : ep00_data <= (ep00_resp_idx>=  9'd4) ? 8'h00 : DESCRIPTOR_STR0  [ (4  - 1 - ep00_resp_idx) * 8 +: 8 ];  // GetDescriptor -> response string descriptor 0
        32'h0301_06_80  : ep00_data <= (ep00_resp_idx>= 9'd64) ? 8'h00 : DESCRIPTOR_STR1  [ (64 - 1 - ep00_resp_idx) * 8 +: 8 ];  // GetDescriptor -> response string descriptor 1
        32'h0302_06_80  : ep00_data <= (ep00_resp_idx>= 9'd64) ? 8'h00 : DESCRIPTOR_STR2  [ (64 - 1 - ep00_resp_idx) * 8 +: 8 ];  // GetDescriptor -> response string descriptor 2
        32'h0303_06_80  : ep00_data <= (ep00_resp_idx>= 9'd64) ? 8'h00 : DESCRIPTOR_STR3  [ (64 - 1 - ep00_resp_idx) * 8 +: 8 ];  // GetDescriptor -> response string descriptor 3
        32'h0304_06_80  : ep00_data <= (ep00_resp_idx>= 9'd64) ? 8'h00 : DESCRIPTOR_STR4  [ (64 - 1 - ep00_resp_idx) * 8 +: 8 ];  // GetDescriptor -> response string descriptor 4
        default          : ep00_data <= ep00_resp;                                                                                 // other : response by user
    endcase



//-------------------------------------------------------------------------------------------------------------------------------------
// process OUT data
//-------------------------------------------------------------------------------------------------------------------------------------
always @ (posedge clk or negedge rstn)
    if (~rstn) begin
        ep00_setup_cmd <= 64'h0;
        ep00_data_out   <= 8'h0;
        ep00_data_valid <= 1'b0;
        ep00_data_idx   <= 9'h0;
        ep00_data_cnt   <= 9'h0;
        ep01_data   <= 8'h0;
        ep01_valid  <= 1'b0;
        ep01_commit <= 1'b0;
        ep01_abort  <= 1'b0;
    end else begin
        ep00_data_valid <= 1'b0;
        ep01_data   <= 8'h0;
        ep01_valid  <= 1'b0;
        ep01_commit <= 1'b0;
        ep01_abort  <= 1'b0;

        // End of a received packet: publish or discard what was streamed out above.
        // Commit only for a good DATA packet addressed to endpoint 1. Abort on any bad
        // packet - aborting when nothing was written is harmless.
        if (rp_fin) begin
            if (~rp_okay)
                ep01_abort <= 1'b1;
            else if ((rp_pid == PID_DATA0 || rp_pid == PID_DATA1) && (endp == 4'd1))
                ep01_commit <= 1'b1;
        end
        if (rp_byte_en) begin
            if (endp == 4'd0) begin                                        // endpoint 0 OUT -> SETUP command
                if (ep00_setup) begin
                    ep00_setup_cmd <= {rp_byte, ep00_setup_cmd[63:8]};     // save 8 bytes SETUP command
                    ep00_data_cnt  <= 9'h0;                                // a new control transfer begins
                end else begin                                             // OUT data stage of a control transfer
                    ep00_data_out   <= rp_byte;
                    ep00_data_valid <= 1'b1;
                    ep00_data_idx   <= ep00_data_cnt;                      // index of THIS byte
                    ep00_data_cnt   <= ep00_data_cnt + 9'd1;
                end
            end else if (endp == 4'd1) begin                               // endpoint 01 OUT
                ep01_data  <= rp_byte;
                ep01_valid <= 1'b1;
            end
        end
    end



//-------------------------------------------------------------------------------------------------------------------------------------
// detect the IN/OUT packet border and the SOF
//-------------------------------------------------------------------------------------------------------------------------------------
always @ (posedge clk or negedge rstn)
    if (~rstn) begin
        sot <= 1'b0;
        sof <= 1'b0;
    end else begin
        sot <= 1'b0;
        sof <= 1'b0;
        if (rp_fin & rp_okay) begin
            if (rp_endp == 4'd0)
                sot <= (rp_pid == PID_SETUP);
            else
                sot <= (rp_pid == PID_IN || rp_pid == PID_OUT);
            sof <= (rp_pid == PID_SOF);
        end
    end



endmodule
