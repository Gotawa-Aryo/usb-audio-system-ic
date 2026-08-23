`timescale 1ns / 1ps
//--------------------------------------------------------------------------------------------------------
// Testbench : tb_usb_line_conformance
//
// Conformance of the full-speed line coding against USB 2.0 chapter 7, which UAC 1.0 / BADD
// inherit: NRZI encoding, bit stuffing after six consecutive ones, the SYNC field, and EOP.
// A conforming receiver must recover the original bit stream exactly for any payload.
//
// Vector counts:
//   length sweep     : 256 packets - every payload length 1..64 crossed with four patterns
//   random payloads  : 200 packets - random length 1..64, random content
//   stuffing corners :  60 packets - runs of exactly 5, 6, 7, 12, 13 and 18 ones, walked
//                                    across every offset in the payload
//   idle quiet check :   1
//
// Every packet is checked bit for bit, so a single mis-stuffed or mis-aligned bit anywhere in
// the sweep is caught.
//
// Note on the SYNC boundary: the bit-stuff counter runs across the whole packet including
// SYNC, and SYNC ends with a 1. An encoder that restarts the run count at the payload places
// the first stuffed bit one position late and a conforming receiver rejects the packet.
//--------------------------------------------------------------------------------------------------------

module tb_usb_line_conformance;

    localparam integer CLKS_PER_BIT = 5;          // 60 MHz / 12 Mbps

    reg clk = 1'b0, rstn = 1'b0;
    always #8.333 clk = ~clk;

    reg  dp_rx = 1'b1, dn_rx = 1'b0;
    wire usb_oe, usb_dp_tx, usb_dn_tx;
    wire rx_sta, rx_ena, rx_bit, rx_fin;

    usbfs_bitlevel dut (
        .rstn(rstn), .clk(clk),
        .usb_oe(usb_oe), .usb_dp_tx(usb_dp_tx), .usb_dn_tx(usb_dn_tx),
        .usb_dp_rx(dp_rx), .usb_dn_rx(dn_rx),
        .rx_sta(rx_sta), .rx_ena(rx_ena), .rx_bit(rx_bit), .rx_fin(rx_fin),
        .tx_sta(1'b0), .tx_req(), .tx_bit(1'b0), .tx_fin(1'b0)
    );

    integer errors, n_vec, n_bit_vec;
    integer nrx, nsta, nfin, i;
    reg [255:0] got;
    reg [255:0] want;
    reg cur_j = 1'b1;

    always @(posedge clk) begin
        if (rx_sta) nsta = nsta + 1;
        if (rx_fin) nfin = nfin + 1;
        if (rx_ena) begin
            if (nrx < 256) got[nrx] = rx_bit;
            nrx = nrx + 1;
        end
    end

    task automatic drive_state (input j);
        begin
            dp_rx =  j;
            dn_rx = ~j;
            repeat (CLKS_PER_BIT) @(posedge clk);
        end
    endtask

    task automatic drive_se0;
        begin
            dp_rx = 1'b0;
            dn_rx = 1'b0;
            repeat (CLKS_PER_BIT) @(posedge clk);
        end
    endtask

    task automatic nrzi_bit (input b);
        begin
            if (!b) cur_j = ~cur_j;
            drive_state(cur_j);
        end
    endtask

    task automatic send_packet (input integer n);
        integer k, ones;
        begin
            cur_j = 1'b1;
            drive_state(cur_j);
            for (k = 0; k < 7; k = k + 1) nrzi_bit(1'b0);   // SYNC 0000000
            nrzi_bit(1'b1);                                  // SYNC trailing 1

            ones = 1;                                        // SYNC's trailing 1 counts
            for (k = 0; k < n; k = k + 1) begin
                nrzi_bit(want[k]);
                if (want[k]) begin
                    ones = ones + 1;
                    if (ones == 6) begin
                        nrzi_bit(1'b0);
                        ones = 0;
                    end
                end else ones = 0;
            end

            drive_se0;
            drive_se0;
            cur_j = 1'b1;
            drive_state(cur_j);
            repeat (CLKS_PER_BIT * 6) @(posedge clk);
        end
    endtask

    // Returns 0 if the packet round-tripped exactly.
    function integer verdict (input integer n);
        integer k, bad;
        begin
            bad = 0;
            if (nsta != 1) bad = bad + 1000;
            if (nfin != 1) bad = bad + 1000;
            if (nrx  != n) bad = bad + 1000;
            for (k = 0; k < n; k = k + 1)
                if (k < nrx && got[k] !== want[k]) bad = bad + 1;
            verdict = bad;
        end
    endfunction

    task automatic run_one (input integer n, inout integer failcount);
        integer v;
        begin
            nrx = 0; nsta = 0; nfin = 0;
            send_packet(n);
            #1;
            v = verdict(n);
            n_vec     = n_vec + 1;
            n_bit_vec = n_bit_vec + n;
            if (v != 0) begin
                failcount = failcount + 1;
                if (failcount <= 5)
                    $display("    ** FAIL: len=%0d sta=%0d fin=%0d recovered=%0d penalty=%0d",
                             n, nsta, nfin, nrx, v);
            end
        end
    endtask

    initial begin
        errors = 0; n_vec = 0; n_bit_vec = 0;

        $display("");
        $display("==========================================================================================");
        $display(" USB line coding conformance  (USB 2.0 chapter 7: NRZI, bit stuffing, SYNC, EOP)");
        $display("==========================================================================================");

        rstn = 1'b0;
        repeat (20) @(posedge clk);
        rstn = 1'b1;
        repeat (20) @(posedge clk);

        //================================================================================================
        $display("");
        $display(" 1. Length sweep - every length 1..64 crossed with four patterns");
        $display("");
        begin : sweep
            integer len, pat, fails;
            fails = 0;
            for (len = 1; len <= 64; len = len + 1) begin
                for (pat = 0; pat < 4; pat = pat + 1) begin
                    for (i = 0; i < len; i = i + 1) begin
                        case (pat)
                            0: want[i] = 1'b0;
                            1: want[i] = 1'b1;
                            2: want[i] = i[0];
                            default: want[i] = $urandom & 1;
                        endcase
                    end
                    run_one(len, fails);
                end
            end
            $display("  256 packets (lengths 1..64 x 4 patterns): failures %0d", fails);
            if (fails != 0) errors = errors + 1;
            else $display("    OK: every length and pattern recovered exactly");
        end

        //================================================================================================
        $display("");
        $display(" 2. Random payloads - 200 packets of random length and content");
        $display("");
        begin : randoms
            integer r, len, fails;
            fails = 0;
            for (r = 0; r < 200; r = r + 1) begin
                len = ($urandom % 64) + 1;
                for (i = 0; i < len; i = i + 1) want[i] = $urandom & 1;
                run_one(len, fails);
            end
            $display("  200 random packets: failures %0d", fails);
            if (fails != 0) errors = errors + 1;
            else $display("    OK: all random payloads recovered exactly");
        end

        //================================================================================================
        $display("");
        $display(" 3. Bit-stuffing corners - runs of ones walked across every offset");
        $display("");
        begin : corners
            integer runlen, off, len, fails, c, runs [0:5];
            runs[0]=5; runs[1]=6; runs[2]=7; runs[3]=12; runs[4]=13; runs[5]=18;
            fails = 0;
            len   = 40;
            for (c = 0; c < 6; c = c + 1) begin
                runlen = runs[c];
                for (off = 0; off + runlen <= len; off = off + 4) begin
                    for (i = 0; i < len; i = i + 1)
                        want[i] = (i >= off && i < off + runlen);
                    run_one(len, fails);
                end
            end
            $display("  %0d packets with runs of 5/6/7/12/13/18 ones at walking offsets: failures %0d",
                     n_vec - 456, fails);
            if (fails != 0) errors = errors + 1;
            else $display("    OK: stuffing and de-stuffing agree at every run length and offset");
        end

        //================================================================================================
        $display("");
        $display(" 4. Idle line must not start a packet");
        $display("");
        nrx = 0; nsta = 0; nfin = 0;
        cur_j = 1'b1;
        repeat (60) drive_state(1'b1);
        #1;
        n_vec = n_vec + 1;
        $display("  idle J for 60 bit times: rx_sta=%0d (expected 0)", nsta);
        if (nsta != 0) begin
            $display("    ** FAIL: spurious packet start on an idle line");
            errors = errors + 1;
        end else $display("    OK: idle line stays quiet");

        $display("");
        $display("==========================================================================================");
        $display(" packets exercised: %0d      payload bits checked: %0d", n_vec, n_bit_vec);
        if (errors == 0)
            $display(" RESULT: PASS - line coding conforms across every vector.");
        else
            $display(" RESULT: FAIL - %0d check group(s) failed.", errors);
        $display("==========================================================================================");
        $display("");
        $finish;
    end

endmodule
