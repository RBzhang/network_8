`timescale 1ns / 1ps

//------------------------------------------------------------------------------
// frame_meta_fifo: per-frame metadata FIFO for one TX frame queue.
//   din/dout format: {enqueue_time[TIME_W-1:0], frame_words[15:0]}.
//------------------------------------------------------------------------------
module frame_meta_fifo #(
    parameter DEPTH = 8192,
    parameter TIME_W = 32,
    parameter WIDTH = TIME_W + 16,
    parameter PTR_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH),
    parameter COUNT_W = $clog2(DEPTH + 1)
) (
    input  wire               clk,
    input  wire               rst,
    input  wire               wr_en,
    input  wire [WIDTH-1:0]   din,
    input  wire               rd_en,
    output wire [WIDTH-1:0]   dout,
    output wire               empty,
    output wire               full,
    output wire [COUNT_W-1:0] data_count
);
    sync_fifo #(
        .DEPTH(DEPTH),
        .WIDTH(WIDTH),
        .PTR_W(PTR_W),
        .CNT_W(COUNT_W)
    ) u_fifo (
        .clk(clk),
        .rst(rst),
        .wr_en(wr_en),
        .din(din),
        .rd_en(rd_en),
        .dout(dout),
        .empty(empty),
        .full(full),
        .data_count(data_count)
    );
endmodule
