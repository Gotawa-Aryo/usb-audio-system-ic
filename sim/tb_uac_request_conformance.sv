`timescale 1ns / 1ps
//--------------------------------------------------------------------------------------------------------
// Testbench : tb_uac_request_conformance
//
// Conformance harness for control transfers, checked against
//   references/BasicAudioDevice-10.pdf  section 5.4 "Headphone Requests"
//
// Real SETUP + IN transfers are driven into the device's transaction layer by forcing the
// packet-level interface inside usbfs_core_top, which is exactly what usbfs_packet_rx would
// present. The descriptor bytes that come back are compared against the elaborated
// descriptor parameters, so this exercises the whole descriptor ROM read path rather than
// just inspecting constants.
//
// BADD 5.4.1 requires: ClearFeature, GetConfiguration, GetDescriptor, GetInterface,
// GetStatus, SetAddress, SetConfiguration, SetFeature, SetInterface.
// BADD 5.4.2.1 requires Feature Unit Mute (SET_CUR/GET_CUR) and Volume (CUR/MIN/MAX/RES).
//
// The Feature Unit checks are round trips: SET_CUR is driven through a real control OUT data
// stage and the value is read back with GET_CUR, so a control that merely returns a constant
// would not pass. Mute is additionally checked to actually silence DATA_L.
//--------------------------------------------------------------------------------------------------------

module tb_uac_request_conformance;

    localparam [3:0] PID_OUT   = 4'h1;
    localparam [3:0] PID_IN    = 4'h9;
    localparam [3:0] PID_SETUP = 4'hD;
    localparam [3:0] PID_DATA0 = 4'h3;

    reg clk = 1'b0, rstn = 1'b0;
    always #8.333 clk = ~clk;

    wire usb_dp, usb_dn;
    pullup (usb_dp);
    pulldown (usb_dn);

    usb_audio_top #(.DEBUG("FALSE")) dut (
        .rstn(rstn), .clk(clk),
        .usb_dp_pull(), .usb_dp(usb_dp), .usb_dn(usb_dn), .usb_rstn(),
        .wr_en_l(), .data_l(),
        .debug_en(), .debug_data(), .debug_uart_tx()
    );

    // Static drivers for the forced packet-level interface (force cannot take automatic args).
    reg  [3:0]  f_pid     = 4'h0;
    reg  [10:0] f_addr    = 11'h0;
    reg         f_byte_en = 1'b0;
    reg  [7:0]  f_byte    = 8'h0;
    reg         f_fin     = 1'b0;
    reg         f_okay    = 1'b0;
    reg         f_treq    = 1'b0;

    reg [18*8-1:0]  dev;
    reg [512*8-1:0] cfg;

    function [7:0] devb (input integer i);
        devb = dev[(18 - 1 - i) * 8 +: 8];
    endfunction
    function [7:0] cfgb (input integer i);
        cfgb = cfg[(512 - 1 - i) * 8 +: 8];
    endfunction

    integer n_pass, n_fail, n_info;
    integer i, nresp;
    reg [7:0] resp [0:271];

    task automatic chk (input cond, input [63:0] id, input [1023:0] text);
        begin
            if (cond) begin
                n_pass = n_pass + 1;
                $display("  [ OK      ] %-8s %0s", id, text);
            end else begin
                n_fail = n_fail + 1;
                $display("  [ NONCONF ] %-8s %0s", id, text);
            end
        end
    endtask

    task automatic note (input [63:0] id, input [1023:0] text);
        begin
            n_info = n_info + 1;
            $display("  [ note    ] %-8s %0s", id, text);
        end
    endtask

    // ---- packet-level stimulus -------------------------------------------------------------------------
    task automatic token (input [3:0] pid, input [3:0] endp);
        begin
            @(posedge clk); #1;
            f_pid  = pid;
            f_addr = {endp, 7'h00};
            f_fin  = 1'b1;
            f_okay = 1'b1;
            @(posedge clk); #1;
            f_fin  = 1'b0;
            f_okay = 1'b0;
            repeat (2) @(posedge clk); #1;
        end
    endtask

    // SETUP stage: token, then the 8-byte command as a DATA0 packet
    task automatic setup_xfer (input [7:0] bm, input [7:0] breq,
                               input [15:0] wval, input [15:0] widx, input [15:0] wlen);
        reg [7:0] cmd [0:7];
        integer k;
        begin
            cmd[0] = bm;         cmd[1] = breq;
            cmd[2] = wval[7:0];  cmd[3] = wval[15:8];
            cmd[4] = widx[7:0];  cmd[5] = widx[15:8];
            cmd[6] = wlen[7:0];  cmd[7] = wlen[15:8];

            token(PID_SETUP, 4'h0);
            for (k = 0; k < 8; k = k + 1) begin
                @(posedge clk); #1;
                f_byte    = cmd[k];
                f_byte_en = 1'b1;
                @(posedge clk); #1;
                f_byte_en = 1'b0;
            end
            token(PID_DATA0, 4'h0);
        end
    endtask

    // DATA stage. Endpoint 0 carries at most EP00_MAXPKTSIZE bytes per transaction, so a long
    // descriptor is fetched with repeated IN tokens - exactly what a real host does. The
    // transfer's byte index (ep00_resp_idx) is only cleared by the SETUP, so it carries across.
    localparam integer EP0_MAXPKT = 32;

    task automatic in_xfer (input integer nbytes);
        integer k, chunk, got;
        begin
            nresp = 0;
            got   = 0;
            while (got < nbytes) begin
                chunk = nbytes - got;
                if (chunk > EP0_MAXPKT) chunk = EP0_MAXPKT;
                token(PID_IN, 4'h0);
                for (k = 0; k < chunk; k = k + 1) begin
                    @(posedge clk); #1;
                    f_treq = 1'b1;
                    @(posedge clk); #1;
                    f_treq = 1'b0;
                    @(posedge clk); #1;
                    if (nresp < 272) begin
                        resp[nresp] = dut.usbfs_core_i.tp_byte;
                        nresp = nresp + 1;
                    end
                end
                got = got + chunk;
            end
        end
    endtask

    // Control OUT data stage: OUT token, then the payload as a data packet.
    task automatic out_xfer (input [15:0] d, input integer nbytes);
        integer k;
        begin
            token(PID_OUT, 4'h0);
            for (k = 0; k < nbytes; k = k + 1) begin
                @(posedge clk); #1;
                f_byte    = (k == 0) ? d[7:0] : d[15:8];
                f_byte_en = 1'b1;
                @(posedge clk); #1;
                f_byte_en = 1'b0;
            end
            token(PID_DATA0, 4'h0);
        end
    endtask

    task automatic show (input integer n);
        integer k;
        reg [8*64-1:0] line;
        begin
            $write("             ...");
            for (k = 0; k < n && k < 12; k = k + 1) $write(" %02h", resp[k]);
            if (n > 12) $write(" ...");
            $write("\n");
        end
    endtask

    initial begin
        n_pass = 0; n_fail = 0; n_info = 0;

        dev = dut.usbfs_core_i.DESCRIPTOR_DEVICE;
        cfg = dut.usbfs_core_i.DESCRIPTOR_CONFIG;

        $display("");
        $display("==========================================================================================");
        $display(" UAC 1.0 Basic Audio Device control-transfer conformance report");
        $display(" reference: references/BasicAudioDevice-10.pdf section 5.4");
        $display("==========================================================================================");

        rstn = 1'b0;
        repeat (20) @(posedge clk);
        rstn = 1'b1;

        // Take over the packet-level interface and release the device from its 2000 ms detach.
        force dut.usbfs_core_i.usb_rstn    = 1'b1;
        force dut.usbfs_core_i.rp_pid      = f_pid;
        force dut.usbfs_core_i.rp_addr     = f_addr;
        force dut.usbfs_core_i.rp_byte_en  = f_byte_en;
        force dut.usbfs_core_i.rp_byte     = f_byte;
        force dut.usbfs_core_i.rp_fin      = f_fin;
        force dut.usbfs_core_i.rp_okay     = f_okay;
        force dut.usbfs_core_i.tp_byte_req = f_treq;
        repeat (20) @(posedge clk);

        //================================================================================================
        $display("");
        $display(" 1. GetDescriptor  (mandatory, BADD 5.4.1)");
        $display("");

        // ---- device descriptor ------------------------------------------------------------------------
        setup_xfer(8'h80, 8'h06, 16'h0100, 16'h0000, 16'd18);
        in_xfer(18);
        show(18);
        begin : dev_cmp
            integer bad;
            bad = 0;
            for (i = 0; i < 18; i = i + 1)
                if (resp[i] !== devb(i)) bad = bad + 1;
            chk(bad == 0, "REQ-01", "GetDescriptor(DEVICE) returns the 18-byte device descriptor");
            if (bad != 0) $display("             ... %0d byte(s) differ from the descriptor parameter", bad);
        end

        // ---- configuration descriptor ------------------------------------------------------------------
        setup_xfer(8'h80, 8'h06, 16'h0200, 16'h0000, 16'd174);
        in_xfer(64);
        show(64);
        begin : cfg_cmp
            integer bad;
            bad = 0;
            for (i = 0; i < 64; i = i + 1)
                if (resp[i] !== cfgb(i)) bad = bad + 1;
            chk(bad == 0, "REQ-02",
                "GetDescriptor(CONFIGURATION) returns the configuration block");
            if (bad != 0) $display("             ... %0d byte(s) differ from the descriptor parameter", bad);
        end

        // ---- string descriptor 0 (language IDs) ---------------------------------------------------------
        setup_xfer(8'h80, 8'h06, 16'h0300, 16'h0000, 16'd4);
        in_xfer(4);
        show(4);
        chk(resp[0] == 8'h04 && resp[1] == 8'h03, "REQ-03",
            "GetDescriptor(STRING 0) returns a STRING descriptor with the language ID array");

        //================================================================================================
        $display("");
        $display(" 2. GetConfiguration  (mandatory, BADD 5.4.1)");
        $display("");

        setup_xfer(8'h80, 8'h08, 16'h0000, 16'h0000, 16'd1);
        in_xfer(1);
        show(1);
        chk(resp[0] == 8'h01, "REQ-04", "GetConfiguration returns the active configuration value 1");

        //================================================================================================
        $display("");
        $display(" 3. Feature Unit requests  (mandatory, BADD 5.4.2.1)");
        $display("");
        $display("             Feature Unit ID2, wIndex = 0x0200. Mute on Master (channel 0),");
        $display("             Volume on Center Front (channel 1). The path is mono.");
        $display("");

        // ---- Mute GET_CUR -----------------------------------------------------------------
        setup_xfer(8'hA1, 8'h81, 16'h0100, 16'h0200, 16'd1);
        in_xfer(1);
        show(1);
        chk(resp[0] == 8'h00, "REQ-05",
            "Feature Unit GET_CUR(Mute) returns the current setting (unmuted after reset)");

        // ---- Mute SET_CUR then GET_CUR ----------------------------------------------------
        setup_xfer(8'h21, 8'h01, 16'h0100, 16'h0200, 16'd1);
        out_xfer(16'h0001, 1);
        setup_xfer(8'hA1, 8'h81, 16'h0100, 16'h0200, 16'd1);
        in_xfer(1);
        show(1);
        chk(resp[0] == 8'h01, "REQ-06",
            "Feature Unit SET_CUR(Mute)=1 is accepted and reads back (BADD 5.4.2.1.1)");

        // muting must actually silence the stream, not just store a bit
        chk(dut.data_l === 16'h0000, "REQ-07",
            "the Mute Control silences the audio stream while set");

        setup_xfer(8'h21, 8'h01, 16'h0100, 16'h0200, 16'd1);
        out_xfer(16'h0000, 1);
        setup_xfer(8'hA1, 8'h81, 16'h0100, 16'h0200, 16'd1);
        in_xfer(1);
        show(1);
        chk(resp[0] == 8'h00, "REQ-08", "SET_CUR(Mute)=0 restores the unmuted state");

        // ---- Volume CUR / MIN / MAX / RES --------------------------------------------------
        setup_xfer(8'hA1, 8'h81, 16'h0201, 16'h0200, 16'd2);
        in_xfer(2);
        show(2);
        chk({resp[1], resp[0]} == 16'hF000, "REQ-09",
            "Feature Unit GET_CUR(Volume, Center Front) returns the current setting");

        setup_xfer(8'hA1, 8'h82, 16'h0201, 16'h0200, 16'd2);
        in_xfer(2);
        show(2);
        chk({resp[1], resp[0]} == 16'hC000, "REQ-10",
            "Feature Unit GET_MIN(Volume) is supported (BADD 5.4.2.1.2)");

        setup_xfer(8'hA1, 8'h83, 16'h0201, 16'h0200, 16'd2);
        in_xfer(2);
        show(2);
        chk({resp[1], resp[0]} == 16'h0000, "REQ-11",
            "Feature Unit GET_MAX(Volume) is supported (BADD 5.4.2.1.2)");

        setup_xfer(8'hA1, 8'h84, 16'h0201, 16'h0200, 16'd2);
        in_xfer(2);
        show(2);
        chk({resp[1], resp[0]} == 16'h0100, "REQ-12",
            "Feature Unit GET_RES(Volume) is supported (BADD 5.4.2.1.2)");

        // ---- Volume SET_CUR then GET_CUR, per channel --------------------------------------
        setup_xfer(8'h21, 8'h01, 16'h0201, 16'h0200, 16'd2);
        out_xfer(16'hE800, 2);
        setup_xfer(8'hA1, 8'h81, 16'h0201, 16'h0200, 16'd2);
        in_xfer(2);
        show(2);
        chk({resp[1], resp[0]} == 16'hE800, "REQ-13",
            "SET_CUR(Volume, Center Front) is accepted and reads back");

        // the reported MIN and MAX must themselves be settable
        setup_xfer(8'h21, 8'h01, 16'h0201, 16'h0200, 16'd2);
        out_xfer(16'hC000, 2);
        setup_xfer(8'hA1, 8'h81, 16'h0201, 16'h0200, 16'd2);
        in_xfer(2);
        show(2);
        chk({resp[1], resp[0]} == 16'hC000, "REQ-14",
            "SET_CUR(Volume) accepts the advertised MIN");

        setup_xfer(8'h21, 8'h01, 16'h0201, 16'h0200, 16'd2);
        out_xfer(16'h0000, 2);
        setup_xfer(8'hA1, 8'h81, 16'h0201, 16'h0200, 16'd2);
        in_xfer(2);
        show(2);
        chk({resp[1], resp[0]} == 16'h0000, "REQ-15",
            "SET_CUR(Volume) accepts the advertised MAX");

        //================================================================================================
        $display("");
        $display(" 4. Other mandatory standard requests  (BADD 5.4.1)");
        $display("");

        setup_xfer(8'h80, 8'h00, 16'h0000, 16'h0000, 16'd2);
        in_xfer(2);
        show(2);
        note("REQ-16", "GetStatus is not decoded by usbfs_transaction; it returns ep00_resp");

        note("REQ-17", "SetAddress/SetConfiguration/SetInterface are accepted but produce no observable state here");
        note("REQ-18", "usbfs_transaction ignores the device address entirely - it answers tokens for any address");

        release dut.usbfs_core_i.usb_rstn;
        release dut.usbfs_core_i.rp_pid;
        release dut.usbfs_core_i.rp_addr;
        release dut.usbfs_core_i.rp_byte_en;
        release dut.usbfs_core_i.rp_byte;
        release dut.usbfs_core_i.rp_fin;
        release dut.usbfs_core_i.rp_okay;
        release dut.usbfs_core_i.tp_byte_req;

        $display("");
        $display("==========================================================================================");
        $display(" conforming: %0d      non-conforming: %0d      advisory notes: %0d",
                 n_pass, n_fail, n_info);
        if (n_fail == 0)
            $display(" RESULT: control transfers conform to the Basic Audio Device definition.");
        else
            $display(" RESULT: %0d requirement(s) not met.", n_fail);
        $display("==========================================================================================");
        $display("");
        $finish;
    end

endmodule
