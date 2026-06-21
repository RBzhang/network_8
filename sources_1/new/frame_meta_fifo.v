`timescale 1ns / 1ps

//------------------------------------------------------------------------------
// frame_meta_fifo: per-frame metadata FIFO for one TX frame queue.
//   din/dout format: {enqueue_time[TIME_W-1:0], frame_words[15:0]}.
//   USE_IP=1: Vivado fifo_generator_meta (48-bit, depth 512, FWFT)
//   USE_IP=0: custom sync_fifo (iverilog simulation)
//------------------------------------------------------------------------------
module frame_meta_fifo #(
    parameter DEPTH = 8192,
    parameter TIME_W = 32,
    parameter WIDTH = TIME_W + 16,
    parameter USE_IP = 1,
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
    generate
        if (USE_IP) begin : g_ip
            // Vivado IP: fifo_generator_meta
            //   Common Clock Block RAM, FWFT, 48-bit x 512
            //   srst (synchronous reset), data_count [9:0]
            wire [9:0] ip_data_count;

            fifo_generator_meta u_fifo (
                .clk(clk),
                .srst(rst),
                .din(din),
                .wr_en(wr_en),
                .rd_en(rd_en),
                .dout(dout),
                .empty(empty),
                .full(full),
                .data_count(ip_data_count)
            );

            // Pad 10-bit IP data_count to COUNT_W (14-bit) for interface compatibility
            assign data_count = {{COUNT_W-10{1'b0}}, ip_data_count};
        end else begin : g_behav
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
        end
    endgenerate
endmodule
