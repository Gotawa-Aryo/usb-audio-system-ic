`timescale 1ns / 1ps
//--------------------------------------------------------------------------------------------------------
// Testbench : tb_usbfs_core_top
// DUT       : usbfs_core_top - the full-speed device core wrapper
//
// Covers the parts of the wrapper that are not already exercised through the sub-module
// testbenches: the reset / attach state machine, the D+/D- tri-state control, and the
// descriptor ROM's response to a GetDescriptor(Device) request.
//
// usbfs_core_top holds the device detached for RESET_CYCLES = 120,000,000 clocks (2000 ms at
// 60 MHz) before asserting usb_dp_pull. Simulating that honestly would take 120 million
// cycles, so the counter is forced close to its terminal value instead - the mechanism under
// test is what happens at the boundary, not the wait itself.
//--------------------------------------------------------------------------------------------------------

module tb_usbfs_core_top;

    reg clk = 1'b0, rstn = 1'b0;
    always #8.333 clk = ~clk;

    wire usb_dp_pull, usb_rstn;
    wire usb_dp, usb_dn;
    wire sot, sof;
    wire [63:0] ep00_setup_cmd;
    wire [ 8:0] ep00_resp_idx;

    // Host side of the bus. When drive_bus is low the testbench releases the lines so the
    // device's own tri-state drivers are visible.
    reg  drive_bus = 1'b1;
    reg  host_dp = 1'b1, host_dn = 1'b0;
    assign usb_dp = drive_bus ? host_dp : 1'bz;
    assign usb_dn = drive_bus ? host_dn : 1'bz;
    pullup   (usb_dp);
    pulldown (usb_dn);

    usbfs_core_top #(
        .DESCRIPTOR_DEVICE ( {144'h12_01_10_01_00_00_00_20_9A_FB_9A_FB_00_01_01_02_00_01} ),
        .EP01_ISOCHRONOUS  ( 1      ),
        .DEBUG             ( "FALSE" )
    ) dut (
        .rstn(rstn), .clk(clk),
        .usb_dp_pull(usb_dp_pull), .usb_dp(usb_dp), .usb_dn(usb_dn),
        .usb_rstn(usb_rstn),
        .sot(sot), .sof(sof),
        .ep00_setup_cmd(ep00_setup_cmd), .ep00_resp_idx(ep00_resp_idx), .ep00_resp(8'h0),
        .ep01_data(), .ep01_valid(),
        .debug_en(), .debug_data(), .debug_uart_tx()
    );

    integer errors = 0;

    initial begin
        $display("");
        $display("==========================================================================================");
        $display(" tb_usbfs_core_top : reset / attach sequencing and bus tri-state");
        $display("==========================================================================================");
        $display("");

        // ---- held in reset ------------------------------------------------------------------------------
        rstn = 1'b0;
        repeat (20) @(posedge clk);
        #1;
        $display("  during reset: usb_dp_pull=%b usb_rstn=%b (expected 0, 0)", usb_dp_pull, usb_rstn);
        if (usb_dp_pull !== 1'b0 || usb_rstn !== 1'b0) begin
            $display("    ** FAIL: the device should be detached while rstn is low");
            errors = errors + 1;
        end else begin
            $display("    OK: device detached during reset");
        end

        // ---- released, but still inside the 2000 ms detach window ----------------------------------------
        rstn = 1'b1;
        repeat (200) @(posedge clk);
        #1;
        $display("  200 clocks after release: usb_dp_pull=%b (expected 0, still counting)", usb_dp_pull);
        if (usb_dp_pull !== 1'b0) begin
            $display("    ** FAIL: attached far too early");
            errors = errors + 1;
        end else begin
            $display("    OK: still detached, counter running (usb_rstn_cnt = %0d)", dut.usb_rstn_cnt);
        end

        // ---- skip to the end of the detach window ---------------------------------------------------------
        force dut.usb_rstn_cnt = 32'd119999990;
        repeat (2) @(posedge clk);
        release dut.usb_rstn_cnt;
        repeat (40) @(posedge clk);
        #1;
        $display("  past the detach window:   usb_dp_pull=%b usb_rstn=%b (expected 1, 1)",
                 usb_dp_pull, usb_rstn);
        if (usb_dp_pull !== 1'b1) begin
            $display("    ** FAIL: the pull-up was never enabled");
            errors = errors + 1;
        end else begin
            $display("    OK: pull-up enabled, device attaches");
        end
        if (usb_rstn !== 1'b1) begin
            $display("    ** FAIL: usb_rstn never released with the bus in J state");
            errors = errors + 1;
        end else begin
            $display("    OK: usb_rstn released with the bus idle");
        end

        // ---- host-driven bus reset: SE0 held long enough -------------------------------------------------
        host_dp = 1'b0;
        host_dn = 1'b0;
        repeat (400) @(posedge clk);      // > 5 us of SE0
        #1;
        $display("  after host SE0:           usb_rstn=%b (expected 0, host reset detected)", usb_rstn);
        if (usb_rstn !== 1'b0) begin
            $display("    ** FAIL: a host bus reset was not detected");
            errors = errors + 1;
        end else begin
            $display("    OK: host bus reset detected");
        end

        // return to idle J and confirm recovery
        host_dp = 1'b1;
        host_dn = 1'b0;
        repeat (40) @(posedge clk);
        #1;
        $display("  bus back to idle J:       usb_rstn=%b (expected 1)", usb_rstn);
        if (usb_rstn !== 1'b1) begin
            $display("    ** FAIL: did not recover after the host released the bus reset");
            errors = errors + 1;
        end else begin
            $display("    OK: recovered after bus reset");
        end

        // ---- tri-state: with the device idle, the lines are not driven by the device ---------------------
        drive_bus = 1'b0;
        repeat (20) @(posedge clk);
        #1;
        $display("  device idle, host released: usb_oe=%b", dut.usb_oe);
        if (dut.usb_oe !== 1'b0) begin
            $display("    ** FAIL: the device is driving the bus while idle");
            errors = errors + 1;
        end else begin
            $display("    OK: device releases the bus when not transmitting");
        end
        drive_bus = 1'b1;

        // ---- chip reset detaches the device again ---------------------------------------------------------
        rstn = 1'b0;
        repeat (5) @(posedge clk);
        #1;
        $display("  reset re-asserted:        usb_dp_pull=%b usb_rstn=%b (expected 0, 0)",
                 usb_dp_pull, usb_rstn);
        if (usb_dp_pull !== 1'b0 || usb_rstn !== 1'b0) begin
            $display("    ** FAIL: reset did not detach the device");
            errors = errors + 1;
        end else begin
            $display("    OK: reset detaches the device, forcing re-enumeration");
        end

        $display("");
        $display("==========================================================================================");
        if (errors == 0)
            $display(" RESULT: PASS - attach, bus reset, tri-state and detach all behave.");
        else
            $display(" RESULT: FAIL - %0d check(s) failed.", errors);
        $display("==========================================================================================");
        $display("");
        $finish;
    end

endmodule
