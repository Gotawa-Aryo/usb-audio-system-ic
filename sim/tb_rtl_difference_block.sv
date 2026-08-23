`timescale 1ns / 1ps
//--------------------------------------------------------------------------------------------------------
// Testbench : tb_rtl_difference_block
// DUT       : rtl_difference_block - 18-bit signed subtractor inside the Delta-Sigma DAC
//             Modulator (block 1.4). Computes the loop error, sample minus feedback.
//
// Like the adder, this wraps at 18 bits rather than saturating. The cases that matter most
// are the ones the modulator actually generates: sample minus +32767 and sample minus -32768.
//--------------------------------------------------------------------------------------------------------

module tb_rtl_difference_block;

    localparam integer N_RANDOM = 20000;

    reg  signed [17:0] A, B;
    wire signed [17:0] S;

    integer errors = 0;
    integer i;

    rtl_difference_block dut (.A(A), .B(B), .S(S));

    task automatic expect_diff (input signed [17:0] a, input signed [17:0] b, input [255:0] label);
        reg signed [17:0] want;
        begin
            A = a;
            B = b;
            #1;
            want = (a - b);                       // wraps naturally at 18 bits
            if (S !== want) begin
                $display("  FAIL %0s: A=%0d B=%0d -> S=%0d, expected %0d", label, a, b, S, want);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $display("");
        $display("==========================================================================================");
        $display(" tb_rtl_difference_block : 18-bit signed subtractor");
        $display("==========================================================================================");
        $display("");

        $display(" directed cases");
        expect_diff( 18'sd0,       18'sd0,       "zero - zero");
        expect_diff( 18'sd100,     18'sd100,     "x - x = 0");
        expect_diff( 18'sd0,       18'sd1,       "0 - 1");
        expect_diff( 18'sd131071,  18'sd0,       "18-bit max - 0");
        expect_diff(-18'sd131072,  18'sd0,       "18-bit min - 0");
        expect_diff( 18'sd50,     -18'sd50,      "x - (-x)");

        $display(" overflow wrap cases (expected to fold, not saturate)");
        expect_diff(-18'sd131072,  18'sd1,       "18-bit min - 1 wraps to max");
        expect_diff( 18'sd131071, -18'sd1,       "18-bit max + 1 wraps to min");

        // exactly the two feedback subtractions the modulator performs every cycle
        $display(" modulator loop-error cases");
        expect_diff( 18'sd0,       18'sd32767,   "silence - (+32767 feedback)");
        expect_diff( 18'sd0,      -18'sd32768,   "silence - (-32768 feedback)");
        expect_diff( 18'sd32767,   18'sd32767,   "full positive sample - (+32767)");
        expect_diff(-18'sd32768,  -18'sd32768,   "full negative sample - (-32768)");

        $display(" %0d randomised cases", N_RANDOM);
        for (i = 0; i < N_RANDOM; i = i + 1) begin
            expect_diff($urandom(), $urandom(), "random");
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
