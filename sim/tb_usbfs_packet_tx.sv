`timescale 1ns / 1ps
//--------------------------------------------------------------------------------------------------------
// Testbench : tb_usbfs_packet_tx
// DUT       : usbfs_packet_tx - packs PID + payload + CRC16 into a USB packet bit stream
//
// The testbench stands in for usbfs_bitlevel: it pumps tx_req and collects tx_bit, which is
// the packet bit stream before NRZI encoding and bit stuffing.
//
// Two independent checks:
//   1. The first 8 bits are the PID byte {~pid, pid}, LSB first - derived from the USB
//      specification, not from the DUT.
//   2. The whole stream is fed into usbfs_packet_rx. That module computes CRC16 with its own
//      independent implementation, so rp_okay=1 proves the CRC that packet_tx appended is
//      correct without this testbench having to reproduce the polynomial.
//--------------------------------------------------------------------------------------------------------

module tb_usbfs_packet_tx;

    localparam [3:0] PID_DATA0 = 4'h3;
    localparam [3:0] PID_DATA1 = 4'hB;

    reg        clk  = 1'b0;
    reg        rstn = 1'b0;
    always #8.333 clk = ~clk;

    // ---- packet_tx interface -------------------------------------------------------------------------
    reg        tp_sta   = 1'b0;
    reg  [3:0] tp_pid   = 4'h0;
    wire       tp_byte_req;
    reg  [7:0] tp_byte  = 8'h0;
    reg        tp_fin_n = 1'b0;
    wire       tx_sta;
    reg        tx_req   = 1'b0;
    wire       tx_bit;
    wire       tx_fin;

    usbfs_packet_tx dut (
        .rstn(rstn), .clk(clk),
        .tp_sta(tp_sta), .tp_pid(tp_pid), .tp_byte_req(tp_byte_req),
        .tp_byte(tp_byte), .tp_fin_n(tp_fin_n),
        .tx_sta(tx_sta), .tx_req(tx_req), .tx_bit(tx_bit), .tx_fin(tx_fin)
    );

    // ---- packet_rx used as an independent checker ----------------------------------------------------
    reg        rx_sta = 1'b0, rx_ena = 1'b0, rx_bit = 1'b0, rx_fin = 1'b0;
    wire [3:0] rp_pid;
    wire[10:0] rp_addr;
    wire       rp_byte_en;
    wire [7:0] rp_byte;
    wire       rp_fin, rp_okay;

    usbfs_packet_rx chk (
        .rstn(rstn), .clk(clk),
        .rx_sta(rx_sta), .rx_ena(rx_ena), .rx_bit(rx_bit), .rx_fin(rx_fin),
        .rp_pid(rp_pid), .rp_addr(rp_addr), .rp_byte_en(rp_byte_en),
        .rp_byte(rp_byte), .rp_fin(rp_fin), .rp_okay(rp_okay)
    );

    integer errors = 0;
    integer nbits, i, j, nrx;
    reg [1023:0] bits;
    reg [7:0] payload [0:63];
    reg [7:0] rxbuf   [0:63];
    integer   plen = 0;
    integer   byte_idx = 0;

    // Byte server. usbfs_packet_tx pulses tp_byte_req and expects tp_byte and tp_fin_n to be
    // valid on the following cycle; tp_fin_n=0 means "there is no such byte, emit the CRC now".
    always @(posedge clk)
        if (tp_byte_req) begin
            if (byte_idx < plen) begin
                tp_byte  <= payload[byte_idx];
                tp_fin_n <= 1'b1;
            end else begin
                tp_byte  <= 8'h0;
                tp_fin_n <= 1'b0;
            end
            byte_idx <= byte_idx + 1;
        end

    // Collect bytes that the checker decodes
    always @(posedge clk)
        if (rp_byte_en && nrx < 64) begin
            rxbuf[nrx] = rp_byte;
            nrx = nrx + 1;
        end

    // Drive one packet out of packet_tx, collecting the bit stream into `bits`.
    // tx_req is pumped once every 5 clocks, the real cadence usbfs_bitlevel uses at
    // 60 MHz / 12 Mbps. That gap is what gives the byte handshake time to complete -
    // pumping back to back starves it and the FSM shifts out stale bits.
    task automatic emit_packet (input [3:0] pid, input integer len);
        begin
            nbits    = 0;
            plen     = len;
            byte_idx = 0;
            @(posedge clk); #1;
            tp_pid   = pid;
            tp_fin_n = 1'b1;
            tp_sta   = 1'b1;
            @(posedge clk); #1;
            tp_sta   = 1'b0;

            for (i = 0; i < 4000; i = i + 1) begin
                repeat (3) @(posedge clk);       // idle gap: byte handshake settles here
                @(posedge clk); #1;
                tx_req = 1'b1;
                @(posedge clk); #1;
                tx_req = 1'b0;
                // tx_bit / tx_fin valid now
                if (tx_fin) i = 4000;
                else begin
                    bits[nbits] = tx_bit;
                    nbits = nbits + 1;
                end
            end
        end
    endtask

    // Replay a bit stream into the checker as if usbfs_bitlevel had received it.
    task automatic replay (input integer n, input integer corrupt_bit);
        begin
            nrx = 0;
            @(posedge clk); #1;
            rx_sta = 1'b1;
            @(posedge clk); #1;
            rx_sta = 1'b0;
            for (j = 0; j < n; j = j + 1) begin
                rx_bit = (j == corrupt_bit) ? ~bits[j] : bits[j];
                rx_ena = 1'b1;
                @(posedge clk); #1;
                rx_ena = 1'b0;
                @(posedge clk); #1;
            end
            rx_fin = 1'b1;
            @(posedge clk); #1;
            rx_fin = 1'b0;
            repeat (4) @(posedge clk);
            #1;
        end
    endtask

    task automatic check_packet (input [3:0] pid, input integer len, input [255:0] label);
        reg [7:0] want_pid_byte;
        integer   b;
        begin
            for (b = 0; b < len; b = b + 1) payload[b] = 8'h10 + b[7:0];

            emit_packet(pid, len);

            // ---- check 1: PID byte, LSB first ---------------------------------------------------------
            want_pid_byte = {~pid, pid};
            for (b = 0; b < 8; b = b + 1) begin
                if (bits[b] !== want_pid_byte[b]) begin
                    $display("  FAIL %0s: PID bit %0d was %b, expected %b",
                             label, b, bits[b], want_pid_byte[b]);
                    errors = errors + 1;
                end
            end

            // ---- check 2: total length = 8 PID + 8*len payload + 16 CRC --------------------------------
            if (nbits != 8 + 8 * len + 16) begin
                $display("  FAIL %0s: emitted %0d bits, expected %0d",
                         label, nbits, 8 + 8 * len + 16);
                errors = errors + 1;
            end

            // ---- check 3: independent decode ----------------------------------------------------------
            replay(nbits, -1);
            if (rp_pid !== pid) begin
                $display("  FAIL %0s: decoded PID %h, expected %h", label, rp_pid, pid);
                errors = errors + 1;
            end
            if (!rp_okay) begin
                $display("  FAIL %0s: CRC16 rejected by packet_rx", label);
                errors = errors + 1;
            end
            if (nrx != len) begin
                $display("  FAIL %0s: decoded %0d payload bytes, expected %0d", label, nrx, len);
                errors = errors + 1;
            end
            for (b = 0; b < len && b < nrx; b = b + 1) begin
                if (rxbuf[b] !== payload[b]) begin
                    $display("  FAIL %0s: byte %0d was %02h, expected %02h",
                             label, b, rxbuf[b], payload[b]);
                    errors = errors + 1;
                end
            end

            $display("  %-28s pid=%h len=%0d bits=%0d okay=%b decoded=%0d",
                     label, rp_pid, len, nbits, rp_okay, nrx);
        end
    endtask

    initial begin
        $display("");
        $display("==========================================================================================");
        $display(" tb_usbfs_packet_tx : PID framing and CRC16 generation");
        $display("==========================================================================================");
        $display("");

        rstn = 1'b0;
        repeat (10) @(posedge clk);
        rstn = 1'b1;
        repeat (5) @(posedge clk);

        check_packet(PID_DATA0,  0, "DATA0 zero-length");
        check_packet(PID_DATA0,  1, "DATA0 1 byte");
        check_packet(PID_DATA0,  8, "DATA0 8 bytes");
        check_packet(PID_DATA1, 16, "DATA1 16 bytes");
        check_packet(PID_DATA0, 32, "DATA0 32 bytes");

        // ---- a corrupted bit must be caught by CRC16 --------------------------------------------------
        $display("");
        $display(" bit-error injection");
        check_packet(PID_DATA0, 8, "DATA0 8 bytes (clean)");
        replay(nbits, 20);                       // flip one payload bit on replay
        if (rp_okay) begin
            $display("  FAIL: a flipped payload bit was NOT caught by CRC16");
            errors = errors + 1;
        end else begin
            $display("  OK: flipped payload bit rejected by CRC16");
        end

        $display("");
        $display("==========================================================================================");
        if (errors == 0)
            $display(" RESULT: PASS - packets frame correctly and round-trip through packet_rx.");
        else
            $display(" RESULT: FAIL - %0d check(s) failed.", errors);
        $display("==========================================================================================");
        $display("");
        $finish;
    end

endmodule
