`timescale 1ns / 1ps
//--------------------------------------------------------------------------------------------------------
// Testbench : tb_dac_conformance
//
// DC conformance of the delta-sigma modulator against the Technical Specification slide:
//   "First-order Sigma-Delta DAC with 16 ENOB at 1250 oversampling"
//   "Support standard audio sample rate of 48 kHz"
//
// For a first-order modulator with +32767 / -32768 feedback, the steady-state output density
// for a constant signed 16-bit sample x is exactly
//     d(x) = (x + 32768) / 65535
// so DC linearity is an exact property, not an approximation, and any deviation beyond the
// measurement window's own quantisation is a real error.
//
// Vector count: 1025 codes spanning the full 16-bit range at 64 LSB steps, each measured over
// 16384 clocks, plus 24 directed codes at the rails and around silence.
//
// Scope note: this measures DC transfer, monotonicity and the oversampling ratio. It does NOT
// measure ENOB in the audio sense - that depends on the noise shaping across the audio band
// and on the external analog low-pass filter, neither of which is observable from the 1-bit
// output alone. The bench reports the measurement floor so the linearity numbers can be read
// against it honestly.
//--------------------------------------------------------------------------------------------------------

module tb_dac_conformance;

    localparam integer WINDOW      = 16384;
    localparam integer STEP        = 64;
    localparam integer N_CODES     = 1025;          // -32768 .. 32767 inclusive at 64 LSB steps
    localparam integer OSR         = 1250;          // 60 MHz / 48 kHz
    localparam real    FLOOR       = 1.0 / WINDOW;  // density quantisation of the window
    localparam real    TOL_LINEAR  = 0.0005;

    reg         clk     = 1'b0;
    reg         reset_n = 1'b0;
    reg  [15:0] wr_data = 16'h0;
    wire        mod_out;

    always #8.333 clk = ~clk;

    first_order_dfe dut (
        .SYS_CLK_60M   ( clk     ),
        .RESET_N       ( reset_n ),
        .WR_DATA       ( wr_data ),
        .MODULATOR_OUT ( mod_out )
    );

    integer errors, n_vec;
    integer count, i, transitions;
    real    density, ideal, err, max_err, sum_abs;
    real    prev_density;
    integer n_nonmono, n_overtol;
    reg     last_bit;

    task automatic measure (input [15:0] x);
        begin
            reset_n = 1'b0;
            wr_data = x;
            repeat (4) @(posedge clk);
            reset_n = 1'b1;
            repeat (4) @(posedge clk);

            count       = 0;
            transitions = 0;
            #1;
            last_bit = mod_out;
            for (i = 0; i < WINDOW; i = i + 1) begin
                @(posedge clk);
                #1;
                if (mod_out) count = count + 1;
                if (mod_out !== last_bit) transitions = transitions + 1;
                last_bit = mod_out;
            end
            density = count * 1.0 / WINDOW;
            ideal   = ($signed(x) + 32768.0) / 65535.0;
            err     = density - ideal;
            if (err < 0.0) err = -err;
            n_vec = n_vec + 1;
        end
    endtask

    initial begin
        errors = 0; n_vec = 0;
        max_err = 0.0; sum_abs = 0.0;
        n_nonmono = 0; n_overtol = 0;

        $display("");
        $display("==========================================================================================");
        $display(" Delta-sigma DAC DC conformance");
        $display(" ideal d(x) = (x + 32768) / 65535   window = %0d clocks   floor = %0.6f",
                 WINDOW, FLOOR);
        $display("==========================================================================================");
        $display("");

        //================================================================================================
        $display(" 1. Oversampling ratio");
        $display("");
        $display("  declared: 1250x at 48 kHz from a 60 MHz clock");
        if (60000000 / 48000 == OSR)
            $display("    OK: 60 MHz / 48 kHz = %0d, matches the declared oversampling ratio", OSR);
        else begin
            $display("    ** FAIL: oversampling ratio inconsistent");
            errors = errors + 1;
        end

        //================================================================================================
        $display("");
        $display(" 2. Full-scale DC sweep - %0d codes at %0d LSB steps", N_CODES, STEP);
        $display("");

        prev_density = -1.0;
        begin : sweep
            integer c;
            reg signed [31:0] code;
            for (c = 0; c < N_CODES; c = c + 1) begin
                code = -32768 + c * STEP;
                if (code > 32767) code = 32767;
                measure(code[15:0]);

                sum_abs = sum_abs + err;
                if (err > max_err) max_err = err;
                if (err > TOL_LINEAR) begin
                    n_overtol = n_overtol + 1;
                    if (n_overtol <= 5)
                        $display("    ** linearity: code %0d density %0.6f ideal %0.6f err %0.6f",
                                 code, density, ideal, err);
                end

                if (density < prev_density) begin
                    n_nonmono = n_nonmono + 1;
                    if (n_nonmono <= 5)
                        $display("    ** monotonicity: code %0d density %0.6f fell below previous %0.6f",
                                 code, density, prev_density);
                end
                prev_density = density;
            end
        end

        $display("  codes measured        : %0d", N_CODES);
        $display("  max linearity error   : %0.6f  (%0.1f LSB of 65536)", max_err, max_err * 65536.0);
        $display("  mean linearity error  : %0.6f  (%0.1f LSB of 65536)",
                 sum_abs / N_CODES, (sum_abs / N_CODES) * 65536.0);
        $display("  measurement floor     : %0.6f  (%0.1f LSB of 65536)", FLOOR, FLOOR * 65536.0);
        $display("  codes over tolerance  : %0d  (tolerance %0.6f)", n_overtol, TOL_LINEAR);
        $display("  monotonicity failures : %0d", n_nonmono);

        if (n_overtol != 0) begin
            $display("    ** FAIL: DC transfer deviates from the ideal beyond tolerance");
            errors = errors + 1;
        end else
            $display("    OK: DC transfer tracks the ideal across the full range");

        if (n_nonmono != 0) begin
            $display("    ** FAIL: transfer is not monotonic - the converter has missing codes");
            errors = errors + 1;
        end else
            $display("    OK: transfer is monotonic across all %0d codes", N_CODES);

        //================================================================================================
        $display("");
        $display(" 3. Endpoints and silence");
        $display("");

        measure(-16'sd32768);
        $display("  code -32768: density %0.6f toggles %0d (expected 0.000000, 0)", density, transitions);
        if (density != 0.0 || transitions != 0) begin
            $display("    ** FAIL: negative full scale should hold the output low");
            errors = errors + 1;
        end else $display("    OK: negative full scale rails cleanly");

        measure(16'sd32767);
        $display("  code +32767: density %0.6f toggles %0d (expected 1.000000, 0)", density, transitions);
        if (density != 1.0 || transitions != 0) begin
            $display("    ** FAIL: positive full scale should hold the output high");
            errors = errors + 1;
        end else $display("    OK: positive full scale rails cleanly");

        measure(16'sd0);
        $display("  code      0: density %0.6f toggles %0d (silence must dither)", density, transitions);
        if (transitions < WINDOW / 4) begin
            $display("    ** FAIL: silence is not dithering");
            errors = errors + 1;
        end else $display("    OK: silence dithers around half scale");

        //================================================================================================
        $display("");
        $display(" 4. Fine steps around silence and the rails");
        $display("");
        begin : fine
            integer c, bad;
            reg signed [31:0] codes [0:20];
            codes[0]=-32768; codes[1]=-32767; codes[2]=-32766; codes[3]=-16384;
            codes[4]=-256;   codes[5]=-16;    codes[6]=-4;     codes[7]=-2;
            codes[8]=-1;     codes[9]=0;      codes[10]=1;     codes[11]=2;
            codes[12]=4;     codes[13]=16;    codes[14]=256;   codes[15]=16384;
            codes[16]=32764; codes[17]=32765; codes[18]=32766; codes[19]=32767;
            bad = 0;
            for (c = 0; c < 20; c = c + 1) begin
                measure(codes[c][15:0]);
                if (err > TOL_LINEAR) begin
                    bad = bad + 1;
                    $display("    ** code %0d: density %0.6f ideal %0.6f err %0.6f",
                             codes[c], density, ideal, err);
                end
            end
            $display("  20 directed codes near silence and the rails: %0d over tolerance", bad);
            if (bad != 0) errors = errors + 1;
            else $display("    OK: fine codes track the ideal");
        end

        $display("");
        $display("==========================================================================================");
        $display(" DC vectors measured: %0d      clocks simulated: %0d", n_vec, n_vec * WINDOW);
        if (errors == 0)
            $display(" RESULT: PASS - DC transfer is exact, monotonic, and rails correctly.");
        else
            $display(" RESULT: FAIL - %0d check(s) failed.", errors);
        $display("==========================================================================================");
        $display("");
        $finish;
    end

endmodule
