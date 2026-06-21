`timescale 1ns / 1ps

//------------------------------------------------------------------------------
// tx_frame_fifo: main-clock frame-word FIFO.
//   din/dout format: {sof, eof, data[31:0]}.
//   USE_IP=1: Vivado fifo_generato_txframe (34-bit, depth 8192, FWFT)
//   USE_IP=0: custom sync_fifo (iverilog simulation)
//------------------------------------------------------------------------------
module tx_frame_fifo #(
    parameter DEPTH = 8192,
    parameter WIDTH = 34,
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
            // Vivado IP: fifo_generato_txframe
            //   Common Clock Block RAM, FWFT, 34-bit x 8192
            //   srst (synchronous reset), data_count [13:0]
            fifo_generato_txframe u_fifo (
                .clk(clk),
                .srst(rst),
                .din(din),
                .wr_en(wr_en),
                .rd_en(rd_en),
                .dout(dout),
                .empty(empty),
                .full(full),
                .data_count(data_count)
            );
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
