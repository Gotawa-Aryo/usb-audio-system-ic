`timescale 1ns / 1ps
//--------------------------------------------------------------------------------------------------------
// Testbench : tb_rtl_digital_shifter
// DUT       : rtl_digital_shifter - S = A - 18'b11_1000_0000_0000_0000
//
// NOTE: this module is no longer instantiated by the design. Figure 3 takes the FIFO's
//       RD_DATA straight into the modulator's WR_DATA with no block in between, so it was
//       removed from the datapath. The file and this testbench are kept because
//       sim/tb_dac_chain.sv still uses the module as the pre-rework reference.
//
// The subtrahend 18'h38000 is -32768 when read as a signed 18-bit value, so the block
// really performs S = A + 32768: a signed-to-offset-binary conversion. This testbench
// pins down that behaviour, and confirms the property the old datapath was relying on -
// that a sign-extended 16-bit sample maps onto the full unsigned 0..65535 range.
//--------------------------------------------------------------------------------------------------------

module tb_rtl_digital_shifter;

    localparam integer N_RANDOM = 20000;

    reg  signed [17:0] A;
    wire signed [17:0] S;

    integer errors = 0;
    integer i;
    reg signed [15:0] sample;
    reg        [17:0] got;

    rtl_digital_shifter dut (.A(A), .S(S));

    task automatic expect_shift (input signed [17:0] a, input [255:0] label);
        reg signed [17:0] want;
        begin
            A = a;
            #1;
            want = a - 18'sh38000;
            if (S !== want) begin
                $display("  FAIL %0s: A=%0d -> S=%0d, expected %0d", label, a, S, want);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $display("");
        $display("==========================================================================================");
        $display(" tb_rtl_digital_shifter : S = A - 18'h38000, i.e. a +32768 offset");
        $display("==========================================================================================");
        $display("");

        $display(" directed cases");
        expect_shift( 18'sd0,      "zero");
        expect_shift( 18'sd1,      "one");
        expect_shift(-18'sd1,      "minus one");
        expect_shift( 18'sd32767,  "16-bit max");
        expect_shift(-18'sd32768,  "16-bit min");
        expect_shift( 18'sd131071, "18-bit max");
        expect_shift(-18'sd131072, "18-bit min");

        $display("");
        $display(" offset-binary property: sign-extended 16-bit sample -> unsigned 0..65535");
        $display("");
        $display("   sample | S (unsigned) | expected");
        $display("   ------ | ------------ | --------");
        begin : offset_check
            integer k;
            reg [17:0] want_u;
            for (k = 0; k < 5; k = k + 1) begin
                case (k)
                    0: sample = -16'sd32768;
                    1: sample = -16'sd16384;
                    2: sample =  16'sd0;
                    3: sample =  16'sd16384;
                    4: sample =  16'sd32767;
                endcase
                A = {{2{sample[15]}}, sample};
                #1;
                got    = S;
                want_u = sample + 32768;
                $display("   %6d | %12d | %8d", sample, got, want_u);
                if (got !== want_u) begin
                    $display("     ** FAIL: offset-binary mapping is wrong");
                    errors = errors + 1;
                end
                if (got > 18'd65535) begin
                    $display("     ** FAIL: result escaped the 16-bit unsigned range");
                    errors = errors + 1;
                end
            end
        end

        $display("");
        $display(" %0d randomised cases", N_RANDOM);
        for (i = 0; i < N_RANDOM; i = i + 1) begin
            expect_shift($urandom(), "random");
        end

        $display("");
        $display("==========================================================================================");
        if (errors == 0)
            $display(" RESULT: PASS - the block adds 32768 modulo 2^18, as the old datapath assumed.");
        else
            $display(" RESULT: FAIL - %0d mismatch(es).", errors);
        $display("==========================================================================================");
        $display("");
        $finish;
    end

endmodule
