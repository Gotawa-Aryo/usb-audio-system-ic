`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: oversampling_trigger
//
// Block 1.3 "Control Unit" of Figure 3, "XLR8_2026_Chipathon Schematic Review".
//
// Produces SIG_48K, the sample tick that drives RD_EN on the FIFO Buffer (block 1.2).
//
// The isochronous endpoint declares bmAttributes = 0x0D, Isochronous *Synchronous*
// (BADD Tables 5-18/5-19). That declaration is a promise that the device's sample
// clock is locked to the USB frame, so this block derives SIG_48K from SOF rather
// than free-running off the local crystal:
//
//   - the frame length is measured in SYS_CLK_60M cycles between consecutive SOFs
//     (nominally 60000, but the host's clock is what actually sets it)
//   - a phase accumulator adds 48 per cycle and emits a tick whenever it crosses the
//     measured frame length, giving exactly 48 ticks per frame whatever that length is
//   - the accumulator is realigned on every SOF, so phase error cannot accumulate
//
// If SOF is absent - unplugged, or not yet enumerated - the block falls back to the
// nominal 60000-cycle frame, which is an exact 1250-cycle sample period. The DAC
// therefore keeps running at 48 kHz with no host attached.
//
// NOTE: Figure 3 does not draw a connection from block 1.1 to block 1.3. This SOF
// input is that connection, and the figure needs updating to match.
//////////////////////////////////////////////////////////////////////////////////


module oversampling_trigger(
        input  wire SYS_CLK_60M,
        input  wire RESET_N,
        input  wire SOF,          // 1 kHz start-of-frame marker from the USB Interface
        output wire SIG_48K
    );

    localparam [16:0] NOMINAL_PERIOD = 17'd60000;   // 60 MHz / 1 kHz
    localparam [16:0] PERIOD_MIN     = 17'd57000;   // accept +/- 5 % around nominal
    localparam [16:0] PERIOD_MAX     = 17'd63000;
    localparam [16:0] SOF_TIMEOUT    = 17'd90000;   // 1.5 frames of silence -> free run
    localparam [17:0] SAMPLES_FRAME  = 18'd48;      // samples per 1 ms frame at 48 kHz

    reg [16:0] frame_cnt;      // SYS_CLK_60M cycles since the last SOF
    reg [16:0] period;         // measured length of the previous frame
    reg        locked;         // SOF seen recently, with a plausible spacing
    reg [16:0] acc;            // phase accumulator
    reg        tick;

    wire [16:0] period_eff = locked ? period : NOMINAL_PERIOD;

    wire [17:0] acc_sum     = {1'b0, acc} + SAMPLES_FRAME;
    wire        acc_wrap    = (acc_sum >= {1'b0, period_eff});
    wire [17:0] acc_wrapped = acc_sum - {1'b0, period_eff};

    wire        period_ok   = (frame_cnt >= PERIOD_MIN) && (frame_cnt <= PERIOD_MAX);

    always @(posedge SYS_CLK_60M or negedge RESET_N) begin
        if (!RESET_N) begin
            frame_cnt <= 17'd0;
            period    <= NOMINAL_PERIOD;
            locked    <= 1'b0;
            acc       <= 17'd0;
            tick      <= 1'b0;
        end else begin
            //--------------------------------------------------------------------
            // frame timer and lock tracking
            //--------------------------------------------------------------------
            if (SOF) begin
                frame_cnt <= 17'd1;
                if (period_ok) begin
                    period <= frame_cnt;
                    locked <= 1'b1;
                end else begin
                    locked <= 1'b0;          // implausible spacing, do not trust it
                end
            end else if (frame_cnt < SOF_TIMEOUT) begin
                frame_cnt <= frame_cnt + 17'd1;
            end else begin
                locked <= 1'b0;              // SOF has stopped arriving
            end

            //--------------------------------------------------------------------
            // phase accumulator : exactly SAMPLES_FRAME ticks per frame
            //--------------------------------------------------------------------
            if (SOF) begin
                // Realign phase to the frame boundary. Seed with one cycle's worth of
                // increment rather than zero: this cycle still belongs to the new frame,
                // and dropping it would yield 47 ticks per frame instead of 48.
                acc  <= SAMPLES_FRAME[16:0];
                tick <= 1'b0;
            end else if (acc_wrap) begin
                acc  <= acc_wrapped[16:0];
                tick <= 1'b1;
            end else begin
                acc  <= acc_sum[16:0];
                tick <= 1'b0;
            end
        end
    end

    assign SIG_48K = tick;
endmodule
