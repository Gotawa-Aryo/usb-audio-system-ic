`timescale 1ns / 1ps
//--------------------------------------------------------------------------------------------------------
// Testbench : tb_uac_stream_conformance
//
// Conformance of the isochronous audio stream against the contract the descriptors declare
// and BADD requires:
//
//   bInterval       = 1        -> one packet per 1 ms frame
//   tSamFreq        = 48000 Hz -> 48 samples per frame
//   wMaxPacketSize  = 96       -> 48 samples x 1 channel x 2 bytes
//   bmAttributes    = 0x0D     -> the sample clock is locked to the frame
//
// tb_uac_descriptor_conformance checks that the descriptors declare these values.
// This bench checks the chip honours them end to end, closing the loop between the two.
//
// It runs on ic_top_usb_audio, not on a single block, because the contract is now spread
// across three of them: block 1.1 decodes the packet burst, block 1.2 absorbs it, and block
// 1.3 drains it at a rate locked to SOF. Samples are counted where they leave the FIFO
// Buffer for the modulator, which is the point the analog side actually sees.
//
// Every sample carries a unique counter value, so a dropped, duplicated or reordered sample
// is detected exactly.
//
// Vector count: FRAMES x 48 samples, each verified individually, at three host frame rates.
//--------------------------------------------------------------------------------------------------------

module tb_uac_stream_conformance;

    localparam integer FRAMES        = 40;
    localparam integer SAMPLES_FRAME = 48;          // tSamFreq 48000 / bInterval 1 ms
    localparam integer NOMINAL_FRAME = 60000;       // 60 MHz / 1 kHz

    reg clk = 1'b0, reset_n = 1'b0;
    always #8.333 clk = ~clk;

    wire usb_dp_pull, dac_mod_out_l;
    wire usb_dp, usb_dn;
    pullup   (usb_dp);
    pulldown (usb_dn);

    ic_top_usb_audio dut (
        .USB_DP_PULL   ( usb_dp_pull   ),
        .USB_DP        ( usb_dp        ),
        .USB_DN        ( usb_dn        ),
        .SYS_CLK_60M   ( clk           ),
        .DAC_MOD_OUT_L ( dac_mod_out_l ),
        .RESET_N       ( reset_n       )
    );

    // forced USB core outputs inside block 1.1
    reg [7:0] inj_data  = 8'h0;
    reg       inj_valid = 1'b0;
    reg       inj_sof   = 1'b0;

    integer errors, n_out, n_in;
    integer expect_next, n_gap, n_dup, n_ooo, n_starve;
    reg [15:0] last_seen;
    reg        soaking = 1'b0;   // gates starvation counting to the injection phase only

    // A sample leaves the FIFO Buffer for the modulator whenever the Control Unit ticks and
    // the buffer has data. That is the stream the analog side sees.
    always @(posedge clk)
        if (dut.sig_48k) begin
            if (dut.rd_empty) begin
                if (soaking) n_starve = n_starve + 1;   // a real underrun; the drain tail is not one
            end else begin
                if (dut.rd_data !== expect_next[15:0]) begin
                    if (dut.rd_data === last_seen)          n_dup = n_dup + 1;
                    else if (dut.rd_data > expect_next)     n_gap = n_gap + 1;
                    else                                    n_ooo = n_ooo + 1;
                    if (n_gap + n_dup + n_ooo <= 5)
                        $display("    ** sample %0d: got %04h, expected %04h",
                                 n_out, dut.rd_data, expect_next[15:0]);
                    expect_next = dut.rd_data + 1;
                end else begin
                    expect_next = expect_next + 1;
                end
                last_seen = dut.rd_data;
                n_out = n_out + 1;
            end
        end

    task automatic inject_byte (input [7:0] b);
        begin
            @(posedge clk); #1;
            inj_data  = b;
            inj_valid = 1'b1;
            @(posedge clk); #1;
            inj_valid = 1'b0;
        end
    endtask

    integer f, sm, k;

    // One 1 ms frame: SOF, a 96-byte isochronous packet, then idle for the rest of it.
    task automatic run_frame (input integer frame_clks);
        begin
            @(posedge clk); #1;
            inj_sof = 1'b1;
            @(posedge clk); #1;
            inj_sof = 1'b0;

            for (sm = 0; sm < SAMPLES_FRAME; sm = sm + 1) begin
                inject_byte(n_in[7:0]);          // sample LSB - the counter
                inject_byte(n_in[15:8]);         // sample MSB
                n_in = n_in + 1;
            end
            // 1 SOF clock + 2 bytes x 2 clocks x 48 samples already elapsed
            repeat (frame_clks - 1 - (SAMPLES_FRAME * 4)) @(posedge clk);
            #1;
        end
    endtask

    task automatic soak (input integer frame_clks, input [255:0] label);
        begin
            n_out = 0; n_in = 0; expect_next = 0;
            n_gap = 0; n_dup = 0; n_ooo = 0; n_starve = 0;
            last_seen = 16'hFFFF;

            soaking = 1'b1;
            for (f = 0; f < FRAMES; f = f + 1) run_frame(frame_clks);
            soaking = 1'b0;
            repeat (NOMINAL_FRAME * 3) @(posedge clk);       // drain
            #1;

            $display("  %-30s frame=%0d clk : in=%0d out=%0d gap=%0d dup=%0d ooo=%0d starve=%0d",
                     label, frame_clks, n_in, n_out, n_gap, n_dup, n_ooo, n_starve);

            if (n_gap != 0 || n_dup != 0 || n_ooo != 0) begin
                $display("    ** FAIL: the isochronous path lost, duplicated or reordered samples");
                errors = errors + 1;
            end else if (n_out != n_in) begin
                $display("    ** FAIL: sample count mismatch - %0d in, %0d out", n_in, n_out);
                errors = errors + 1;
            end else if (n_starve != 0) begin
                $display("    ** FAIL: the buffer ran dry %0d time(s) mid-stream", n_starve);
                errors = errors + 1;
            end else begin
                $display("    OK: every sample arrived exactly once, in order");
            end
        end
    endtask

    initial begin
        errors = 0;
        n_out = 0; n_in = 0; expect_next = 0;
        n_gap = 0; n_dup = 0; n_ooo = 0; n_starve = 0;
        last_seen = 16'hFFFF;

        $display("");
        $display("==========================================================================================");
        $display(" UAC isochronous stream conformance");
        $display(" contract: 1 packet/frame, 48 samples/frame, 96 bytes/packet, clock locked to SOF");
        $display("==========================================================================================");
        $display("");

        reset_n = 1'b0;
        repeat (20) @(posedge clk);
        reset_n = 1'b1;

        force dut.u_usb_audio.usb_rstn  = 1'b1;
        force dut.u_usb_audio.out_data  = inj_data;
        force dut.u_usb_audio.out_valid = inj_valid;
        force dut.u_usb_audio.sof       = inj_sof;
        // Injection happens downstream of usbfs_packet_rx, so the real ep01_commit never
        // fires. Commit unconditionally; CRC rejection is covered by tb_usb_wire_end_to_end.
        force dut.wr_commit_l = 1'b1;
        force dut.wr_abort_l  = 1'b0;
        repeat (20) @(posedge clk);

        $display(" sustained stream, %0d frames of %0d samples each", FRAMES, SAMPLES_FRAME);
        $display("");

        // A conforming synchronous device tracks whatever frame rate the host presents.
        // A free-running one drifts and eventually starves or overruns the buffer.
        soak(NOMINAL_FRAME, "nominal host rate");
        soak(60600,         "host 1 % slow");
        soak(59400,         "host 1 % fast");

        release dut.u_usb_audio.usb_rstn;
        release dut.u_usb_audio.out_data;
        release dut.u_usb_audio.out_valid;
        release dut.u_usb_audio.sof;
        release dut.wr_commit_l;
        release dut.wr_abort_l;

        $display("");
        $display("==========================================================================================");
        $display(" sample vectors checked: %0d", FRAMES * SAMPLES_FRAME * 3);
        if (errors == 0)
            $display(" RESULT: PASS - the stream honours the declared isochronous contract.");
        else
            $display(" RESULT: FAIL - %0d check(s) failed.", errors);
        $display("==========================================================================================");
        $display("");
        $finish;
    end

endmodule
