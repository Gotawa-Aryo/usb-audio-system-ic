`timescale 1ns / 1ps
//--------------------------------------------------------------------------------------------------------
// Testbench : tb_first_order_dfe
// DUT       : first_order_dfe - block 1.4 "Delta-Sigma DAC Modulator" of Figure 3
//
// WR_DATA is a 16-bit SIGNED PCM sample. The 1-bit output density for a steady input x
// settles at d(x) = (x + 32768) / 65535, so silence (16'h0000) gives a 50 % duty bitstream.
//
// Checks:
//   1. reset squelches MODULATOR_OUT and clears the integrator
//   2. DC transfer accuracy across full scale
//   3. monotonicity - density never decreases as the sample increases
//   4. integrator stability - reg_sig stays bounded, i.e. the loop does not run away
//   5. the rails behave: -32768 gives a solid 0, +32767 gives a solid 1
//   6. silence actually toggles rather than sticking at one level
//--------------------------------------------------------------------------------------------------------

module tb_first_order_dfe;

    localparam integer MEAS_CYCLES = 65536;
    localparam real    TOLERANCE   = 0.001;

    reg         clk     = 1'b0;
    reg         reset_n = 1'b0;
    reg  [15:0] wr_data = 16'h0;
    wire        mod_out;

    always #8.333 clk = ~clk;                 // 60 MHz

    integer errors = 0;
    integer count, i, transitions;
    integer int_min, int_max;
    real    density, ideal, prev_density;
    reg     last_bit;

    first_order_dfe dut (
        .SYS_CLK_60M   ( clk     ),
        .RESET_N       ( reset_n ),
        .WR_DATA       ( wr_data ),
        .MODULATOR_OUT ( mod_out )
    );

    // Drive a steady sample and measure output density, integrator excursion and toggle count.
    task automatic measure (input [15:0] x);
        integer sv;
        begin
            reset_n = 1'b0;
            wr_data = x;
            repeat (4) @(posedge clk);
            reset_n = 1'b1;
            repeat (4) @(posedge clk);

            count       = 0;
            transitions = 0;
            int_min     = 0;
            int_max     = 0;
            #1;
            last_bit = mod_out;

            for (i = 0; i < MEAS_CYCLES; i = i + 1) begin
                @(posedge clk);
                #1;
                if (mod_out) count = count + 1;
                if (mod_out !== last_bit) transitions = transitions + 1;
                last_bit = mod_out;

                sv = $signed(dut.reg_sig);
                if (sv < int_min) int_min = sv;
                if (sv > int_max) int_max = sv;
            end

            density = count * 1.0 / MEAS_CYCLES;
            ideal   = ($signed(x) + 32768.0) / 65535.0;
        end
    endtask

    initial begin
        $display("");
        $display("==========================================================================================");
        $display(" tb_first_order_dfe : first-order delta-sigma modulator");
        $display(" ideal density d(x) = (x + 32768) / 65535");
        $display("==========================================================================================");
        $display("");

        // ---- 1. reset behaviour ----------------------------------------------------------------------
        reset_n = 1'b0;
        wr_data = 16'sd12345;
        repeat (20) @(posedge clk);
        #1;
        if (mod_out !== 1'b0) begin
            $display("  FAIL: MODULATOR_OUT is not squelched during reset");
            errors = errors + 1;
        end else begin
            $display("  OK: MODULATOR_OUT squelched during reset");
        end
        if (dut.reg_sig !== 18'h0) begin
            $display("  FAIL: integrator not cleared by reset (= %0d)", $signed(dut.reg_sig));
            errors = errors + 1;
        end else begin
            $display("  OK: integrator cleared by reset");
        end

        // async reset assertion without a clock edge
        reset_n = 1'b1;
        repeat (50) @(posedge clk);
        #1;
        reset_n = 1'b0;
        #1;
        if (dut.reg_sig !== 18'h0) begin
            $display("  FAIL: asynchronous reset did not clear the integrator immediately");
            errors = errors + 1;
        end else begin
            $display("  OK: asynchronous reset clears the integrator immediately");
        end

        // ---- 2/3/4. DC transfer, monotonicity, stability ---------------------------------------------
        $display("");
        $display(" DC transfer across full scale");
        $display("");
        $display("   sample |    ideal | measured |     error | integrator range     | toggles");
        $display("   ------ | -------- | -------- | --------- | -------------------- | -------");

        prev_density = -1.0;
        begin : sweep
            integer k;
            reg signed [15:0] s;
            for (k = 0; k < 11; k = k + 1) begin
                case (k)
                    0:  s = -16'sd32768;
                    1:  s = -16'sd26214;
                    2:  s = -16'sd19660;
                    3:  s = -16'sd13107;
                    4:  s =  -16'sd6553;
                    5:  s =      16'sd0;
                    6:  s =   16'sd6553;
                    7:  s =  16'sd13107;
                    8:  s =  16'sd19660;
                    9:  s =  16'sd26214;
                    10: s =  16'sd32767;
                endcase

                measure(s);

                $display("   %6d | %8.5f | %8.5f | %9.5f | %8d .. %-8d | %7d",
                         s, ideal, density, density - ideal, int_min, int_max, transitions);

                if ((density - ideal) > TOLERANCE || (ideal - density) > TOLERANCE) begin
                    $display("     ** FAIL: density error exceeds %0.4f", TOLERANCE);
                    errors = errors + 1;
                end

                if (density < prev_density) begin
                    $display("     ** FAIL: density decreased as the sample increased (not monotonic)");
                    errors = errors + 1;
                end
                prev_density = density;

                // The integrator should stay within roughly +/- one full-scale step of the
                // feedback constants. Anything far outside that means the loop is winding up.
                if (int_max > 100000 || int_min < -100000) begin
                    $display("     ** FAIL: integrator excursion too large - loop is not settling");
                    errors = errors + 1;
                end
            end
        end

        // ---- 5. rails ---------------------------------------------------------------------------------
        $display("");
        measure(-16'sd32768);
        $display("  full negative rail: density = %8.5f, toggles = %0d (expected 0 and 0)",
                 density, transitions);
        if (density != 0.0 || transitions != 0) begin
            $display("    ** FAIL: -32768 should hold MODULATOR_OUT solidly low");
            errors = errors + 1;
        end

        measure(16'sd32767);
        $display("  full positive rail: density = %8.5f, toggles = %0d (expected 1 and 0)",
                 density, transitions);
        if (density != 1.0 || transitions != 0) begin
            $display("    ** FAIL: +32767 should hold MODULATOR_OUT solidly high");
            errors = errors + 1;
        end

        // ---- 6. silence must dither, not stick --------------------------------------------------------
        measure(16'sd0);
        $display("  silence: density = %8.5f, toggles = %0d (expected ~0.5 and a lot)",
                 density, transitions);
        if (transitions < MEAS_CYCLES / 4) begin
            $display("    ** FAIL: silence is not dithering - the modulator is stuck");
            errors = errors + 1;
        end

        $display("");
        $display("==========================================================================================");
        if (errors == 0)
            $display(" RESULT: PASS - transfer is accurate and monotonic, loop stays bounded.");
        else
            $display(" RESULT: FAIL - %0d check(s) failed.", errors);
        $display("==========================================================================================");
        $display("");
        $finish;
    end

endmodule
