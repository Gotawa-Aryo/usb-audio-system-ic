`timescale 1ns / 1ps
//--------------------------------------------------------------------------------------------------------
// Testbench : tb_usb_wire_end_to_end
//
// The only bench that drives real USB traffic on the wire, all the way through to the pin.
//
// Every other bench in sim/ either forces the USB core's decoded outputs (out_data/out_valid/
// sof) and so skips bitlevel, packet_rx and transaction entirely, or drives D+/D- into the
// bitlevel module alone. This one drives properly framed full-speed packets onto USB_DP/USB_DN
// of ic_top_usb_audio and checks the audio comes out of DAC_MOD_OUT_L:
//
//   host BFM -> USB_DP/USB_DN -> usbfs_bitlevel -> usbfs_packet_rx -> usbfs_transaction
//            -> usb_audio_top -> FIFO Buffer -> Control Unit drain -> modulator -> pin
//
// The host model builds each packet the way the specification says: SYNC, PID with its check
// nibble, payload, CRC5 for tokens or CRC16 for data, NRZI encoding, bit stuffing across the
// whole packet including the SYNC field, and an SE0 EOP. It also decodes the device's replies
// off the wire, so the control path is verified in both directions.
//
// Checks:
//   1. the device attaches and answers GetDescriptor(DEVICE) over the wire, byte for byte
//   2. audio sent as real OUT + DATA0 packets arrives at the FIFO in order, with no loss
//   3. a steady sample reaches DAC_MOD_OUT_L at the right bitstream density - the data is
//      verified at the chip pin, not at an internal node
//   4. a corrupted DATA0 packet is rejected rather than played
//--------------------------------------------------------------------------------------------------------

module tb_usb_wire_end_to_end;

    localparam integer CLKS_PER_BIT  = 5;         // 60 MHz / 12 Mbps
    localparam integer SAMPLES_FRAME = 48;
    localparam integer FRAME_CLKS    = 60000;     // 1 ms
    localparam integer RESET_CYCLES  = 120000000;

    localparam [3:0] PID_OUT   = 4'h1;
    localparam [3:0] PID_IN    = 4'h9;
    localparam [3:0] PID_SOF   = 4'h5;
    localparam [3:0] PID_SETUP = 4'hD;
    localparam [3:0] PID_DATA0 = 4'h3;
    localparam [3:0] PID_DATA1 = 4'hB;

    reg clk = 1'b0, reset_n = 1'b0;
    always #8.333 clk = ~clk;

    // ---- the bus ---------------------------------------------------------------------------------
    reg  host_oe = 1'b0;
    reg  host_dp = 1'b1, host_dn = 1'b0;
    wire usb_dp, usb_dn;
    assign usb_dp = host_oe ? host_dp : 1'bz;
    assign usb_dn = host_oe ? host_dn : 1'bz;
    pullup   (usb_dp);          // idle J when nobody drives
    pulldown (usb_dn);

    wire usb_dp_pull, dac_mod_out_l;

    ic_top_usb_audio dut (
        .USB_DP_PULL   ( usb_dp_pull   ),
        .USB_DP        ( usb_dp        ),
        .USB_DN        ( usb_dn        ),
        .SYS_CLK_60M   ( clk           ),
        .DAC_MOD_OUT_L ( dac_mod_out_l ),
        .RESET_N       ( reset_n       )
    );

    integer errors = 0;

    //====================================================================================================
    // Host transmitter
    //====================================================================================================
    reg [7:0] txbuf [0:255];
    reg       cur_j;
    integer   stuff_ones;

    task automatic drive (input j);
        begin
            host_oe = 1'b1;
            host_dp =  j;
            host_dn = ~j;
            repeat (CLKS_PER_BIT) @(posedge clk);
        end
    endtask

    task automatic drive_se0;
        begin
            host_oe = 1'b1;
            host_dp = 1'b0;
            host_dn = 1'b0;
            repeat (CLKS_PER_BIT) @(posedge clk);
        end
    endtask

    // One raw bit, NRZI encoded, with stuffing applied.
    task automatic tx_bit (input b);
        begin
            if (!b) cur_j = ~cur_j;
            drive(cur_j);
            if (b) begin
                stuff_ones = stuff_ones + 1;
                if (stuff_ones == 6) begin
                    cur_j = ~cur_j;             // stuffed 0
                    drive(cur_j);
                    stuff_ones = 0;
                end
            end else begin
                stuff_ones = 0;
            end
        end
    endtask

    task automatic tx_byte (input [7:0] v);
        integer k;
        begin
            for (k = 0; k < 8; k = k + 1) tx_bit(v[k]);
        end
    endtask

    function [4:0] crc5_step (input [4:0] c, input b);
        reg x;
        begin
            x = c[4] ^ b;
            crc5_step = {c[3:0], 1'b0} ^ {2'b0, x, 1'b0, x};
        end
    endfunction

    function [15:0] crc16_step (input [15:0] c, input b);
        reg x;
        begin
            x = c[15] ^ b;
            crc16_step = {c[14:0], 1'b0} ^ {x, 12'b0, x, 1'b0, x};
        end
    endfunction

    task automatic start_packet;
        begin
            host_oe = 1'b1;
            cur_j   = 1'b1;
            drive(cur_j);                        // settle idle J
            stuff_ones = 0;
            begin : sync
                integer k;
                for (k = 0; k < 7; k = k + 1) tx_bit(1'b0);
                tx_bit(1'b1);                    // SYNC ends with a 1 ...
            end
            stuff_ones = 1;                      // ... and it counts toward the stuff run
        end
    endtask

    // Inter-packet idle held after EOP. Must be 0 before a token the device answers:
    // usbfs_bitlevel turns its transmitter around within a few bit times of the EOP, so
    // idling here would miss the start of the reply.
    integer post_idle_bits = 30;

    task automatic end_packet;
        begin
            drive_se0;
            drive_se0;
            cur_j = 1'b1;
            drive(cur_j);
            host_oe = 1'b0;                      // release so the device can answer
            if (post_idle_bits > 0)
                repeat (CLKS_PER_BIT * post_idle_bits) @(posedge clk);
        end
    endtask

    task automatic bus_idle (input integer nbits);
        begin
            host_oe = 1'b0;
            repeat (CLKS_PER_BIT * nbits) @(posedge clk);
        end
    endtask

    // Token: PID + 11 bits {endp, addr} + CRC5
    task automatic send_token (input [3:0] pid, input [6:0] addr, input [3:0] endp);
        reg [10:0] f;
        reg [4:0]  c, t;
        integer    k;
        begin
            f = {endp, addr};
            c = 5'h1F;
            start_packet;
            tx_byte({~pid, pid});
            for (k = 0; k < 11; k = k + 1) begin
                tx_bit(f[k]);
                c = crc5_step(c, f[k]);
            end
            t = ~c;
            for (k = 4; k >= 0; k = k - 1) tx_bit(t[k]);
            end_packet;
        end
    endtask

    // Data: PID + payload from txbuf + CRC16. corrupt_bit >= 0 flips one payload bit.
    task automatic send_data (input [3:0] pid, input integer n, input integer corrupt_bit);
        reg [15:0] c, t;
        reg        b;
        integer    i, k, bitidx;
        begin
            c = 16'hFFFF;
            start_packet;
            tx_byte({~pid, pid});
            bitidx = 0;
            for (i = 0; i < n; i = i + 1) begin
                for (k = 0; k < 8; k = k + 1) begin
                    b = txbuf[i][k];
                    c = crc16_step(c, b);              // CRC over the TRUE data ...
                    if (bitidx == corrupt_bit) b = ~b; // ... then corrupt only the wire
                    tx_bit(b);
                    bitidx = bitidx + 1;
                end
            end
            t = ~c;
            for (k = 15; k >= 0; k = k - 1) tx_bit(t[k]);
            end_packet;
        end
    endtask

    //====================================================================================================
    // Host receiver - decodes what the device drives back onto the wire
    //====================================================================================================
    reg [7:0] rxbuf [0:255];
    integer   rx_nbytes;
    reg [3:0] rx_pid;
    reg       rx_ok;

    task automatic receive_packet (input integer timeout_clks);
        integer waited, nbits, ones, i, bitpos;
        reg     prev_j, cur, b;
        reg [511:0] bits;
        begin
            rx_nbytes = 0;
            rx_pid    = 4'h0;
            rx_ok     = 1'b0;
            waited    = 0;

            // wait for the device to pull the line off idle J (SYNC starts with a K)
            while (usb_dp !== 1'b0 && waited < timeout_clks) begin
                @(posedge clk);
                waited = waited + 1;
            end
            if (waited >= timeout_clks) disable receive_packet;

            repeat (2) @(posedge clk);           // move to the middle of the bit

            prev_j = 1'b1;                       // line was idle J before this
            nbits  = 0;
            ones   = 0;
            for (i = 0; i < 512; i = i + 1) begin
                if (usb_dp === 1'b0 && usb_dn === 1'b0) i = 512;   // EOP
                else begin
                    cur = (usb_dp === 1'b1);
                    b   = (cur == prev_j);       // NRZI: no transition = 1
                    prev_j = cur;
                    if (ones == 6) begin
                        ones = 0;                // this is a stuffed bit, drop it
                    end else begin
                        bits[nbits] = b;
                        nbits = nbits + 1;
                        if (b) ones = ones + 1;
                        else   ones = 0;
                    end
                    repeat (CLKS_PER_BIT) @(posedge clk);
                end
            end

            // bits[0..7] are SYNC, then the PID byte, then payload, then CRC16
            if (nbits >= 16) begin
                for (i = 0; i < 4; i = i + 1) rx_pid[i] = bits[8 + i];
                bitpos    = 16;
                rx_nbytes = 0;
                while (bitpos + 8 <= nbits - 16 && rx_nbytes < 256) begin
                    for (i = 0; i < 8; i = i + 1) rxbuf[rx_nbytes][i] = bits[bitpos + i];
                    bitpos    = bitpos + 8;
                    rx_nbytes = rx_nbytes + 1;
                end
                rx_ok = 1'b1;
            end
        end
    endtask

    //====================================================================================================
    // Scoreboard on the audio path
    //====================================================================================================
    integer n_out, expect_next, n_gap, n_dup, n_ooo, n_ones, n_meas;
    reg     measuring;
    reg [15:0] last_seen;

    reg checking_order = 1'b0;

    always @(posedge clk)
        if (checking_order && dut.sig_48k && !dut.rd_empty) begin
            if (dut.rd_data !== expect_next[15:0]) begin
                if (dut.rd_data === last_seen)      n_dup = n_dup + 1;
                else if (dut.rd_data > expect_next) n_gap = n_gap + 1;
                else                                n_ooo = n_ooo + 1;
                if (n_gap + n_dup + n_ooo <= 4)
                    $display("    ** sample %0d: got %04h, expected %04h",
                             n_out, dut.rd_data, expect_next[15:0]);
                expect_next = dut.rd_data + 1;
            end else begin
                expect_next = expect_next + 1;
            end
            last_seen = dut.rd_data;
            n_out = n_out + 1;
        end

    integer n_drained;
    always @(posedge clk)
        if (dut.sig_48k && !dut.rd_empty) n_drained = n_drained + 1;

    always @(posedge clk)
        if (measuring) begin
            n_meas = n_meas + 1;
            if (dac_mod_out_l) n_ones = n_ones + 1;
        end

    //====================================================================================================
    integer f, s, i, t0;
    integer sample_ctr;
    reg [15:0] frame_no;
    real density, ideal;

    // One 1 ms frame carrying a 96-byte audio packet built from `mk` (0 = counter, else constant)
    task automatic audio_frame (input integer counter_mode, input [15:0] fixed_val);
        reg [15:0] v;
        begin
            send_token(PID_SOF, 7'h00, 4'h0);
            frame_no = frame_no + 1;

            for (s = 0; s < SAMPLES_FRAME; s = s + 1) begin
                v = counter_mode ? sample_ctr : fixed_val;
                txbuf[2*s]     = v[7:0];
                txbuf[2*s + 1] = v[15:8];
                if (counter_mode) sample_ctr = sample_ctr + 1;
            end

            send_token(PID_OUT, 7'h00, 4'h1);
            send_data(PID_DATA0, SAMPLES_FRAME * 2, -1);
        end
    endtask

    initial begin
        n_out = 0; expect_next = 0; n_gap = 0; n_dup = 0; n_ooo = 0;
        n_ones = 0; n_meas = 0; measuring = 1'b0; last_seen = 16'hFFFF;
        n_drained = 0;
        frame_no = 0; sample_ctr = 0;

        $display("");
        $display("==========================================================================================");
        $display(" tb_usb_wire_end_to_end : real USB packets on the wire, checked at the chip pin");
        $display("==========================================================================================");
        $display("");

        reset_n = 1'b0;
        host_oe = 1'b0;
        repeat (50) @(posedge clk);
        reset_n = 1'b1;
        repeat (50) @(posedge clk);

        // The core holds the device detached for 2000 ms. That mechanism is covered by
        // tb_usbfs_core_top; skip the wait so this bench can get to the traffic.
        force dut.u_usb_audio.usbfs_core_i.usb_rstn_cnt = RESET_CYCLES - 10;
        repeat (4) @(posedge clk);
        release dut.u_usb_audio.usbfs_core_i.usb_rstn_cnt;
        repeat (200) @(posedge clk);
        #1;

        $display(" 1. Attach");
        $display("");
        $display("  USB_DP_PULL = %b, device usb_rstn = %b (expected 1, 1)",
                 usb_dp_pull, dut.u_usb_audio.usb_rstn);
        if (usb_dp_pull !== 1'b1 || dut.u_usb_audio.usb_rstn !== 1'b1) begin
            $display("    ** FAIL: the device did not attach");
            errors = errors + 1;
        end else $display("    OK: device attached and enumerating");

        // ---- 2. control transfer over the wire ---------------------------------------------------
        $display("");
        $display(" 2. GetDescriptor(DEVICE) over the wire");
        $display("");

        txbuf[0] = 8'h80; txbuf[1] = 8'h06;        // bmRequestType, bRequest
        txbuf[2] = 8'h00; txbuf[3] = 8'h01;        // wValue  = 0x0100 DEVICE
        txbuf[4] = 8'h00; txbuf[5] = 8'h00;        // wIndex
        txbuf[6] = 8'h12; txbuf[7] = 8'h00;        // wLength = 18

        send_token(PID_SETUP, 7'h00, 4'h0);
        send_data(PID_DATA0, 8, -1);

        post_idle_bits = 0;                 // do not idle: the reply starts right after EOP
        send_token(PID_IN, 7'h00, 4'h0);
        receive_packet(20000);
        post_idle_bits = 30;
        bus_idle(30);

        if (!rx_ok) begin
            $display("  ** FAIL: the device did not answer the IN token");
            errors = errors + 1;
        end else begin
            $write("  device replied PID=%h, %0d bytes:", rx_pid, rx_nbytes);
            for (i = 0; i < rx_nbytes && i < 12; i = i + 1) $write(" %02h", rxbuf[i]);
            $write("\n");

            if (rx_pid !== PID_DATA1 && rx_pid !== PID_DATA0) begin
                $display("    ** FAIL: expected a DATA packet, got PID %h", rx_pid);
                errors = errors + 1;
            end

            begin : cmp
                reg [18*8-1:0] dev;
                integer bad;
                dev = dut.u_usb_audio.usbfs_core_i.DESCRIPTOR_DEVICE;
                bad = 0;
                for (i = 0; i < 18 && i < rx_nbytes; i = i + 1)
                    if (rxbuf[i] !== dev[(18 - 1 - i) * 8 +: 8]) bad = bad + 1;
                if (rx_nbytes < 18) begin
                    $display("    ** FAIL: only %0d of 18 descriptor bytes came back", rx_nbytes);
                    errors = errors + 1;
                end else if (bad != 0) begin
                    $display("    ** FAIL: %0d descriptor byte(s) differ from the device parameter", bad);
                    errors = errors + 1;
                end else begin
                    $display("    OK: all 18 device descriptor bytes round-tripped over the wire");
                end
            end
        end

        // ---- 3. audio streaming, ordering ---------------------------------------------------------
        $display("");
        $display(" 3. Audio over the wire - 20 frames x 48 samples as OUT + DATA0 packets");
        $display("");

        n_out = 0; expect_next = 0; n_gap = 0; n_dup = 0; n_ooo = 0;
        last_seen = 16'hFFFF; sample_ctr = 0;
        checking_order = 1'b1;

        for (f = 0; f < 20; f = f + 1) begin
            audio_frame(1, 16'h0);
            // idle out the rest of the 1 ms frame
            repeat (FRAME_CLKS - 6000) @(posedge clk);
        end
        repeat (FRAME_CLKS * 2) @(posedge clk);
        checking_order = 1'b0;
        #1;

        $display("  sent %0d samples, %0d arrived at the FIFO output", sample_ctr, n_out);
        $display("  gaps=%0d duplicates=%0d out-of-order=%0d", n_gap, n_dup, n_ooo);
        if (n_out == 0) begin
            $display("    ** FAIL: no audio reached the DAC path at all");
            errors = errors + 1;
        end else if (n_gap != 0 || n_dup != 0 || n_ooo != 0) begin
            $display("    ** FAIL: the wire-level path lost or reordered samples");
            errors = errors + 1;
        end else begin
            $display("    OK: every sample arrived exactly once, in order");
        end

        // ---- 4. the data reaches the pin ------------------------------------------------------------
        $display("");
        $display(" 4. A steady sample measured at DAC_MOD_OUT_L");
        $display("");

        begin : dc_check
            reg [15:0] v;
            v = 16'sd16384;

            // prime the buffer so the modulator is fed before measuring
            for (f = 0; f < 3; f = f + 1) begin
                audio_frame(0, v);
                repeat (FRAME_CLKS - 6000) @(posedge clk);
            end

            n_ones = 0; n_meas = 0;
            measuring = 1'b1;
            for (f = 0; f < 20; f = f + 1) begin
                audio_frame(0, v);
                repeat (FRAME_CLKS - 6000) @(posedge clk);
            end
            measuring = 1'b0;
            #1;

            density = n_ones * 1.0 / n_meas;
            ideal   = ($signed(v) + 32768.0) / 65535.0;
            $display("  sample %0d sent as USB packets -> DAC_MOD_OUT_L density %0.5f (ideal %0.5f)",
                     $signed(v), density, ideal);
            if ((density - ideal) > 0.01 || (ideal - density) > 0.01) begin
                $display("    ** FAIL: the audio did not reach the pin at the right level");
                errors = errors + 1;
            end else begin
                $display("    OK: the sample sent over USB is present at the chip pin");
            end
        end

        // ---- 5. a corrupted packet must not be played -------------------------------------------------
        $display("");
        $display(" 5. A DATA0 packet with a flipped payload bit");
        $display("");

        begin : bad_pkt
            integer n_before;

            // let the buffer run completely dry first, so anything that shows up afterwards
            // can only have come from the corrupted packet
            repeat (FRAME_CLKS * 4) @(posedge clk);
            #1;
            n_before = n_drained;

            send_token(PID_SOF, 7'h00, 4'h0);
            for (s = 0; s < SAMPLES_FRAME; s = s + 1) begin
                txbuf[2*s]     = 8'hAA;
                txbuf[2*s + 1] = 8'h55;
            end
            send_token(PID_OUT, 7'h00, 4'h1);
            send_data(PID_DATA0, SAMPLES_FRAME * 2, 37);     // flip payload bit 37

            repeat (FRAME_CLKS * 2) @(posedge clk);
            #1;
            $display("  samples reaching the DAC from the corrupted packet: %0d (expected 0)",
                     n_drained - n_before);
            if (n_drained - n_before != 0) begin
                $display("    ** FAIL: a packet failing CRC16 was played anyway");
                errors = errors + 1;
            end else begin
                $display("    OK: CRC16 rejected the packet, nothing reached the DAC");
            end
        end

        $display("");
        $display("==========================================================================================");
        if (errors == 0)
            $display(" RESULT: PASS - real USB packets traverse the whole chip and reach the pin.");
        else
            $display(" RESULT: FAIL - %0d check(s) failed.", errors);
        $display("==========================================================================================");
        $display("");
        $finish;
    end

    // safety net
    initial begin
        #400_000_000;
        $display(" ** TIMEOUT: the bench did not finish");
        $finish;
    end

endmodule
