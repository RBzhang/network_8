`timescale 1ns / 1ps

//------------------------------------------------------------------------------
// RX report FIFO.
//   Write side receives local-delivery words from rx_dispatcher:
//     word 0: {srcID, dstID, count}
//     word 1: {len16, 16'h0000}
//     word 2..: payload words
//   Read side reconstructs the existing app_rx_* header/payload handshake.
//   The Vivado FIFO IP is configured as common-clock FWFT, so dout is valid
//   whenever empty is low.
//------------------------------------------------------------------------------
module rx_report_fifo #(
    parameter DEPTH = 2048,
    parameter USE_IP = 1,
    parameter COUNT_W = 12
) (
    input  wire        clk,
    input  wire        rst,

    input  wire        wr_en,
    input  wire [31:0] din,
    output wire        full,
    output wire [COUNT_W-1:0] data_count,

    output reg         app_rx_frame_valid,
    input  wire        app_rx_frame_ready,
    output reg  [7:0]  app_rx_src_id,
    output reg  [7:0]  app_rx_dst_id,
    output reg  [15:0] app_rx_count,
    output reg  [15:0] app_rx_len16,
    output reg         app_rx_payload_valid,
    input  wire        app_rx_payload_ready,
    output reg  [15:0] app_rx_payload_addr,
    output reg  [31:0] app_rx_payload_data
);
    localparam [1:0] R_HDR0    = 2'd0;
    localparam [1:0] R_HDR1    = 2'd1;
    localparam [1:0] R_FRAME   = 2'd2;
    localparam [1:0] R_PAYLOAD = 2'd3;

    wire [31:0] fifo_dout;
    wire        fifo_empty;
    reg         fifo_rd_en;
    reg  [31:0] header0;
    reg  [15:0] payload_index;

generate
    if (USE_IP) begin : g_vivado_ip
        fifo_generator_sync u_fifo (
            .clk(clk),
            .srst(rst),
            .din(din),
            .wr_en(wr_en),
            .rd_en(fifo_rd_en),
            .dout(fifo_dout),
            .full(full),
            .empty(fifo_empty),
            .data_count(data_count)
        );
    end else begin : g_behav
        sync_fifo #(
            .DEPTH(DEPTH),
            .WIDTH(32),
            .CNT_W(COUNT_W)
        ) u_fifo (
            .clk(clk),
            .rst(rst),
            .wr_en(wr_en),
            .din(din),
            .rd_en(fifo_rd_en),
            .dout(fifo_dout),
            .empty(fifo_empty),
            .full(full),
            .data_count(data_count)
        );
    end
endgenerate

    reg [1:0] st;

    always @(posedge clk) begin
        if (rst) begin
            st <= R_HDR0;
            fifo_rd_en <= 1'b0;
            header0 <= 32'd0;
            payload_index <= 16'd0;
            app_rx_frame_valid <= 1'b0;
            app_rx_src_id <= 8'd0;
            app_rx_dst_id <= 8'd0;
            app_rx_count <= 16'd0;
            app_rx_len16 <= 16'd0;
            app_rx_payload_valid <= 1'b0;
            app_rx_payload_addr <= 16'd0;
            app_rx_payload_data <= 32'd0;
        end else begin
            fifo_rd_en <= 1'b0;

            case (st)
                R_HDR0: begin
                    if (!fifo_empty) begin
                        header0 <= fifo_dout;
                        fifo_rd_en <= 1'b1;
                        st <= R_HDR1;
                    end
                end

                R_HDR1: begin
                    if (!fifo_empty) begin
                        app_rx_src_id <= header0[31:24];
                        app_rx_dst_id <= header0[23:16];
                        app_rx_count <= header0[15:0];
                        app_rx_len16 <= fifo_dout[31:16];
                        app_rx_frame_valid <= 1'b1;
                        fifo_rd_en <= 1'b1;
                        st <= R_FRAME;
                    end
                end

                R_FRAME: begin
                    if (app_rx_frame_valid && app_rx_frame_ready) begin
                        app_rx_frame_valid <= 1'b0;
                        if (app_rx_len16 == 16'd0) begin
                            st <= R_HDR0;
                        end else begin
                            payload_index <= 16'd0;
                            st <= R_PAYLOAD;
                        end
                    end
                end

                R_PAYLOAD: begin
                    if (!app_rx_payload_valid && !fifo_empty) begin
                        app_rx_payload_addr <= payload_index;
                        app_rx_payload_data <= fifo_dout;
                        app_rx_payload_valid <= 1'b1;
                        fifo_rd_en <= 1'b1;
                    end else if (app_rx_payload_valid && app_rx_payload_ready) begin
                        app_rx_payload_valid <= 1'b0;
                        if (payload_index == app_rx_len16 - 1'b1) begin
                            st <= R_HDR0;
                        end else begin
                            payload_index <= payload_index + 1'b1;
                        end
                    end
                end

                default: st <= R_HDR0;
            endcase
        end
    end
endmodule
