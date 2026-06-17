`timescale 1ns / 1ps

//------------------------------------------------------------------------------
// port_cdc: async FIFO boundary and port-domain output registers.
//------------------------------------------------------------------------------
module port_cdc #(
    parameter FIFO_DEPTH = 8192,
    parameter NUM_PORTS  = 2,
    parameter FIFO_COUNT_W = (FIFO_DEPTH <= 1) ? 1 : $clog2(FIFO_DEPTH)
) (
    input  wire        rst,
    input  wire        id_locked,
    input  wire        clk,
    input  wire        rx_clk0,
    input  wire        rx_clk1,
    input  wire        tx_clk0,
    input  wire        tx_clk1,
    input  wire [31:0] in0,
    input  wire [31:0] in1,
    input  wire        valid_in0,
    input  wire        valid_in1,
    input  wire [NUM_PORTS-1:0] rx_rd_en,
    output wire [NUM_PORTS*32-1:0] rx_dout_flat,
    output wire [NUM_PORTS-1:0] rx_empty,
    output wire [NUM_PORTS-1:0] rx_full,
    input  wire [NUM_PORTS-1:0] tx_wr_en,
    input  wire [NUM_PORTS*32-1:0] tx_din_flat,
    output wire [NUM_PORTS-1:0] tx_full,
    output wire [NUM_PORTS*FIFO_COUNT_W-1:0] tx_wr_data_count_flat,
    output wire [NUM_PORTS*32-1:0] tx_dout_flat,
    output wire [NUM_PORTS-1:0] tx_empty,
    output wire [31:0] out0,
    output wire [31:0] out1,
    output wire        valid_out0,
    output wire        valid_out1
);
    reg id_locked_rx0_meta, id_locked_rx0;
    reg id_locked_rx1_meta, id_locked_rx1;
    reg rst_rx0_meta, rst_rx0_sync;
    reg rst_rx1_meta, rst_rx1_sync;
    reg rst_tx0_meta, rst_tx0_sync;
    reg rst_tx1_meta, rst_tx1_sync;

    always @(posedge rx_clk0) begin
        id_locked_rx0_meta <= id_locked;
        id_locked_rx0 <= id_locked_rx0_meta;
        rst_rx0_meta <= rst;
        rst_rx0_sync <= rst_rx0_meta;
    end

    always @(posedge rx_clk1) begin
        id_locked_rx1_meta <= id_locked;
        id_locked_rx1 <= id_locked_rx1_meta;
        rst_rx1_meta <= rst;
        rst_rx1_sync <= rst_rx1_meta;
    end

    always @(posedge tx_clk0) begin
        rst_tx0_meta <= rst;
        rst_tx0_sync <= rst_tx0_meta;
    end

    always @(posedge tx_clk1) begin
        rst_tx1_meta <= rst;
        rst_tx1_sync <= rst_tx1_meta;
    end

    genvar p;
    generate
        for (p = 0; p < NUM_PORTS; p = p + 1) begin : g_fifo
            if (p == 0) begin : g_port0
                wire [FIFO_COUNT_W-1:0] unused_rx_wr_data_count;

                async_fifo #(.DEPTH(FIFO_DEPTH)) u_rx_fifo (
                    .wr_clk(rx_clk0),
                    .rst(rst_rx0_sync),
                    .wr_en(valid_in0 && id_locked_rx0 && !rx_rd_en[p]),
                    .din(in0),
                    .full(rx_full[p]),
                    .wr_data_count(unused_rx_wr_data_count),
                    .rd_clk(clk),
                    .rd_en(rx_rd_en[p]),
                    .dout(rx_dout_flat[p*32 +: 32]),
                    .empty(rx_empty[p])
                );
                async_fifo #(.DEPTH(FIFO_DEPTH)) u_tx_fifo (
                    .wr_clk(clk),
                    .rst(rst),
                    .wr_en(tx_wr_en[p]),
                    .din(tx_din_flat[p*32 +: 32]),
                    .full(tx_full[p]),
                    .wr_data_count(tx_wr_data_count_flat[p*FIFO_COUNT_W +: FIFO_COUNT_W]),
                    .rd_clk(tx_clk0),
                    .rd_en(!tx_empty[p]),
                    .dout(tx_dout_flat[p*32 +: 32]),
                    .empty(tx_empty[p])
                );
            end else begin : g_port1
                wire [FIFO_COUNT_W-1:0] unused_rx_wr_data_count;

                async_fifo #(.DEPTH(FIFO_DEPTH)) u_rx_fifo (
                    .wr_clk(rx_clk1),
                    .rst(rst_rx1_sync),
                    .wr_en(valid_in1 && id_locked_rx1 && !rx_rd_en[p]),
                    .din(in1),
                    .full(rx_full[p]),
                    .wr_data_count(unused_rx_wr_data_count),
                    .rd_clk(clk),
                    .rd_en(rx_rd_en[p]),
                    .dout(rx_dout_flat[p*32 +: 32]),
                    .empty(rx_empty[p])
                );
                async_fifo #(.DEPTH(FIFO_DEPTH)) u_tx_fifo (
                    .wr_clk(clk),
                    .rst(rst),
                    .wr_en(tx_wr_en[p]),
                    .din(tx_din_flat[p*32 +: 32]),
                    .full(tx_full[p]),
                    .wr_data_count(tx_wr_data_count_flat[p*FIFO_COUNT_W +: FIFO_COUNT_W]),
                    .rd_clk(tx_clk1),
                    .rd_en(!tx_empty[p]),
                    .dout(tx_dout_flat[p*32 +: 32]),
                    .empty(tx_empty[p])
                );
            end
        end
    endgenerate

    reg [31:0] out0_r, out1_r;
    reg        valid_out0_r, valid_out1_r;

    always @(posedge tx_clk0) begin
        if (rst_tx0_sync) begin
            out0_r <= 32'd0;
            valid_out0_r <= 1'b0;
        end else begin
            valid_out0_r <= !tx_empty[0];
            if (!tx_empty[0])
                out0_r <= tx_dout_flat[0 +: 32];
        end
    end

    always @(posedge tx_clk1) begin
        if (rst_tx1_sync) begin
            out1_r <= 32'd0;
            valid_out1_r <= 1'b0;
        end else begin
            valid_out1_r <= !tx_empty[1];
            if (!tx_empty[1])
                out1_r <= tx_dout_flat[32 +: 32];
        end
    end

    assign out0 = out0_r;
    assign out1 = out1_r;
    assign valid_out0 = valid_out0_r;
    assign valid_out1 = valid_out1_r;
endmodule
