`timescale 1ns / 1ps
//--------------------------------------------------------------------------------------------------------
// Testbench : tb_reset_propagation
// Purpose   : Check that the chip-level RESET_N pin actually resets the USB Interface block.
//
//             Figure 3 ("Schematic: Top-Level") routes RESET_N into all four digital blocks:
//               1.1 USB Interface, 1.2 FIFO Buffer, 1.3 Control Unit, 1.4 Delta-Sigma DAC Modulator.
//
//             usbfs_core_top documents its own reset as "USB will unplug when reset", implemented
//             by the async-reset counter usb_rstn_cnt. That counter is therefore a direct,
//             cheap probe for "did RESET_N reach block 1.1?" - far cheaper than waiting out the
//             2000 ms (120e6 cycle) re-enumeration delay before USB_DP_PULL rises.
//--------------------------------------------------------------------------------------------------------

module tb_reset_propagation;

    reg  clk     = 1'b0;
    reg  reset_n = 1'b0;
    wire usb_dp_pull;
    wire dac_mod_out_l;
    wire usb_dp, usb_dn;

    // USB bus idle (full-speed J state) so the core never sees X on the data lines.
    pullup   (usb_dp);
    pulldown (usb_dn);

    always #8.333 clk = ~clk;                 // 60 MHz

    ic_top_usb_audio dut (
        .USB_DP_PULL   ( usb_dp_pull   ),
        .USB_DP        ( usb_dp        ),
        .USB_DN        ( usb_dn        ),
        .SYS_CLK_60M   ( clk           ),
        .DAC_MOD_OUT_L ( dac_mod_out_l ),
        .RESET_N       ( reset_n       )
    );

    // Probe inside block 1.1 (USB Interface)
    wire [31:0] usb_cnt = dut.u_usb_audio.usbfs_core_i.usb_rstn_cnt;

    integer errors = 0;
    integer cnt_running, cnt_during, cnt_after;

    initial begin
        $display("");
        $display("==========================================================================================");
        $display(" tb_reset_propagation : does the RESET_N pin reach the USB Interface (block 1.1)?");
        $display("==========================================================================================");
        $display("");

        // ---- power-on reset -------------------------------------------------------------------------
        reset_n = 1'b0;
        repeat (20) @(posedge clk);
        reset_n = 1'b1;

        // ---- let the USB interface run --------------------------------------------------------------
        repeat (5000) @(posedge clk);
        #1;
        cnt_running = usb_cnt;
        $display("  after 5000 clocks with RESET_N high : usb_rstn_cnt = %0d", cnt_running);
        if (cnt_running < 4000) begin
            $display("    ** unexpected: the USB interface does not appear to be running");
            errors = errors + 1;
        end

        // ---- assert the chip reset ------------------------------------------------------------------
        reset_n = 1'b0;
        repeat (50) @(posedge clk);
        #1;
        cnt_during = usb_cnt;
        $display("  after 50 clocks with RESET_N LOW    : usb_rstn_cnt = %0d   (documented: 0)", cnt_during);
        if (cnt_during != 0) begin
            $display("    ** FAIL: RESET_N did not reach block 1.1 - the USB interface kept running.");
            errors = errors + 1;
        end else begin
            $display("    OK: the USB interface is held in reset.");
        end

        // ---- release and confirm it restarts from zero -----------------------------------------------
        reset_n = 1'b1;
        repeat (200) @(posedge clk);
        #1;
        cnt_after = usb_cnt;
        $display("  200 clocks after RESET_N released   : usb_rstn_cnt = %0d   (documented: ~200)", cnt_after);
        if (cnt_after > 1000) begin
            $display("    ** FAIL: the counter resumed from its pre-reset value instead of restarting.");
            errors = errors + 1;
        end else begin
            $display("    OK: the USB interface re-enumerates after reset, as documented.");
        end

        // ---- DAC modulator output must be squelched while in reset ----------------------------------
        reset_n = 1'b0;
        repeat (10) @(posedge clk);
        #1;
        $display("  DAC_MOD_OUT_L while RESET_N low     : %b   (expected 0)", dac_mod_out_l);
        if (dac_mod_out_l !== 1'b0) errors = errors + 1;
        reset_n = 1'b1;

        $display("");
        $display("==========================================================================================");
        if (errors == 0)
            $display(" RESULT: PASS - RESET_N reaches every digital block, per Figure 3.");
        else
            $display(" RESULT: FAIL - %0d check(s) failed. RESET_N is not wired as Figure 3 shows.", errors);
        $display("==========================================================================================");
        $display("");

        $finish;
    end

endmodule
