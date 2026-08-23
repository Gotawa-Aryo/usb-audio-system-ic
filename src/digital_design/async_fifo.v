`timescale 1ns / 1ps
// async_fifo.v
//
// Block 1.2 "FIFO Buffer" of Figure 3.
//
// Writes are SPECULATIVE. The USB packet layer streams payload bytes to the endpoint as they
// arrive, and only learns whether the CRC16 checked out once the whole packet has been
// received - so by the time a bad packet is known to be bad, its samples have already been
// written here. USB requires a receiver to discard a packet that fails CRC, and for an
// isochronous endpoint there is no retry, so the data must simply not be played.
//
// The write side therefore keeps two pointers: wr_ptr_spec, where the next write lands, and
// wr_ptr_bin, the committed pointer the read side actually sees. wr_commit publishes the
// speculative writes; wr_abort discards them by rewinding to the committed pointer. Only the
// committed pointer crosses to the read domain, so a rejected packet is never visible
// downstream.
//
// Tying wr_commit=1 and wr_abort=0 reproduces the original write-through behaviour.

module async_fifo #(
    parameter DATA_WIDTH = 32,   // 32 bits = 16-bit L + 16-bit R
    parameter ADDR_WIDTH = 4     // depth = 2^4 = 16 entries
)(
    // Write side - USB clock domain (60MHz)
    input  wire                  wr_clk,
    input  wire                  wr_rst_n,
    input  wire                  wr_en,
    input  wire [DATA_WIDTH-1:0] wr_data,
    input  wire                  wr_commit,   // publish the speculative writes
    input  wire                  wr_abort,    // discard them
    output wire                  wr_full,

    // Read side - DAC clock domain
    input  wire                  rd_clk,
    input  wire                  rd_rst_n,
    input  wire                  rd_en,
    output wire [DATA_WIDTH-1:0] rd_data,
    output wire                  rd_empty
);

localparam DEPTH = 1 << ADDR_WIDTH;

// Memory
reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

// Binary pointers. wr_ptr_bin is the committed write pointer; wr_ptr_spec runs ahead of it
// while a packet is being received.
reg [ADDR_WIDTH:0] wr_ptr_bin  = 0;
reg [ADDR_WIDTH:0] wr_ptr_spec = 0;
reg [ADDR_WIDTH:0] rd_ptr_bin  = 0;

// Gray code pointers. Only the committed write pointer crosses to the read domain.
wire [ADDR_WIDTH:0] wr_ptr_gray  = wr_ptr_bin  ^ (wr_ptr_bin  >> 1);
wire [ADDR_WIDTH:0] wr_spec_gray = wr_ptr_spec ^ (wr_ptr_spec >> 1);
wire [ADDR_WIDTH:0] rd_ptr_gray  = rd_ptr_bin  ^ (rd_ptr_bin  >> 1);

// Synchronize gray pointers across domains (2 flip-flop synchronizer)
reg [ADDR_WIDTH:0] rd_ptr_gray_sync1 = 0, rd_ptr_gray_sync2 = 0;
reg [ADDR_WIDTH:0] wr_ptr_gray_sync1 = 0, wr_ptr_gray_sync2 = 0;

always @ (posedge wr_clk or negedge wr_rst_n)
    if (~wr_rst_n) begin
        rd_ptr_gray_sync1 <= 0;
        rd_ptr_gray_sync2 <= 0;
    end else begin
        rd_ptr_gray_sync1 <= rd_ptr_gray;       // sync rd gray ptr into wr domain
        rd_ptr_gray_sync2 <= rd_ptr_gray_sync1;
    end

always @ (posedge rd_clk or negedge rd_rst_n)
    if (~rd_rst_n) begin
        wr_ptr_gray_sync1 <= 0;
        wr_ptr_gray_sync2 <= 0;
    end else begin
        wr_ptr_gray_sync1 <= wr_ptr_gray;       // committed pointer only
        wr_ptr_gray_sync2 <= wr_ptr_gray_sync1;
    end

// Full is measured against the speculative pointer, so an in-flight packet can never
// overwrite data the reader has not taken yet.
assign wr_full  = (wr_spec_gray == {~rd_ptr_gray_sync2[ADDR_WIDTH:ADDR_WIDTH-1],
                                     rd_ptr_gray_sync2[ADDR_WIDTH-2:0]});
assign rd_empty = (rd_ptr_gray == wr_ptr_gray_sync2);

// Write logic
always @ (posedge wr_clk)
    if (wr_en && !wr_full)
        mem[wr_ptr_spec[ADDR_WIDTH-1:0]] <= wr_data;

always @ (posedge wr_clk or negedge wr_rst_n)
    if (~wr_rst_n) begin
        wr_ptr_bin  <= 0;
        wr_ptr_spec <= 0;
    end else begin
        if (wr_en && !wr_full)
            wr_ptr_spec <= wr_ptr_spec + 1;

        if (wr_commit)
            wr_ptr_bin  <= (wr_en && !wr_full) ? wr_ptr_spec + 1 : wr_ptr_spec;

        if (wr_abort)                            // last assignment wins: rewind
            wr_ptr_spec <= wr_ptr_bin;
    end

// Read logic
assign rd_data = mem[rd_ptr_bin[ADDR_WIDTH-1:0]];

always @ (posedge rd_clk or negedge rd_rst_n)
    if (~rd_rst_n) rd_ptr_bin <= 0;
    else if (rd_en && !rd_empty)
        rd_ptr_bin <= rd_ptr_bin + 1;

endmodule
