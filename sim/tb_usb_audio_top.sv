`timescale 1ns / 1ps
//--------------------------------------------------------------------------------------------------------
// Testbench : tb_usb_audio_top
// DUT       : usb_audio_top - block 1.1 "USB Interface" of Figure 3
//
// Block 1.1 decodes the USB byte stream into 16-bit mono PCM and hands each sample to
// the FIFO Buffer as WR_EN_L / DATA_L. It no longer paces anything: smoothing the packet burst
// into a steady 48 ksps stream is block 1.2's job, and the sample clock belongs to block 1.3.
//
// Enumerating a real host would take 2000 ms of simulated time before the core releases
// usb_rstn, so the USB core's outputs are forced directly: usb_rstn high, then bytes injected
// on out_data / out_valid with sof framing. Everything downstream of that is the real RTL.
//
// Checks:
//   1. two bytes assemble into one mono sample, little-endian
//   2. DATA_L carries that sample unchanged
//   3. WR_EN_L pulses once per sample, not once per byte
//   4. SOF resets the byte phase, so a short packet cannot invert LSB/MSB for the stream
//   5. SOF_OUT reproduces the frame marker for the Control Unit
//   6. the Mute Control gates DATA_L
//--------------------------------------------------------------------------------------------------------

module tb_usb_audio_top;

    reg clk = 1'b0, rstn = 1'b0;
    always #8.333 clk = ~clk;

    wire        usb_dp_pull, usb_rstn;
    wire        wr_en_l, sof_out;
    wire [15:0] data_l;
    wire        usb_dp, usb_dn;

    pullup   (usb_dp);
    pulldown (usb_dn);

    usb_audio_top #(.DEBUG("FALSE")) dut (
        .rstn(rstn), .clk(clk),
        .usb_dp_pull(usb_dp_pull), .usb_dp(usb_dp), .usb_dn(usb_dn),
        .usb_rstn(usb_rstn),
        .wr_en_l(wr_en_l), .data_l(data_l), .sof_out(sof_out),
        .debug_en(), .debug_data(), .debug_uart_tx()
    );

    integer errors = 0;
    integer i, n_wr, n_sof;
    reg [15:0] seen [0:63];

    reg [7:0] inj_data  = 8'h0;
    reg       inj_valid = 1'b0;
    reg       inj_sof   = 1'b0;

    always @(posedge clk) begin
        if (wr_en_l && n_wr < 64) begin
            seen[n_wr] = data_l;
            n_wr = n_wr + 1;
        end
        if (sof_out) n_sof = n_sof + 1;
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

    task automatic pulse_sof;
        begin
            @(posedge clk); #1;
            inj_sof = 1'b1;
            @(posedge clk); #1;
            inj_sof = 1'b0;
        end
    endtask

    // One mono sample as two bytes: LSB then MSB
    task automatic push_sample (input [15:0] v);
        begin
            inject_byte(v[7:0]);
            inject_byte(v[15:8]);
        end
    endtask

    initial begin
        n_wr = 0; n_sof = 0;

        $display("");
        $display("==========================================================================================");
        $display(" tb_usb_audio_top : PCM assembly and the WR_EN_L / DATA_L handoff");
        $display("==========================================================================================");
        $display("");

        rstn = 1'b0;
        repeat (20) @(posedge clk);
        rstn = 1'b1;

        force dut.usb_rstn  = 1'b1;
        force dut.out_data  = inj_data;
        force dut.out_valid = inj_valid;
        force dut.sof       = inj_sof;
        repeat (10) @(posedge clk);

        // ---- 1/2/3. assembly, byte order, strobe rate    ------------------------------------------------
        pulse_sof;
        n_wr = 0;
        push_sample(16'h1234);
        push_sample(16'h5678);
        push_sample(16'hF001);
        push_sample(16'h8000);
        repeat (20) @(posedge clk);
        #1;

        $display("  pushed 4 samples (8 bytes), WR_EN_L fired %0d time(s)", n_wr);
        if (n_wr != 4) begin
            $display("    ** FAIL: expected exactly 4 WR_EN_L pulses, one per sample");
            errors = errors + 1;
        end else begin
            $display("    OK: WR_EN_L pulses once per sample, not once per byte");
        end

        begin : check_samples
            reg [15:0] want [0:3];
            want[0] = 16'h1234;
            want[1] = 16'h5678;
            want[2] = 16'hF001;
            want[3] = 16'h8000;

            $display("");
            $display("   #  DATA_L  expected");
            $display("   -  ------  --------");
            for (i = 0; i < n_wr && i < 4; i = i + 1) begin
                $display("   %0d   %04h    %04h", i, seen[i], want[i]);
                if (seen[i] !== want[i]) begin
                    $display("     ** FAIL: DATA_L does not match the injected sample");
                    errors = errors + 1;
                end
            end
        end

        // ---- 4. SOF resets the byte phase ----------------------------------------------------------------
        $display("");
        n_wr = 0;
        inject_byte(8'hAA);          // deliberately incomplete sample: 1 stray byte
        pulse_sof;                   // SOF must discard the partial sample
        push_sample(16'hDEAD);
        repeat (20) @(posedge clk);
        #1;

        if (n_wr >= 1) begin
            $display("  after 1 stray byte + SOF, first sample = %04h (expected DEAD)", seen[0]);
            if (seen[0] !== 16'hDEAD) begin
                $display("    ** FAIL: SOF did not resynchronise the byte phase");
                errors = errors + 1;
            end else begin
                $display("    OK: SOF resynchronises the byte phase");
            end
        end else begin
            $display("  ** FAIL: no sample emerged after the SOF resync test");
            errors = errors + 1;
        end

        // ---- 5. SOF_OUT is passed through for the Control Unit -------------------------------------------
        $display("");
        n_sof = 0;
        for (i = 0; i < 5; i = i + 1) pulse_sof;
        repeat (5) @(posedge clk);
        #1;
        $display("  5 SOF pulses injected, SOF_OUT fired %0d time(s)", n_sof);
        if (n_sof != 5) begin
            $display("    ** FAIL: the Control Unit would not see the frame marker");
            errors = errors + 1;
        end else begin
            $display("    OK: SOF_OUT reproduces the frame marker");
        end

        // ---- 6. Mute gates the stream ---------------------------------------------------------------------
        $display("");
        force dut.mute_master = 1'b1;
        n_wr = 0;
        pulse_sof;
        push_sample(16'h4321);
        repeat (20) @(posedge clk);
        #1;
        $display("  with Mute set, DATA_L = %04h (expected 0000)", seen[0]);
        if (n_wr < 1 || seen[0] !== 16'h0000) begin
            $display("    ** FAIL: the Mute Control does not gate DATA_L");
            errors = errors + 1;
        end else begin
            $display("    OK: Mute silences the stream");
        end
        release dut.mute_master;

        release dut.usb_rstn;
        release dut.out_data;
        release dut.out_valid;
        release dut.sof;

        $display("");
        $display("==========================================================================================");
        if (errors == 0)
            $display(" RESULT: PASS - PCM assembly, byte order and the FIFO handoff all behave.");
        else
            $display(" RESULT: FAIL - %0d check(s) failed.", errors);
        $display("==========================================================================================");
        $display("");
        $finish;
    end

endmodule
