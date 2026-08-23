`timescale 1ns / 1ps
//--------------------------------------------------------------------------------------------------------
// Testbench : tb_usbfs_transaction
// DUT       : usbfs_transaction - transaction FSM, endpoint routing, descriptor ROM
//
// Driven at the packet level, standing in for usbfs_packet_rx / usbfs_packet_tx. A packet is
// presented as: optional rp_byte_en data beats, then one cycle of rp_fin & rp_okay with
// rp_pid / rp_endp set. That is exactly the contract usbfs_packet_rx implements.
//
// Instantiated with the same isochronous setting the chip uses. Endpoint 0x01 OUT is the
// only non-control endpoint the device declares; every other endpoint must NAK.
//--------------------------------------------------------------------------------------------------------

module tb_usbfs_transaction;

    localparam [3:0] PID_OUT   = 4'h1;
    localparam [3:0] PID_IN    = 4'h9;
    localparam [3:0] PID_SOF   = 4'h5;
    localparam [3:0] PID_DATA0 = 4'h3;
    localparam [3:0] PID_NAK   = 4'hA;

    reg clk = 1'b0, rstn = 1'b0;
    always #8.333 clk = ~clk;

    reg  [3:0] rp_pid = 4'h0, rp_endp = 4'h0;
    reg        rp_byte_en = 1'b0;
    reg  [7:0] rp_byte = 8'h0;
    reg        rp_fin = 1'b0, rp_okay = 1'b0;

    wire       tp_sta;
    wire [3:0] tp_pid;
    reg        tp_byte_req = 1'b0;
    wire [7:0] tp_byte;
    wire       tp_fin_n;
    wire       sot, sof;
    wire[63:0] ep00_setup_cmd;
    wire [8:0] ep00_resp_idx;

    wire [7:0] ep01_data;
    wire       ep01_valid;

    usbfs_transaction #(
        .EP01_ISOCHRONOUS ( 1      )
    ) dut (
        .rstn(rstn), .clk(clk),
        .rp_pid(rp_pid), .rp_endp(rp_endp), .rp_byte_en(rp_byte_en),
        .rp_byte(rp_byte), .rp_fin(rp_fin), .rp_okay(rp_okay),
        .tp_sta(tp_sta), .tp_pid(tp_pid), .tp_byte_req(tp_byte_req),
        .tp_byte(tp_byte), .tp_fin_n(tp_fin_n),
        .sot(sot), .sof(sof),
        .ep00_setup_cmd(ep00_setup_cmd), .ep00_resp_idx(ep00_resp_idx), .ep00_resp(8'h0),
        .ep00_data_out(), .ep00_data_valid(), .ep00_data_idx(),
        .ep01_data(ep01_data), .ep01_valid(ep01_valid)
    );

    integer errors = 0;
    integer i, n_out, sof_count;
    reg [7:0] outbuf [0:255];

    always @(posedge clk) begin
        if (ep01_valid && n_out < 256) begin
            outbuf[n_out] = ep01_data;
            n_out = n_out + 1;
        end
        if (sof) sof_count = sof_count + 1;
    end

    // Present a token: one cycle of rp_fin & rp_okay with pid/endp set.
    task automatic send_token (input [3:0] pid, input [3:0] endp);
        begin
            @(posedge clk); #1;
            rp_pid  = pid;
            rp_endp = endp;
            rp_fin  = 1'b1;
            rp_okay = 1'b1;
            @(posedge clk); #1;
            rp_fin  = 1'b0;
            rp_okay = 1'b0;
            repeat (2) @(posedge clk); #1;
        end
    endtask

    // Present a DATA0 packet body then its rp_fin.
    task automatic send_data (input [3:0] endp, input integer len);
        integer k;
        begin
            for (k = 0; k < len; k = k + 1) begin
                @(posedge clk); #1;
                rp_byte    = 8'hA0 + k[7:0];
                rp_byte_en = 1'b1;
                @(posedge clk); #1;
                rp_byte_en = 1'b0;
            end
            send_token(PID_DATA0, endp);
        end
    endtask

    initial begin
        n_out = 0; sof_count = 0;

        $display("");
        $display("==========================================================================================");
        $display(" tb_usbfs_transaction : SOF detection, OUT routing, IN NAK");
        $display("==========================================================================================");
        $display("");

        rstn = 1'b0;
        repeat (10) @(posedge clk);
        rstn = 1'b1;
        repeat (5) @(posedge clk);

        // ---- SOF ---------------------------------------------------------------------------------------
        sof_count = 0;
        for (i = 0; i < 5; i = i + 1) send_token(PID_SOF, 4'h0);
        $display("  SOF tokens sent = 5, sof pulses seen = %0d", sof_count);
        if (sof_count != 5) begin
            $display("    ** FAIL: sof did not pulse once per SOF token");
            errors = errors + 1;
        end else begin
            $display("    OK: sof pulses once per SOF token");
        end

        // ---- OUT to endpoint 1 -------------------------------------------------------------------------
        n_out = 0;
        send_token(PID_OUT, 4'h1);
        send_data(4'h1, 8);
        repeat (5) @(posedge clk); #1;

        $display("  OUT ep1 with 8 bytes -> ep01_valid fired %0d time(s)", n_out);
        if (n_out != 8) begin
            $display("    ** FAIL: expected 8 bytes on ep01");
            errors = errors + 1;
        end else begin
            for (i = 0; i < 8; i = i + 1)
                if (outbuf[i] !== (8'hA0 + i[7:0])) begin
                    $display("    ** FAIL: ep01 byte %0d was %02h, expected %02h",
                             i, outbuf[i], 8'hA0 + i);
                    errors = errors + 1;
                end
            if (errors == 0) $display("    OK: payload routed to ep01 intact");
        end

        // ---- OUT to endpoint 1 must not leak into other endpoints ---------------------------------------
        n_out = 0;
        send_token(PID_OUT, 4'h3);
        send_data(4'h3, 4);
        repeat (5) @(posedge clk); #1;
        $display("  OUT ep3 with 4 bytes -> ep01_valid fired %0d time(s) (expected 0)", n_out);
        if (n_out != 0) begin
            $display("    ** FAIL: endpoint routing leaked into ep01");
            errors = errors + 1;
        end else begin
            $display("    OK: endpoint routing is isolated");
        end

        // ---- IN to a non-control endpoint must be NAKed --------------------------------------------------
        // A headphone declares no IN endpoint other than endpoint 0, so every other IN is a NAK.
        begin : in_nak
            integer e, bad;
            bad = 0;
            for (e = 1; e < 5; e = e + 1) begin
                send_token(PID_IN, e[3:0]);
                #1;
                if (tp_pid !== PID_NAK) begin
                    $display("  ** FAIL: IN to endpoint %0d answered %h, expected NAK (%h)",
                             e, tp_pid, PID_NAK);
                    bad = bad + 1;
                end
            end
            $display("  IN to endpoints 1..4 -> %0d of 4 answered something other than NAK", bad);
            if (bad != 0) errors = errors + bad;
            else $display("    OK: the device declares no IN endpoint but endpoint 0, and NAKs the rest");
        end

        $display("");
        $display("==========================================================================================");
        if (errors == 0)
            $display(" RESULT: PASS - SOF, OUT routing and IN NAK all behave.");
        else
            $display(" RESULT: FAIL - %0d check(s) failed.", errors);
        $display("==========================================================================================");
        $display("");
        $finish;
    end

endmodule
