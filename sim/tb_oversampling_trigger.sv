`timescale 1ns / 1ps
//--------------------------------------------------------------------------------------------------------
// Testbench : tb_oversampling_trigger
// DUT       : oversampling_trigger - block 1.3 "Control Unit" of Figure 3
//
// The Control Unit produces SIG_48K, the tick that drives RD_EN on the FIFO Buffer.
//
// The isochronous endpoint declares bmAttributes = 0x0D, Isochronous *Synchronous*, so the
// sample clock must be locked to the USB frame rather than free-running off the crystal.
// That is the property this bench exists to prove, and it is the one thing
// tb_uac_descriptor_conformance cannot check - a descriptor can claim a lock that the
// hardware does not implement.
//
// Checks:
//   1. reset state
//   2. free-run with no SOF: exactly 1250 clocks per tick, one clock wide
//   3. locked at a nominal 60000-clock frame: exactly 48 ticks per frame
//   4. locked at a stretched frame (host clock slow): still exactly 48 ticks per frame
//   5. locked at a compressed frame (host clock fast): still exactly 48 ticks per frame
//   6. SOF stops: falls back to free-run rather than stalling
//   7. implausible SOF spacing is rejected rather than tracked
//
// Checks 4 and 5 are the substance: 48 ticks per frame at a frame length the device did not
// choose is exactly what "synchronous" means, and it is what stops the buffer from drifting.
//--------------------------------------------------------------------------------------------------------

module tb_oversampling_trigger;

    localparam integer NOMINAL   = 60000;    // 60 MHz / 1 kHz
    localparam integer PER_FRAME = 48;       // samples per frame at 48 kHz
    localparam integer FREE_RUN  = NOMINAL / PER_FRAME;   // 1250

    reg  clk     = 1'b0;
    reg  reset_n = 1'b0;
    reg  sof     = 1'b0;
    wire sig_48k;

    always #8.333 clk = ~clk;                 // 60 MHz

    integer errors = 0;
    integer gap, width, i;
    integer tick_in_frame;

    oversampling_trigger dut (
        .SYS_CLK_60M ( clk     ),
        .RESET_N     ( reset_n ),
        .SOF         ( sof     ),
        .SIG_48K     ( sig_48k )
    );

    always @(posedge clk)
        if (sig_48k) tick_in_frame = tick_in_frame + 1;

    // Advance to the next tick, leaving the clock count in `gap`.
    task automatic wait_tick;
        begin
            @(posedge clk);
            #1;
            gap = 1;
            while (!sig_48k) begin
                @(posedge clk);
                #1;
                gap = gap + 1;
            end
        end
    endtask

    // Run one frame of `period_clks` clocks, opening with a one-clock SOF.
    // Leaves the number of ticks emitted during that frame in `tick_in_frame`.
    task automatic frame (input integer period_clks);
        begin
            @(posedge clk); #1;
            sof           = 1'b1;
            tick_in_frame = 0;
            @(posedge clk); #1;
            sof           = 1'b0;
            repeat (period_clks - 1) @(posedge clk);
            #1;
        end
    endtask

    // Drive `n` frames of the given length and check every one carries exactly 48 ticks.
    task automatic check_locked (input integer period_clks, input integer n,
                                 input [255:0] label);
        integer f, bad, first_bad;
        begin
            bad = 0; first_bad = -1;
            // two settling frames: the period is measured from the previous frame
            frame(period_clks);
            frame(period_clks);
            for (f = 0; f < n; f = f + 1) begin
                frame(period_clks);
                if (tick_in_frame != PER_FRAME) begin
                    bad = bad + 1;
                    if (first_bad < 0) first_bad = tick_in_frame;
                end
            end
            $display("  %-34s frame=%0d clocks, %0d frames, ticks/frame wrong in %0d",
                     label, period_clks, n, bad);
            if (bad != 0) begin
                $display("    ** FAIL: first bad frame carried %0d ticks, expected %0d",
                         first_bad, PER_FRAME);
                errors = errors + 1;
            end else begin
                $display("    OK: exactly %0d ticks in every frame", PER_FRAME);
            end
        end
    endtask

    initial begin
        tick_in_frame = 0;

        $display("");
        $display("==========================================================================================");
        $display(" tb_oversampling_trigger : SOF-locked 48 kHz sample tick");
        $display("==========================================================================================");
        $display("");

        // ---- 1. reset state ---------------------------------------------------------------------------
        reset_n = 1'b0;
        repeat (10) @(posedge clk);
        #1;
        if (sig_48k !== 1'b0) begin
            $display("  FAIL: SIG_48K is not low while RESET_N is asserted");
            errors = errors + 1;
        end else $display("  OK: SIG_48K low during reset");
        if (dut.acc !== 17'd0 || dut.locked !== 1'b0) begin
            $display("  FAIL: accumulator or lock flag not cleared by reset");
            errors = errors + 1;
        end else $display("  OK: accumulator and lock flag cleared by reset");

        reset_n = 1'b1;

        // ---- 2. free-run, no SOF ----------------------------------------------------------------------
        $display("");
        $display(" free-run (no SOF present)");
        $display("");

        wait_tick;
        $display("  first tick %0d clocks after reset release (expected %0d)", gap, FREE_RUN);
        if (gap != FREE_RUN) begin
            $display("    ** FAIL");
            errors = errors + 1;
        end

        width = 1;
        @(posedge clk); #1;
        while (sig_48k) begin
            width = width + 1;
            @(posedge clk); #1;
        end
        $display("  tick width = %0d clock(s) (expected 1)", width);
        if (width != 1) begin
            $display("    ** FAIL: the FIFO would pop more than one sample per tick");
            errors = errors + 1;
        end

        wait_tick;                        // resync after the width measurement
        for (i = 0; i < 200; i = i + 1) begin
            wait_tick;
            if (gap != FREE_RUN) begin
                $display("    ** FAIL: free-run period %0d was %0d clocks, expected %0d",
                         i, gap, FREE_RUN);
                errors = errors + 1;
            end
        end
        $display("  200 consecutive free-run periods all exactly %0d clocks", FREE_RUN);
        if (dut.locked !== 1'b0) begin
            $display("    ** FAIL: reported locked with no SOF present");
            errors = errors + 1;
        end else $display("    OK: not locked while no SOF is present");

        // ---- 3/4/5. locked to the frame ----------------------------------------------------------------
        $display("");
        $display(" locked to SOF");
        $display("");

        check_locked(NOMINAL, 20, "nominal 1 ms frame");
        if (dut.locked !== 1'b1) begin
            $display("    ** FAIL: did not report locked while SOF was present");
            errors = errors + 1;
        end else $display("    OK: reports locked");

        // A host running 1 % slow stretches the frame. A synchronous device must follow it,
        // still delivering 48 samples per frame - that is what stops the buffer drifting.
        check_locked(60600, 20, "stretched frame (host 1 % slow)");
        check_locked(59400, 20, "compressed frame (host 1 % fast)");
        check_locked(60060, 10, "stretched frame (host 0.1 % slow)");
        check_locked(59940, 10, "compressed frame (host 0.1 % fast)");

        // ---- 6. SOF disappears --------------------------------------------------------------------------
        $display("");
        $display(" SOF loss");
        $display("");
        sof = 1'b0;
        repeat (NOMINAL * 3) @(posedge clk);
        #1;
        if (dut.locked !== 1'b0) begin
            $display("  FAIL: still reporting locked after SOF stopped");
            errors = errors + 1;
        end else $display("  OK: lock dropped after SOF stopped");

        wait_tick;
        for (i = 0; i < 20; i = i + 1) begin
            wait_tick;
            if (gap != FREE_RUN) begin
                $display("    ** FAIL: fell back to %0d clocks, expected %0d", gap, FREE_RUN);
                errors = errors + 1;
                i = 20;
            end
        end
        $display("  OK: falls back to a free-running %0d clock period", FREE_RUN);

        // ---- 7. implausible SOF spacing ------------------------------------------------------------------
        $display("");
        $display(" bogus SOF spacing");
        $display("");
        for (i = 0; i < 5; i = i + 1) frame(1000);        // far outside the accept window
        #1;
        if (dut.locked !== 1'b0) begin
            $display("  FAIL: locked to an implausible 1000-clock frame");
            errors = errors + 1;
        end else begin
            $display("  OK: implausible frame spacing rejected, stays free-running");
        end

        $display("");
        $display("==========================================================================================");
        if (errors == 0)
            $display(" RESULT: PASS - the sample clock tracks the USB frame, as the endpoint declares.");
        else
            $display(" RESULT: FAIL - %0d check(s) failed.", errors);
        $display("==========================================================================================");
        $display("");
        $finish;
    end

endmodule
