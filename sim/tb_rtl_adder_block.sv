`timescale 1ns / 1ps
//--------------------------------------------------------------------------------------------------------
// Testbench : tb_rtl_adder_block
// DUT       : rtl_adder_block - 18-bit signed adder inside the Delta-Sigma DAC Modulator (block 1.4)
//
// The modulator relies on this adder WRAPPING rather than saturating: the integrator is
// allowed to run past 18 bits and fold, which is what keeps the loop stable. So the
// reference model is a plain modulo-2^18 add, and the overflow cases below are expected
// behaviour, not defects.
//--------------------------------------------------------------------------------------------------------

module tb_rtl_adder_block;

    localparam integer N_RANDOM = 20000;

    reg  signed [17:0] A, B;
    wire signed [17:0] S;

    integer errors = 0;
    integer i;

    rtl_adder_block dut (.A(A), .B(B), .S(S));

    task automatic expect_sum (input signed [17:0] a, input signed [17:0] b, input [255:0] label);
        reg signed [17:0] want;
        begin
            A = a;
            B = b;
            #1;
            want = (a + b);                       // wraps naturally at 18 bits
            if (S !== want) begin
                $display("  FAIL %0s: A=%0d B=%0d -> S=%0d, expected %0d", label, a, b, S, want);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $display("");
        $display("==========================================================================================");
        $display(" tb_rtl_adder_block : 18-bit signed adder");
        $display("==========================================================================================");
        $display("");

        $display(" directed cases");
        expect_sum( 18'sd0,       18'sd0,       "zero + zero");
        expect_sum( 18'sd1,       18'sd1,       "one + one");
        expect_sum( 18'sd32767,   18'sd1,       "16-bit max + 1");
        expect_sum(-18'sd32768,  -18'sd1,       "16-bit min - 1");
        expect_sum( 18'sd131071,  18'sd0,       "18-bit max + 0");
        expect_sum(-18'sd131072,  18'sd0,       "18-bit min + 0");
        expect_sum( 18'sd100,    -18'sd100,     "x + (-x)");
        expect_sum(-18'sd50,      18'sd120,     "negative + positive");

        $display(" overflow wrap cases (expected to fold, not saturate)");
        expect_sum( 18'sd131071,  18'sd1,       "18-bit max + 1 wraps to min");
        expect_sum(-18'sd131072, -18'sd1,       "18-bit min - 1 wraps to max");
        expect_sum( 18'sd131071,  18'sd131071,  "max + max");

        // the two feedback constants the modulator actually uses
        $display(" modulator feedback constants");
        expect_sum( 18'sd32767,   18'sd32767,   "+32767 + +32767");
        expect_sum(-18'sd32768,  -18'sd32768,   "-32768 + -32768");

        $display(" %0d randomised cases", N_RANDOM);
        for (i = 0; i < N_RANDOM; i = i + 1) begin
            expect_sum($urandom(), $urandom(), "random");
        end

        $display("");
        $display("==========================================================================================");
        if (errors == 0)
            $display(" RESULT: PASS - all cases match the modulo-2^18 reference.");
        else
            $display(" RESULT: FAIL - %0d mismatch(es).", errors);
        $display("==========================================================================================");
        $display("");
        $finish;
    end

endmodule
