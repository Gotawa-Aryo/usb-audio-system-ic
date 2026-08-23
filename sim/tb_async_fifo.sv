`timescale 1ns / 1ps
//--------------------------------------------------------------------------------------------------------
// Testbench : tb_async_fifo
// DUT       : async_fifo - block 1.2 "FIFO Buffer" of Figure 3
//
// Instantiated in the chip at DATA_WIDTH=16, ADDR_WIDTH=4 (16 entries), with both clocks
// tied to SYS_CLK_60M. This testbench covers it in both modes:
//
//   Part A - single clock, the configuration the chip actually uses
//   Part B - genuinely asynchronous clocks, to exercise the gray-code pointer synchronisers
//
// Two behaviours of this FIFO matter downstream and are checked explicitly:
//   - rd_data is combinational on the read pointer, so it presents the next unread word
//     without needing a pop first
//   - the flags are conservative. Because each pointer crosses through two synchroniser
//     flops, rd_empty can still read high for a couple of clocks after a write lands. It
//     never reads low when the FIFO is genuinely empty, which is the safe direction.
//--------------------------------------------------------------------------------------------------------

module tb_async_fifo;

    localparam integer DW    = 16;
    localparam integer AW    = 4;
    localparam integer DEPTH = 1 << AW;

    integer errors = 0;

    //====================================================================================================
    // Part A : single clock domain (the chip configuration)
    //====================================================================================================
    reg           clk = 1'b0;
    reg           rst_n = 1'b0;
    reg           wr_en = 1'b0;
    reg  [DW-1:0] wr_data = 0;
    wire          wr_full;
    reg           rd_en = 1'b0;
    wire [DW-1:0] rd_data;
    wire          rd_empty;

    always #8.333 clk = ~clk;                 // 60 MHz

    async_fifo #(.DATA_WIDTH(DW), .ADDR_WIDTH(AW)) dut_a (
        .wr_clk(clk), .wr_rst_n(rst_n), .wr_en(wr_en), .wr_data(wr_data),
        .wr_commit(1'b1), .wr_abort(1'b0), .wr_full(wr_full),
        .rd_clk(clk), .rd_rst_n(rst_n), .rd_en(rd_en), .rd_data(rd_data), .rd_empty(rd_empty)
    );

    integer i, got, timeout;

    // Stimulus is always driven 1 ns after a clock edge and released 1 ns after the next one,
    // so the DUT unambiguously samples it high on exactly one edge. Driving right on the edge
    // races the DUT's own always block and the enable can be missed entirely.
    task automatic push (input [DW-1:0] d);
        begin
            @(posedge clk);
            #1;
            wr_data = d;
            wr_en   = 1'b1;
            @(posedge clk);
            #1;
            wr_en   = 1'b0;
        end
    endtask

    // Wait for rd_empty to fall, then pop one word into `got`.
    task automatic pop;
        begin
            timeout = 0;
            while (rd_empty && timeout < 100) begin
                @(posedge clk);
                #1;
                timeout = timeout + 1;
            end
            if (rd_empty) begin
                $display("    ** FAIL: FIFO still empty after %0d clocks", timeout);
                errors = errors + 1;
                got = -1;
            end else begin
                got = rd_data;                 // combinational read, valid before the pop
                @(posedge clk);
                #1;
                rd_en = 1'b1;
                @(posedge clk);
                #1;
                rd_en = 1'b0;
            end
        end
    endtask

    //====================================================================================================
    // Part B : asynchronous clocks
    //====================================================================================================
    reg           wclk = 1'b0;
    reg           rclk = 1'b0;
    reg           b_rst_n = 1'b0;
    reg           b_wr_en = 1'b0;
    reg  [DW-1:0] b_wr_data = 0;
    wire          b_wr_full;
    reg           b_rd_en = 1'b0;
    wire [DW-1:0] b_rd_data;
    wire          b_rd_empty;

    always #8.333  wclk = ~wclk;              // 60 MHz write side
    always #29.411 rclk = ~rclk;              // ~17 MHz read side, deliberately unrelated

    async_fifo #(.DATA_WIDTH(DW), .ADDR_WIDTH(AW)) dut_b (
        .wr_clk(wclk), .wr_rst_n(b_rst_n), .wr_en(b_wr_en), .wr_data(b_wr_data),
        .wr_commit(1'b1), .wr_abort(1'b0), .wr_full(b_wr_full),
        .rd_clk(rclk), .rd_rst_n(b_rst_n), .rd_en(b_rd_en), .rd_data(b_rd_data), .rd_empty(b_rd_empty)
    );

    integer sent, recv, b_errors;

    initial begin
        $display("");
        $display("==========================================================================================");
        $display(" tb_async_fifo : FIFO Buffer, %0d x %0d bits", DEPTH, DW);
        $display("==========================================================================================");
        $display("");
        $display(" PART A - single clock domain (the chip configuration)");
        $display("");

        // ---- reset state -----------------------------------------------------------------------------
        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        #1;
        if (rd_empty !== 1'b1) begin
            $display("  FAIL: rd_empty should be 1 after reset");
            errors = errors + 1;
        end else $display("  OK: empty after reset");
        if (wr_full !== 1'b0) begin
            $display("  FAIL: wr_full should be 0 after reset");
            errors = errors + 1;
        end else $display("  OK: not full after reset");

        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        // ---- single word round trip ------------------------------------------------------------------
        push(16'hA5A5);
        pop;
        if (got !== 16'hA5A5) begin
            $display("  FAIL: single word round trip gave %04h, expected A5A5", got);
            errors = errors + 1;
        end else $display("  OK: single word round trip");

        // drain settles back to empty
        timeout = 0;
        while (!rd_empty && timeout < 100) begin @(posedge clk); #1; timeout = timeout + 1; end
        if (!rd_empty) begin
            $display("  FAIL: FIFO did not return to empty after draining");
            errors = errors + 1;
        end else $display("  OK: returns to empty after draining");

        // ---- fill to full ----------------------------------------------------------------------------
        for (i = 0; i < DEPTH; i = i + 1) push(16'h1000 + i[15:0]);
        repeat (5) @(posedge clk);
        #1;
        if (wr_full !== 1'b1) begin
            $display("  FAIL: wr_full not asserted after %0d writes", DEPTH);
            errors = errors + 1;
        end else $display("  OK: full after %0d writes", DEPTH);

        // ---- writes while full are dropped, not corrupting ------------------------------------------
        push(16'hDEAD);
        push(16'hBEEF);
        repeat (5) @(posedge clk);

        // ---- drain and verify FIFO order -------------------------------------------------------------
        for (i = 0; i < DEPTH; i = i + 1) begin
            pop;
            if (got !== (16'h1000 + i[15:0])) begin
                $display("  FAIL: entry %0d was %04h, expected %04h", i, got, 16'h1000 + i);
                errors = errors + 1;
            end
        end
        $display("  OK: all %0d entries came back in order, overflow writes were dropped", DEPTH);

        timeout = 0;
        while (!rd_empty && timeout < 100) begin @(posedge clk); #1; timeout = timeout + 1; end
        if (!rd_empty) begin
            $display("  FAIL: not empty after full drain");
            errors = errors + 1;
        end else $display("  OK: empty after full drain");

        // ---- pointer wraparound ----------------------------------------------------------------------
        for (i = 0; i < DEPTH * 5; i = i + 1) begin
            push(16'h2000 + i[15:0]);
            pop;
            if (got !== (16'h2000 + i[15:0])) begin
                $display("  FAIL: wraparound item %0d was %04h, expected %04h",
                         i, got, 16'h2000 + i);
                errors = errors + 1;
            end
        end
        $display("  OK: %0d items through the pointer wraparound", DEPTH * 5);

        // ---- reads while empty must not advance anything ---------------------------------------------
        @(posedge clk);
        rd_en = 1'b1;
        repeat (10) @(posedge clk);
        rd_en = 1'b0;
        #1;
        if (rd_empty !== 1'b1) begin
            $display("  FAIL: reading an empty FIFO changed the empty flag");
            errors = errors + 1;
        end else $display("  OK: reads on an empty FIFO are ignored");

        push(16'hC0DE);
        pop;
        if (got !== 16'hC0DE) begin
            $display("  FAIL: FIFO corrupted by underflow reads (got %04h)", got);
            errors = errors + 1;
        end else $display("  OK: FIFO still healthy after underflow reads");

        //================================================================================================
        $display("");
        $display(" PART B - asynchronous clocks (60 MHz write, ~17 MHz read)");
        $display("");

        b_rst_n = 1'b0;
        repeat (5) @(posedge wclk);
        b_rst_n = 1'b1;
        repeat (5) @(posedge wclk);

        sent     = 0;
        recv     = 0;
        b_errors = 0;

        fork
            // writer: push a counting pattern whenever there is room
            begin : writer
                for (sent = 0; sent < 200; sent = sent + 1) begin
                    @(posedge wclk);
                    #1;
                    while (b_wr_full) begin @(posedge wclk); #1; end
                    b_wr_data = 16'h3000 + sent[15:0];
                    b_wr_en   = 1'b1;
                    @(posedge wclk);
                    #1;
                    b_wr_en   = 1'b0;
                end
            end
            // reader: pop and check ordering on the slower clock
            begin : reader
                for (recv = 0; recv < 200; recv = recv + 1) begin
                    @(posedge rclk);
                    #1;
                    while (b_rd_empty) begin @(posedge rclk); #1; end
                    if (b_rd_data !== (16'h3000 + recv[15:0])) begin
                        if (b_errors < 5)
                            $display("  FAIL: async item %0d was %04h, expected %04h",
                                     recv, b_rd_data, 16'h3000 + recv);
                        b_errors = b_errors + 1;
                    end
                    b_rd_en = 1'b1;
                    @(posedge rclk);
                    #1;
                    b_rd_en = 1'b0;
                end
            end
        join

        if (b_errors == 0)
            $display("  OK: 200 words crossed the clock domains in order, no corruption");
        else begin
            $display("  FAIL: %0d ordering/data errors across the clock domains", b_errors);
            errors = errors + b_errors;
        end

        $display("");
        $display("==========================================================================================");
        if (errors == 0)
            $display(" RESULT: PASS - flags, ordering, overflow, underflow and CDC all behave.");
        else
            $display(" RESULT: FAIL - %0d check(s) failed.", errors);
        $display("==========================================================================================");
        $display("");
        $finish;
    end

endmodule
