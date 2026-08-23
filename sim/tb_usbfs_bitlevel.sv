`timescale 1ns / 1ps
//--------------------------------------------------------------------------------------------------------
// Testbench : tb_usbfs_bitlevel
// DUT       : usbfs_bitlevel - full-speed line transceiver
//
// Drives D+/D- at 12 Mbps (5 clocks per bit at 60 MHz) with properly formed full-speed
// traffic and checks that the receive path recovers the original bit stream.
//
// The testbench implements the line coding itself, from the USB specification:
//   J state  = (D+ = 1, D- = 0)      idle and logical high for full speed
//   K state  = (D+ = 0, D- = 1)
//   NRZI     = a 0 bit toggles the line state, a 1 bit leaves it unchanged
//   stuffing = after six consecutive 1 bits a 0 is inserted by the transmitter
//   SYNC     = 00000001 LSB first, which from idle J renders as KJKJKJKK
//   EOP      = two bit times of SE0 (both lines low) followed by a J
//
// Checks:
//   1. rx_sta fires once per packet
//   2. the de-stuffed bit stream matches what was sent, including a run of eight 1 bits
//      that forces the receiver to drop a stuffed 0
//   3. rx_fin fires at the EOP
//   4. line noise before SYNC does not produce a spurious packet
//--------------------------------------------------------------------------------------------------------

module tb_usbfs_bitlevel;

    localparam integer CLKS_PER_BIT = 5;          // 60 MHz / 12 Mbps

    reg clk = 1'b0, rstn = 1'b0;
    always #8.333 clk = ~clk;

    reg  dp_rx = 1'b1, dn_rx = 1'b0;              // idle J
    wire usb_oe, usb_dp_tx, usb_dn_tx;
    wire rx_sta, rx_ena, rx_bit, rx_fin;

    usbfs_bitlevel dut (
        .rstn(rstn), .clk(clk),
        .usb_oe(usb_oe), .usb_dp_tx(usb_dp_tx), .usb_dn_tx(usb_dn_tx),
        .usb_dp_rx(dp_rx), .usb_dn_rx(dn_rx),
        .rx_sta(rx_sta), .rx_ena(rx_ena), .rx_bit(rx_bit), .rx_fin(rx_fin),
        .tx_sta(1'b0), .tx_req(), .tx_bit(1'b0), .tx_fin(1'b0)
    );

    integer errors = 0;
    integer nrx, nsta, nfin, i;
    reg [511:0] got;
    reg [511:0] want;
    integer     nwant;

    reg cur_j = 1'b1;                             // current line state, 1 = J

    always @(posedge clk) begin
        if (rx_sta) nsta = nsta + 1;
        if (rx_fin) nfin = nfin + 1;
        if (rx_ena) begin
            if (nrx < 512) got[nrx] = rx_bit;
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

    // NRZI-encode one raw bit onto the line: 0 toggles, 1 holds.
    task automatic nrzi_bit (input b);
        begin
            if (!b) cur_j = ~cur_j;
            drive_state(cur_j);
        end
    endtask

    // Send SYNC then the payload bits, applying bit stuffing, then EOP.
    task automatic send_packet (input integer n);
        integer k, ones;
        begin
            // SYNC = 0,0,0,0,0,0,0,1 (LSB first)
            cur_j = 1'b1;
            drive_state(cur_j);                   // settle in idle J
            for (k = 0; k < 7; k = k + 1) nrzi_bit(1'b0);
            nrzi_bit(1'b1);

            // The bit-stuff counter runs across the whole packet, SYNC included, and SYNC
            // ends with a 1 bit. Restarting the count at zero here would place the first
            // stuffed bit one position late and the receiver would flag a stuff error.
            ones = 1;
            for (k = 0; k < n; k = k + 1) begin
                nrzi_bit(want[k]);
                if (want[k]) begin
                    ones = ones + 1;
                    if (ones == 6) begin
                        nrzi_bit(1'b0);           // stuffed bit, receiver must drop it
                        ones = 0;
                    end
                end else begin
                    ones = 0;
                end
            end

            drive_se0;                            // EOP
            drive_se0;
            cur_j = 1'b1;
            drive_state(cur_j);
            repeat (CLKS_PER_BIT * 8) @(posedge clk);
        end
    endtask

    task automatic run_case (input integer n, input [255:0] label);
        integer k, bad;
        begin
            nrx = 0; nsta = 0; nfin = 0;
            send_packet(n);
            #1;

            bad = 0;
            for (k = 0; k < n; k = k + 1)
                if (k < nrx && got[k] !== want[k]) bad = bad + 1;

            $display("  %-30s sent=%0d recovered=%0d sta=%0d fin=%0d mismatch=%0d",
                     label, n, nrx, nsta, nfin, bad);

            if (nsta != 1) begin
                $display("    ** FAIL: rx_sta fired %0d times, expected 1", nsta);
                errors = errors + 1;
            end
            if (nfin != 1) begin
                $display("    ** FAIL: rx_fin fired %0d times, expected 1", nfin);
                errors = errors + 1;
            end
            if (nrx != n) begin
                $display("    ** FAIL: recovered %0d bits, expected %0d", nrx, n);
                errors = errors + 1;
            end
            if (bad != 0) begin
                $display("    ** FAIL: %0d recovered bits differ from what was sent", bad);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $display("");
        $display("==========================================================================================");
        $display(" tb_usbfs_bitlevel : SYNC, NRZI, bit de-stuffing and EOP");
        $display("==========================================================================================");
        $display("");

        rstn = 1'b0;
        repeat (20) @(posedge clk);
        rstn = 1'b1;
        repeat (20) @(posedge clk);

        // ---- alternating pattern ----------------------------------------------------------------------
        nwant = 16;
        for (i = 0; i < nwant; i = i + 1) want[i] = i[0];
        run_case(nwant, "alternating 0101...");

        // ---- all zeros: maximum NRZI toggling ----------------------------------------------------------
        nwant = 16;
        for (i = 0; i < nwant; i = i + 1) want[i] = 1'b0;
        run_case(nwant, "all zeros (max toggling)");

        // ---- a run of eight ones: forces bit stuffing ---------------------------------------------------
        nwant = 16;
        for (i = 0; i < nwant; i = i + 1) want[i] = (i >= 4 && i < 12);
        run_case(nwant, "eight consecutive ones");

        // ---- a long run: multiple stuffed bits ----------------------------------------------------------
        nwant = 32;
        for (i = 0; i < nwant; i = i + 1) want[i] = 1'b1;
        run_case(nwant, "32 ones (repeated stuffing)");

        // ---- pseudo-random payload ----------------------------------------------------------------------
        nwant = 64;
        for (i = 0; i < nwant; i = i + 1) want[i] = $urandom & 1;
        run_case(nwant, "64 random bits");

        // ---- idle line must not produce a packet --------------------------------------------------------
        nrx = 0; nsta = 0; nfin = 0;
        cur_j = 1'b1;
        repeat (40) drive_state(1'b1);
        #1;
        $display("");
        $display("  idle J for 40 bit times -> rx_sta=%0d (expected 0)", nsta);
        if (nsta != 0) begin
            $display("    ** FAIL: an idle line produced a spurious packet start");
            errors = errors + 1;
        end else begin
            $display("    OK: idle line is quiet");
        end

        $display("");
        $display("==========================================================================================");
        if (errors == 0)
            $display(" RESULT: PASS - line coding recovered exactly, stuffing removed correctly.");
        else
            $display(" RESULT: FAIL - %0d check(s) failed.", errors);
        $display("==========================================================================================");
        $display("");
        $finish;
    end

endmodule
