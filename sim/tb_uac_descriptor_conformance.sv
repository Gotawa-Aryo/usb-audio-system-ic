`timescale 1ns / 1ps
//--------------------------------------------------------------------------------------------------------
// Testbench : tb_uac_descriptor_conformance
//
// Conformance harness for the descriptor set, checked against
//   references/BasicAudioDevice-10.pdf
//   "USB Audio Device Class Specification for Basic Audio Devices", Release 1.0 (BADD)
//
// It reads the actual descriptor parameters out of the instantiated design, walks them as a
// byte array, and asserts the requirements BADD places on a Headphone device. Anything the
// design does not meet reports NONCONF.
//
// The device drives a single analog channel (Table 1: AUDIO_OUT_L) into a headphone load, so
// the target profile is Headphone topology HT1, mono variant M_HP_HT1 (code 0x01, BADD
// Table A-1). Declaring mono matches the pin list, halves the packet to 96 bytes, and lets
// the host downmix rather than the chip discarding a channel it decoded.
//
// Nothing here is hand-copied from the RTL: the descriptor bytes are read hierarchically from
// the elaborated parameters, so editing usb_audio_top.v re-checks automatically.
//--------------------------------------------------------------------------------------------------------

module tb_uac_descriptor_conformance;

    // descriptor types
    localparam [7:0] DT_DEVICE       = 8'h01;
    localparam [7:0] DT_CONFIG       = 8'h02;
    localparam [7:0] DT_INTERFACE    = 8'h04;
    localparam [7:0] DT_ENDPOINT     = 8'h05;
    localparam [7:0] DT_CS_INTERFACE = 8'h24;
    localparam [7:0] DT_CS_ENDPOINT  = 8'h25;
    // CS_INTERFACE subtypes
    localparam [7:0] ST_HEADER       = 8'h01;
    localparam [7:0] ST_INPUT_TERM   = 8'h02;
    localparam [7:0] ST_OUTPUT_TERM  = 8'h03;
    localparam [7:0] ST_FEATURE_UNIT = 8'h06;

    reg clk = 1'b0, rstn = 1'b0;
    wire usb_dp, usb_dn;
    pullup (usb_dp);
    pulldown (usb_dn);

    // Instantiated only so the descriptor parameters can be read out of the elaborated design.
    usb_audio_top #(.DEBUG("FALSE")) dut (
        .rstn(rstn), .clk(clk),
        .usb_dp_pull(), .usb_dp(usb_dp), .usb_dn(usb_dn), .usb_rstn(),
        .wr_en_l(), .data_l(),
        .debug_en(), .debug_data(), .debug_uart_tx()
    );

    reg [18*8-1:0]  dev;
    reg [512*8-1:0] cfg;

    function [7:0] devb (input integer i);
        devb = dev[(18 - 1 - i) * 8 +: 8];
    endfunction

    function [7:0] cfgb (input integer i);
        cfgb = cfg[(512 - 1 - i) * 8 +: 8];
    endfunction

    function [15:0] cfgw (input integer i);          // little-endian 16-bit field
        cfgw = {cfgb(i + 1), cfgb(i)};
    endfunction

    integer n_pass, n_fail, n_info;

    // 1024 bits = 128 characters; anything longer is truncated from the left by $display.
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

    // ---- parsed state ---------------------------------------------------------------------------------
    integer total_len, walked, n_iface_desc, n_feature_unit, n_mixer;
    integer ac_iface_count, as_iface_count;
    integer i, p, blen, btype, bsub;
    integer out_term_type, in_term_from_usb_channels;
    integer fmt_channels, fmt_subframe, fmt_bits, fmt_freq;
    integer ep_attr, ep_maxpkt, ep_interval, ep_addr, csep_attr;
    integer as_delay, as_fmt_tag;
    integer alt0_endpoints, alt1_endpoints;
    integer bnum_interfaces, bmax_power, bm_attributes;
    integer found_fmt, found_ep, found_csep, found_as_general;
    integer cur_subclass, expect_csep, pend_valid;
    integer pend_delay, pend_fmt_tag, pend_channels, pend_subframe, pend_bits, pend_freq;

    initial begin
        n_pass = 0; n_fail = 0; n_info = 0;
        n_feature_unit = 0; n_mixer = 0; n_iface_desc = 0;
        ac_iface_count = 0; as_iface_count = 0;
        alt0_endpoints = -1; alt1_endpoints = -1;
        out_term_type = -1; in_term_from_usb_channels = -1;
        fmt_channels = -1; fmt_subframe = -1; fmt_bits = -1; fmt_freq = -1;
        ep_attr = -1; ep_maxpkt = -1; ep_interval = -1; ep_addr = -1; csep_attr = -1;
        as_delay = -1; as_fmt_tag = -1;
        found_fmt = 0; found_ep = 0; found_csep = 0; found_as_general = 0;
        expect_csep = 0;

        dev = dut.usbfs_core_i.DESCRIPTOR_DEVICE;
        cfg = dut.usbfs_core_i.DESCRIPTOR_CONFIG;

        $display("");
        $display("==========================================================================================");
        $display(" UAC 1.0 Basic Audio Device conformance report");
        $display(" target profile: Headphone HT1, mono variant (M_HP_HT1, BADD Table A-1)");
        $display(" reference: references/BasicAudioDevice-10.pdf");
        $display("==========================================================================================");

        //================================================================================================
        $display("");
        $display(" 1. Device descriptor  (BADD 5.3.1, Table 5-1)");
        $display("");

        chk(devb(0) == 8'h12,  "DEV-01", "bLength = 0x12");
        chk(devb(1) == DT_DEVICE, "DEV-02", "bDescriptorType = DEVICE");
        chk(devb(4) == 8'h00,  "DEV-03", "bDeviceClass = 0 (class is at interface level)");
        chk(devb(5) == 8'h00,  "DEV-04", "bDeviceSubClass = 0");
        chk(devb(6) == 8'h00,  "DEV-05", "bDeviceProtocol = 0");
        chk(devb(17) >= 8'h01, "DEV-06", "bNumConfigurations >= 1");

        if ({devb(3), devb(2)} != 16'h0200)
            note("DEV-07", "bcdUSB is not 0x0200 (BADD Table 5-1 tabulates 0x0200)");
        else
            chk(1'b1, "DEV-07", "bcdUSB = 0x0200");

        $display("             ... bcdUSB=%04h idVendor=%02h%02h idProduct=%02h%02h",
                 {devb(3), devb(2)}, devb(9), devb(8), devb(11), devb(10));

        if ({devb(9), devb(8)} == 16'hFB9A)
            note("DEV-08", "idVendor 0xFB9A is not allocated to this project (upstream value)");

        //================================================================================================
        $display("");
        $display(" 2. Configuration descriptor  (BADD 5.3.2, Table 5-2; power 4.1)");
        $display("");

        total_len       = cfgw(2);
        bnum_interfaces = cfgb(4);
        bm_attributes   = cfgb(7);
        bmax_power      = cfgb(8);

        chk(cfgb(0) == 8'h09, "CFG-01", "bLength = 0x09");
        chk(cfgb(1) == DT_CONFIG, "CFG-02", "bDescriptorType = CONFIGURATION");
        chk(bnum_interfaces >= 2, "CFG-03", "bNumInterfaces >= 2 (one AC, one AS)");
        chk((bm_attributes & 8'h80) != 0, "CFG-04", "bmAttributes D7 = 1");
        chk((bm_attributes & 8'h1F) == 0, "CFG-05", "bmAttributes D4..D0 = 0");
        chk(bmax_power <= 8'd50, "CFG-06", "bMaxPower <= 50 (one unit load, 100 mA) - BADD 4.1");

        $display("             ... wTotalLength=%0d bNumInterfaces=%0d bmAttributes=%02h bMaxPower=%0d (%0d mA)",
                 total_len, bnum_interfaces, bm_attributes, bmax_power, bmax_power * 2);

        //================================================================================================
        $display("");
        $display(" 3. Descriptor block walk");
        $display("");

        // AC HEADER and AS_GENERAL both use bDescriptorSubtype 0x01, and INPUT_TERMINAL and
        // FORMAT_TYPE both use 0x02. They are only distinguishable by which interface they
        // follow, so the walk tracks the current interface subclass.
        // Descriptors are ordered AS interface -> AS_GENERAL -> FORMAT_TYPE -> endpoint, so the
        // AS fields are staged as "pending" and committed when the OUT endpoint is reached.
        walked = 0;
        p = 0;
        cur_subclass  = 0;
        pend_delay    = -1;
        pend_fmt_tag  = -1;
        pend_channels = -1;
        pend_subframe = -1;
        pend_bits     = -1;
        pend_freq     = -1;
        pend_valid    = 0;

        while (p < total_len && p < 512) begin
            blen  = cfgb(p);
            btype = cfgb(p + 1);
            bsub  = cfgb(p + 2);
            if (blen == 0) begin
                $display("  [ NONCONF ] WALK-01  zero-length descriptor at offset %0d - walk aborted", p);
                n_fail = n_fail + 1;
                p = total_len;
            end else begin
                case (btype)
                    DT_INTERFACE : begin
                        n_iface_desc = n_iface_desc + 1;
                        cur_subclass = (cfgb(p + 5) == 8'h01) ? cfgb(p + 6) : 0;
                        if (cur_subclass == 8'h01) begin              // AUDIOCONTROL
                            ac_iface_count = ac_iface_count + 1;
                            chk(cfgb(p + 4) == 8'h00, "AC-01",
                                "AC interface bNumEndpoints = 0 (no status interrupt endpoint)");
                        end else if (cur_subclass == 8'h02) begin     // AUDIOSTREAMING
                            if (cfgb(p + 3) == 8'h00) begin
                                as_iface_count = as_iface_count + 1;
                                alt0_endpoints = cfgb(p + 4);
                            end else begin
                                alt1_endpoints = cfgb(p + 4);
                            end
                            pend_valid = 0;                            // new AS interface
                        end
                    end

                    DT_CS_INTERFACE : begin
                        if (cur_subclass == 8'h01) begin              // inside AudioControl
                            case (bsub)
                                ST_HEADER : begin
                                    chk(cfgw(p + 3) == 16'h0100, "AC-02", "AC header bcdADC = 0x0100");
                                    $display("             ... AC header wTotalLength=%0d bInCollection=%0d",
                                             cfgw(p + 5), cfgb(p + 7));
                                end
                                ST_INPUT_TERM : begin
                                    if (cfgw(p + 4) == 16'h0101)
                                        in_term_from_usb_channels = cfgb(p + 7);
                                end
                                ST_OUTPUT_TERM : begin
                                    if (cfgw(p + 4) != 16'h0101)
                                        out_term_type = cfgw(p + 4);
                                end
                                ST_FEATURE_UNIT : n_feature_unit = n_feature_unit + 1;
                                8'h04           : n_mixer = n_mixer + 1;
                                default         : ;
                            endcase
                        end else if (cur_subclass == 8'h02) begin     // inside AudioStreaming
                            if (bsub == 8'h01) begin                   // AS_GENERAL
                                pend_delay   = cfgb(p + 4);
                                pend_fmt_tag = cfgw(p + 5);
                                pend_valid   = 1;
                            end else if (bsub == 8'h02) begin          // FORMAT_TYPE
                                pend_channels = cfgb(p + 4);
                                pend_subframe = cfgb(p + 5);
                                pend_bits     = cfgb(p + 6);
                                pend_freq     = {cfgb(p + 10), cfgb(p + 9), cfgb(p + 8)};
                            end
                        end
                    end

                    DT_ENDPOINT : begin
                        // the headphone path is the OUT endpoint (host-to-device)
                        if ((cfgb(p + 2) & 8'h80) == 8'h00 && !found_ep) begin
                            found_ep    = 1;
                            ep_addr     = cfgb(p + 2);
                            ep_attr     = cfgb(p + 3);
                            ep_maxpkt   = cfgw(p + 4);
                            ep_interval = cfgb(p + 6);
                            chk(blen == 9, "EP-00",
                                "audio endpoint bLength = 9 (with bRefresh/bSynchAddress)");
                            // commit the AS descriptors that belong to this endpoint
                            if (pend_valid) begin
                                found_as_general = 1;
                                as_delay   = pend_delay;
                                as_fmt_tag = pend_fmt_tag;
                            end
                            if (pend_channels >= 0) begin
                                found_fmt    = 1;
                                fmt_channels = pend_channels;
                                fmt_subframe = pend_subframe;
                                fmt_bits     = pend_bits;
                                fmt_freq     = pend_freq;
                            end
                            expect_csep = 1;
                        end
                    end

                    DT_CS_ENDPOINT : begin
                        if (expect_csep && !found_csep) begin
                            found_csep  = 1;
                            csep_attr   = cfgb(p + 3);
                            expect_csep = 0;
                        end
                    end

                    default : ;
                endcase

                walked = walked + 1;
                p = p + blen;
            end
        end

        $display("             ... walked %0d descriptors, ending at offset %0d", walked, p);
        chk(p == total_len, "WALK-02", "descriptor lengths sum exactly to wTotalLength");
        chk(n_iface_desc >= bnum_interfaces, "WALK-03",
            "at least bNumInterfaces interface descriptors present");

        //================================================================================================
        $display("");
        $display(" 4. Audio function topology  (BADD 5.2, 5.3.3.1)");
        $display("");

        chk(n_feature_unit >= 1, "TOP-01",
            "a Feature Unit is present (BADD 5.3.3.1.10: Mute and Volume SHALL be present)");
        chk(ac_iface_count == 1, "TOP-02", "exactly one AudioControl interface");
        chk(as_iface_count == 1, "TOP-03",
            "exactly one AudioStreaming interface (BADD 3: only Headphone/Microphone/Headset allowed)");

        if (out_term_type >= 0) begin
            chk(out_term_type == 16'h0302, "TOP-04",
                "output terminal type = 0x0302 Headphones (BADD Table 5-7)");
            $display("             ... output terminal type = 0x%04h", out_term_type[15:0]);
        end else begin
            chk(1'b0, "TOP-04", "no non-USB output terminal found");
        end

        if (n_mixer > 0)
            note("TOP-05", "a Mixer Unit is present - only valid for HT2/HT3 topologies");

        //================================================================================================
        $display("");
        $display(" 5. AudioStreaming interface  (BADD 5.3.3.3)");
        $display("");

        chk(alt0_endpoints == 0, "AS-01",
            "alternate setting 0 is zero-bandwidth (bNumEndpoints = 0)");
        chk(alt1_endpoints == 1, "AS-02",
            "alternate setting 1 has exactly one isochronous data endpoint");

        if (found_as_general) begin
            chk(as_delay == 0, "AS-03", "bDelay = 0 (BADD Table 5-15)");
            chk(as_fmt_tag == 16'h0001, "AS-04", "wFormatTag = 0x0001 PCM");
        end else begin
            chk(1'b0, "AS-03", "no AS_GENERAL descriptor found");
        end

        if (found_fmt) begin
            chk(fmt_subframe == 2, "FMT-01", "bSubFrameSize = 2");
            chk(fmt_bits == 16,    "FMT-02", "bBitResolution = 16");
            chk(fmt_freq == 48000, "FMT-03", "tSamFreq = 48000 Hz");
            chk(fmt_channels == 1 || fmt_channels == 2, "FMT-04", "bNrChannels is 1 or 2");
            $display("             ... format: %0d ch, %0d byte subframe, %0d bit, %0d Hz",
                     fmt_channels, fmt_subframe, fmt_bits, fmt_freq);
            if (fmt_channels == 2)
                note("FMT-05",
                     "declared stereo, but the chip has one analog output - mono (BADD Table 5-16) halves the payload");
        end else begin
            chk(1'b0, "FMT-01", "no FORMAT_TYPE descriptor found");
        end

        //================================================================================================
        $display("");
        $display(" 6. Isochronous data endpoint  (BADD Tables 5-18/5-19, 5-20)");
        $display("");

        if (found_ep) begin
            chk(ep_attr == 8'h0D, "EP-01",
                "bmAttributes = 0x0D (Isochronous, Synchronous) - BADD Tables 5-18/5-19");
            chk(ep_interval == 1, "EP-02", "bInterval = 1 (one packet per frame)");
            chk((ep_addr & 8'h80) == 0, "EP-03", "the audio data endpoint is an OUT endpoint");

            $display("             ... EP 0x%02h bmAttributes=0x%02h wMaxPacketSize=%0d bInterval=%0d",
                     ep_addr[7:0], ep_attr[7:0], ep_maxpkt, ep_interval);

            if (found_fmt) begin
                chk(ep_maxpkt == fmt_channels * fmt_subframe * 48, "EP-04",
                    "wMaxPacketSize equals bNrChannels * bSubFrameSize * 48");
                $display("             ... expected %0d bytes/packet from the format descriptor",
                         fmt_channels * fmt_subframe * 48);
            end

            case (ep_attr & 8'h0C)
                8'h00 : note("EP-05",
                             "SyncType = None: host and device clocks free-run, buffer drifts to a glitch");
                8'h04 : note("EP-05", "SyncType = Asynchronous: requires an explicit feedback endpoint");
                8'h08 : note("EP-05", "SyncType = Adaptive: device must track the host rate");
                8'h0C : note("EP-05",
                             "SyncType = Synchronous: the descriptor now asserts the sample clock is locked to SOF. Nothing here can verify that - the implementation still free-runs off the crystal.");
                default : ;
            endcase
        end else begin
            chk(1'b0, "EP-01", "no OUT endpoint descriptor found");
        end

        if (found_csep)
            chk(csep_attr == 8'h00, "EP-06",
                "class-specific EP bmAttributes = 0x00 (no sampling frequency control) - BADD Table 5-20");
        else
            chk(1'b0, "EP-06", "no class-specific endpoint descriptor found");

        //================================================================================================
        $display("");
        $display("==========================================================================================");
        $display(" conforming: %0d      non-conforming: %0d      advisory notes: %0d",
                 n_pass, n_fail, n_info);
        if (n_fail == 0)
            $display(" RESULT: the descriptor set conforms to the Basic Audio Device definition.");
        else
            $display(" RESULT: %0d requirement(s) not met - see docs/usb-subsystem-analysis.md section 5.",
                     n_fail);
        $display("==========================================================================================");
        $display("");
        $finish;
    end

endmodule
