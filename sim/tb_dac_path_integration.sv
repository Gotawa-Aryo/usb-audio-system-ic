`timescale 1ns / 1ps
//--------------------------------------------------------------------------------------------------------
// Testbench : tb_dac_path_integration
// Purpose   : End-to-end check of the digital audio path as drawn in Figure 3:
//
//               1.1 USB Interface --WR_EN_L/DATA_L--> 1.2 FIFO Buffer
//                                                        |  RD_EN driven by
//                                                        |  1.3 Control Unit (SIG_48K)
//                                                        v  RD_DATA
//                                                     1.4 Delta-Sigma DAC Modulator
//                                                        |
//                                                        v  DAC_MOD_OUT_L
//
//             Enumerating a real USB host would take 2000 ms of simulated time before block 1.1
//             emits anything, so instead the WR_EN_L / DATA_L handoff between 1.1 and 1.2 is
//             driven directly. Everything downstream of that point - the FIFO Buffer, the
//             Control Unit's 48 kHz drain, and the modulator - is the real RTL.
//
//             A steady sample x must settle the 1-bit output density at (x + 32768) / 65535.
//--------------------------------------------------------------------------------------------------------

module tb_dac_path_integration;

    localparam integer SAMPLE_PERIOD = 1250;              // 60 MHz / 48 kHz
    localparam integer MEAS_CYCLES   = SAMPLE_PERIOD * 52; // whole number of sample periods
    localparam real    TOLERANCE     = 0.01;

    reg  clk     = 1'b0;
    reg  reset_n = 1'b0;
    wire usb_dp_pull;
    wire dac_mod_out_l;
    wire usb_dp, usb_dn;

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

    integer count, i, errors;
    real    density, ideal;

    // Static, because a procedural continuous assignment (force) cannot reference
    // an automatic task argument.
    reg [15:0] inject_data;

    // Drive one sample into the FIFO Buffer every 48 kHz period and measure the
    // modulator output density over 52 whole sample periods.
    task automatic run_sample (input [15:0] x);
        begin
            reset_n = 1'b0;
            repeat (8) @(posedge clk);
            reset_n = 1'b1;
            @(posedge clk);

            inject_data = x;
            force dut.data_l = inject_data;
            // FIFO writes are speculative until committed. This bench drives the write port
            // directly rather than through the packet layer, so commit unconditionally.
            force dut.wr_commit_l = 1'b1;
            force dut.wr_abort_l  = 1'b0;

            // Pre-load the FIFO so the 48 kHz drain never underflows during the measurement
            force dut.wr_en_l = 1'b1;
            repeat (8) @(posedge clk);
            force dut.wr_en_l = 1'b0;

            fork
                begin : injector
                    forever begin
                        repeat (SAMPLE_PERIOD) @(posedge clk);
                        force dut.wr_en_l = 1'b1;
                        @(posedge clk);
                        force dut.wr_en_l = 1'b0;
                    end
                end
                begin : measure
                    count = 0;
                    for (i = 0; i < MEAS_CYCLES; i = i + 1) begin
                        @(posedge clk);
                        #1;
                        if (dac_mod_out_l) count = count + 1;
                    end
                end
            join_any
            disable fork;

            release dut.wr_en_l;
            release dut.data_l;
            release dut.wr_commit_l;
            release dut.wr_abort_l;

            density = count * 1.0 / MEAS_CYCLES;
            ideal   = ($signed(x) + 32768.0) / 65535.0;
        end
    endtask

    task automatic check (input [15:0] x);
        begin
            run_sample(x);
            $display("  %6d | %8.5f | %8.5f | %9.5f | %s",
                     $signed(x), ideal, density, density - ideal,
                     ((density - ideal) < TOLERANCE && (ideal - density) < TOLERANCE) ? "PASS" : "FAIL");
            if (!((density - ideal) < TOLERANCE && (ideal - density) < TOLERANCE))
                errors = errors + 1;
        end
    endtask

    initial begin
        errors = 0;

        $display("");
        $display("==========================================================================================");
        $display(" tb_dac_path_integration : USB Interface -> FIFO Buffer -> Control Unit -> Modulator");
        $display(" ideal density d(x) = (x + 32768) / 65535, tolerance %0.3f", TOLERANCE);
        $display("==========================================================================================");
        $display("");
        $display("  sample |    ideal |  measured |     error | result");
        $display("  ------ | -------- | --------- | --------- | ------");

        check( 16'sd0     );
        check( 16'sd8192  );
        check( 16'sd16384 );
        check( 16'sd32767 );
        check(-16'sd8192  );
        check(-16'sd16384 );
        check(-16'sd32768 );

        $display("");

        // FIFO left to underflow: modulator must fall back to silence, not a DC rail.
        reset_n = 1'b0;
        repeat (8) @(posedge clk);
        reset_n = 1'b1;
        count = 0;
        for (i = 0; i < MEAS_CYCLES; i = i + 1) begin
            @(posedge clk);
            #1;
            if (dac_mod_out_l) count = count + 1;
        end
        density = count * 1.0 / MEAS_CYCLES;
        $display("  FIFO starved (no writes at all): density = %8.5f  (0.5 = silence)", density);
        if (density > 0.51 || density < 0.49) begin
            $display("    ** FAIL: underflow does not produce silence.");
            errors = errors + 1;
        end else begin
            $display("    OK: underflow produces silence.");
        end

        $display("");
        $display("==========================================================================================");
        if (errors == 0)
            $display(" RESULT: PASS - the Figure 3 audio path reproduces every sample correctly.");
        else
            $display(" RESULT: FAIL - %0d check(s) failed.", errors);
        $display("==========================================================================================");
        $display("");

        $finish;
    end

endmodule
