// async_fifo.v
module async_fifo #(
    parameter DATA_WIDTH = 32,   // 32 bits = 16-bit L + 16-bit R
    parameter ADDR_WIDTH = 4     // depth = 2^4 = 16 entries
)(
    // Write side - USB clock domain (60MHz)
    input  wire                  wr_clk,
    input  wire                  wr_rst_n,
    input  wire                  wr_en,
    input  wire [DATA_WIDTH-1:0] wr_data,
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

// Binary pointers
reg [ADDR_WIDTH:0] wr_ptr_bin = 0;
reg [ADDR_WIDTH:0] rd_ptr_bin = 0;

// Gray code pointers
wire [ADDR_WIDTH:0] wr_ptr_gray = wr_ptr_bin ^ (wr_ptr_bin >> 1);
wire [ADDR_WIDTH:0] rd_ptr_gray = rd_ptr_bin ^ (rd_ptr_bin >> 1);

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
        wr_ptr_gray_sync1 <= wr_ptr_gray;       // sync wr gray ptr into rd domain
        wr_ptr_gray_sync2 <= wr_ptr_gray_sync1;
    end

// Full and empty flags
assign wr_full  = (wr_ptr_gray == {~rd_ptr_gray_sync2[ADDR_WIDTH:ADDR_WIDTH-1],
                                     rd_ptr_gray_sync2[ADDR_WIDTH-2:0]});
assign rd_empty = (rd_ptr_gray == wr_ptr_gray_sync2);

// Write logic
always @ (posedge wr_clk)
    if (wr_en && !wr_full)
        mem[wr_ptr_bin[ADDR_WIDTH-1:0]] <= wr_data;

always @ (posedge wr_clk or negedge wr_rst_n)
    if (~wr_rst_n) wr_ptr_bin <= 0;
    else if (wr_en && !wr_full)
        wr_ptr_bin <= wr_ptr_bin + 1;

// Read logic
assign rd_data = mem[rd_ptr_bin[ADDR_WIDTH-1:0]];

always @ (posedge rd_clk or negedge rd_rst_n)
    if (~rd_rst_n) rd_ptr_bin <= 0;
    else if (rd_en && !rd_empty)
        rd_ptr_bin <= rd_ptr_bin + 1;

endmodule