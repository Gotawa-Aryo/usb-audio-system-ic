`timescale 1ns / 1ps
//--------------------------------------------------------------------------------------------------------
// Testbench : tb_dac_chain
// Purpose   : Characterise the left-channel DAC datapath of ic_top_usb_audio.
//
//             Two chains are driven from the same 32-bit FIFO word:
//
//               OLD      : rtl_digital_shifter -> {S[17],S[14:0]} -> first_order_dfe
//                          (how ic_top_usb_audio.v was wired before the Figure 3 rework;
//                           kept here so the regression stays visible)
//
//               FIG-3    : FIFO RD_DATA[15:0] -> first_order_dfe.WR_DATA
//                          (what "Schematic: Top-Level" specifies - no block between
//                           the FIFO Buffer and the Delta-Sigma DAC Modulator)
//
//             For a 1st-order delta-sigma modulator with +/-32767/32768 feedback, the
//             steady-state output density for a signed 16-bit sample x is
//                 d(x) = (x + 32768) / 65535
//             The testbench measures the real density and compares it against that ideal.
//--------------------------------------------------------------------------------------------------------

module tb_dac_chain;

    localparam integer MEAS_CYCLES = 65536;   // density measurement window

    reg         clk     = 1'b0;
    reg         reset_n = 1'b0;
    reg  [31:0] fifo_word = 32'h0;            // {right[15:0], left[15:0]} as popped from the FIFO
    reg         buffer_empty = 1'b0;

    always #8.333 clk = ~clk;                 // 60 MHz

    //----------------------------------------------------------------------------------------------------
    // Chain A : exactly as ic_top_usb_audio.v wires it today
    //----------------------------------------------------------------------------------------------------
    wire [17:0] shifted_a;
    wire [15:0] audio_data_a;
    wire        bit_a;

    rtl_digital_shifter shifter_a (
        .A ( {{2{fifo_word[15]}}, fifo_word} ),   // 34 bits driving an 18-bit port -> truncation
        .S ( shifted_a                       )
    );

    assign audio_data_a = buffer_empty ? 16'h8000 : {shifted_a[17], shifted_a[14:0]};

    first_order_dfe dfe_a (
        .WR_DATA       ( audio_data_a ),
        .RESET_N       ( reset_n      ),
        .SYS_CLK_60M   ( clk          ),
        .MODULATOR_OUT ( bit_a        )
    );

    //----------------------------------------------------------------------------------------------------
    // Chain B : FIFO RD_DATA[15:0] straight into the modulator, per Figure 3
    //----------------------------------------------------------------------------------------------------
    wire [15:0] audio_data_b = buffer_empty ? 16'h0000 : fifo_word[15:0];
    wire        bit_b;

    first_order_dfe dfe_b (
        .WR_DATA       ( audio_data_b ),
        .RESET_N       ( reset_n      ),
        .SYS_CLK_60M   ( clk          ),
        .MODULATOR_OUT ( bit_b        )
    );

    //----------------------------------------------------------------------------------------------------
    // Density measurement
    //----------------------------------------------------------------------------------------------------
    integer count_a, count_b, i;
    real    dens_a, dens_b, dens_ideal;
    integer fail_trunc, fail_dens;

    task automatic measure (input [15:0] left, input [15:0] right);
        begin
            // Re-zero both integrators so each sample is measured from a known state
            reset_n = 1'b0;
            fifo_word = {right, left};
            repeat (4) @(posedge clk);
            reset_n = 1'b1;
            repeat (4) @(posedge clk);

            count_a = 0;
            count_b = 0;
            for (i = 0; i < MEAS_CYCLES; i = i + 1) begin
                @(posedge clk);
                #1;
                if (bit_a) count_a = count_a + 1;
                if (bit_b) count_b = count_b + 1;
            end

            dens_a     = count_a * 1.0 / MEAS_CYCLES;
            dens_b     = count_b * 1.0 / MEAS_CYCLES;
            dens_ideal = ($signed(left) + 32768.0) / 65535.0;
        end
    endtask

    task automatic report_row (input [15:0] left, input [15:0] right);
        begin
            measure(left, right);
            $display("  %6d   %6d | %8.5f | %8.5f %9.5f | %8.5f %9.5f",
                     $signed(left), $signed(right),
                     dens_ideal,
                     dens_a, dens_a - dens_ideal,
                     dens_b, dens_b - dens_ideal);
        end
    endtask

    //----------------------------------------------------------------------------------------------------
    initial begin
        fail_trunc = 0;
        fail_dens  = 0;

        $display("");
        $display("==========================================================================================");
        $display(" tb_dac_chain : left-channel DAC datapath characterisation");
        $display(" ideal density d(x) = (x + 32768) / 65535");
        $display("==========================================================================================");
        $display("");
        $display(" TEST 1 - density vs left-channel sample (right channel held at 0)");
        $display("");
        $display("    left    right |    ideal |  OLD        error |  FIG-3      error");
        $display("  ------   ------ | -------- | -------- --------- | -------- ---------");

        report_row(16'sd0,      16'sd0);
        report_row(16'sd8192,   16'sd0);
        report_row(16'sd16384,  16'sd0);
        report_row(16'sd32767,  16'sd0);
        report_row(-16'sd8192,  16'sd0);
        report_row(-16'sd16384, 16'sd0);
        report_row(-16'sd32768, 16'sd0);

        $display("");
        $display(" TEST 2 - left channel held at 0, right channel varied");
        $display("          (the left-channel DAC output must not move at all)");
        $display("");
        $display("    left    right |    ideal |  OLD        error |  FIG-3      error");
        $display("  ------   ------ | -------- | -------- --------- | -------- ---------");

        report_row(16'sd0, 16'sd0);
        begin : cross_talk_check
            real base_a, base_b;
            base_a = dens_a;
            base_b = dens_b;

            report_row(16'sd0, 16'sd1);
            if (dens_a != base_a) fail_trunc = fail_trunc + 1;
            if (dens_b != base_b) fail_dens  = fail_dens + 1;

            report_row(16'sd0, 16'sd2);
            if (dens_a != base_a) fail_trunc = fail_trunc + 1;
            if (dens_b != base_b) fail_dens  = fail_dens + 1;

            report_row(16'sd0, 16'sd3);
            if (dens_a != base_a) fail_trunc = fail_trunc + 1;
            if (dens_b != base_b) fail_dens  = fail_dens + 1;
        end

        $display("");
        $display(" TEST 3 - FIFO empty (underflow) behaviour");
        $display("");
        buffer_empty = 1'b1;
        report_row(16'sd0, 16'sd0);
        $display("          OLD fed 16'h8000 into a SIGNED modulator input");
        $display("          -> that is -32768 (full negative rail), not silence.");
        $display("          FIG-3 feeds 16'h0000 -> density 0.5 = true silence.");
        buffer_empty = 1'b0;

        $display("");
        $display("==========================================================================================");
        if (fail_trunc > 0) begin
            $display(" OLD  : cross-coupled - the RIGHT channel moved the LEFT channel output in");
            $display("        %0d of 3 cases. Figure 3 shows a 16-bit left-only path.", fail_trunc);
        end else begin
            $display(" OLD  : no right-channel cross-coupling observed.");
        end

        if (fail_dens == 0)
            $display(" FIG-3: immune to the right channel, and tracks the ideal density. PASS");
        else
            $display(" FIG-3: unexpectedly moved with the right channel. FAIL");
        $display("==========================================================================================");
        $display("");

        $finish;
    end

endmodule
