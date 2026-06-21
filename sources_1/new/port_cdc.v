`timescale 1ns / 1ps

//------------------------------------------------------------------------------
// port_cdc: async FIFO boundary for a parameterized set of optical ports.
//   Each port owns independent RX/TX clocks and independent CDC reset/id sync.
//------------------------------------------------------------------------------
module port_cdc #(
    parameter FIFO_DEPTH = 8192,
    parameter NUM_PORTS  = 2,
    parameter FIFO_COUNT_W = (FIFO_DEPTH <= 1) ? 1 : $clog2(FIFO_DEPTH)
) (
    input  wire        rst,
    input  wire        id_locked,
    input  wire        clk,
    input  wire [NUM_PORTS-1:0] rx_clk,
    input  wire [NUM_PORTS-1:0] tx_clk,
    input  wire [NUM_PORTS*32-1:0] in_flat,
    input  wire [NUM_PORTS-1:0] valid_in,
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
    output wire [NUM_PORTS*32-1:0] out_flat,
    output wire [NUM_PORTS-1:0] valid_out,
    output wire [NUM_PORTS-1:0] rx_overflow
);
    genvar p;
    generate
        for (p = 0; p < NUM_PORTS; p = p + 1) begin : g_port
            reg id_locked_rx_meta;
            reg id_locked_rx_sync;
            reg rst_rx_meta;
            reg rst_rx_sync;
            reg rst_tx_meta;
            reg rst_tx_sync;
            reg [31:0] out_r;
            reg valid_out_r;
            reg tx_rd_en_r;
            reg tx_pop_pending;
            wire [FIFO_COUNT_W-1:0] unused_rx_wr_data_count;
            reg rx_overflow_rx;
            reg rx_overflow_meta;
            reg rx_overflow_sync;

            always @(posedge rx_clk[p]) begin
                id_locked_rx_meta <= id_locked;
                id_locked_rx_sync <= id_locked_rx_meta;
                rst_rx_meta <= rst;
                rst_rx_sync <= rst_rx_meta;
            end

            always @(posedge rx_clk[p]) begin
                if (rst_rx_sync || !id_locked_rx_sync)
                    rx_overflow_rx <= 1'b0;
                else if (valid_in[p] && id_locked_rx_sync && rx_full[p])
                    rx_overflow_rx <= 1'b1;
            end

            always @(posedge tx_clk[p]) begin
                rst_tx_meta <= rst;
                rst_tx_sync <= rst_tx_meta;
            end

            always @(posedge clk) begin
                if (rst || !id_locked) begin
                    rx_overflow_meta <= 1'b0;
                    rx_overflow_sync <= 1'b0;
                end else begin
                    rx_overflow_meta <= rx_overflow_rx;
                    rx_overflow_sync <= rx_overflow_meta;
                end
            end

            async_fifo #(.DEPTH(FIFO_DEPTH)) u_rx_fifo (
                .wr_clk(rx_clk[p]),
                .rst(rst_rx_sync),
                .wr_en(valid_in[p] && id_locked_rx_sync && !rx_full[p]),
                .din(in_flat[p*32 +: 32]),
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
                .rd_clk(tx_clk[p]),
                .rd_en(tx_rd_en_r),
                .dout(tx_dout_flat[p*32 +: 32]),
                .empty(tx_empty[p])
            );

            always @(posedge tx_clk[p]) begin
                if (rst_tx_sync) begin
                    out_r <= 32'd0;
                    valid_out_r <= 1'b0;
                    tx_rd_en_r <= 1'b0;
                    tx_pop_pending <= 1'b0;
                end else if (tx_pop_pending) begin
                    if (tx_rd_en_r) begin
                        tx_rd_en_r <= 1'b0;
                        valid_out_r <= 1'b0;
                        tx_pop_pending <= 1'b0;
                    end else begin
                        tx_rd_en_r <= 1'b1;
                        valid_out_r <= 1'b0;
                    end
                end else if (!tx_empty[p]) begin
                    out_r <= tx_dout_flat[p*32 +: 32];
                    valid_out_r <= 1'b1;
                    tx_rd_en_r <= 1'b0;
                    tx_pop_pending <= 1'b1;
                end else begin
                    tx_rd_en_r <= 1'b0;
                    valid_out_r <= 1'b0;
                end
            end

            assign out_flat[p*32 +: 32] = out_r;
            assign valid_out[p] = valid_out_r;
            assign rx_overflow[p] = rx_overflow_sync;
        end
    endgenerate
endmodule
