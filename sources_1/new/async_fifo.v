`timescale 1ns / 1ps
//------------------------------------------------------------------------------
// Async FIFO wrapper.
// In Vivado synthesis this instantiates the FIFO IP from:
//   sources_1/ip/fifo_generator_32_512/fifo_generator_32_512.xci
// The behavioral branch is kept for local lint/simulation when USE_IP=0.
//------------------------------------------------------------------------------
module async_fifo #(
    parameter DEPTH  = 512,
    parameter WIDTH  = 32,
    parameter USE_IP = 1,
    parameter ADDR_W  = (DEPTH <= 1) ? 1 : $clog2(DEPTH),
    parameter PTR_W   = ADDR_W + 1,
    parameter COUNT_W = ADDR_W
) (
    input  wire             wr_clk,
    input  wire             rst,
    input  wire             wr_en,
    input  wire [WIDTH-1:0] din,
    output wire             full,
    output wire [COUNT_W-1:0] wr_data_count,

    input  wire             rd_clk,
    input  wire             rd_en,
    output wire [WIDTH-1:0] dout,
    output wire             empty
);
generate
    if (USE_IP) begin : g_vivado_ip
        wire wr_rst_busy;
        wire rd_rst_busy;

        fifo_generator_32_512 u_fifo (
            .rst(rst),
            .wr_clk(wr_clk),
            .rd_clk(rd_clk),
            .din(din[31:0]),
            .wr_en(wr_en),
            .rd_en(rd_en),
            .dout(dout[31:0]),
            .full(full),
            .wr_data_count(wr_data_count),
            .empty(empty),
            .wr_rst_busy(wr_rst_busy),
            .rd_rst_busy(rd_rst_busy)
        );
    end else begin : g_behav
        reg [WIDTH-1:0] mem [0:DEPTH-1];

        reg [PTR_W-1:0] wbin, wgray;
        reg [PTR_W-1:0] rbin, rgray;
        reg [PTR_W-1:0] rq1_wgray, rq2_wgray;
        reg [PTR_W-1:0] wq1_rgray, wq2_rgray;

        wire [PTR_W-1:0] wbin_inc;
        wire [PTR_W-1:0] rbin_inc;
        wire [PTR_W-1:0] wgray_inc;
        wire [PTR_W-1:0] rgray_inc;
        wire [PTR_W-1:0] wgray_full_cmp;
        wire [PTR_W-1:0] rbin_sync;
        wire [PTR_W-1:0] wr_count_full;

        function [PTR_W-1:0] gray_to_bin;
            input [PTR_W-1:0] gray;
            integer gi;
            begin
                gray_to_bin[PTR_W-1] = gray[PTR_W-1];
                for (gi = PTR_W - 2; gi >= 0; gi = gi - 1)
                    gray_to_bin[gi] = gray_to_bin[gi + 1] ^ gray[gi];
            end
        endfunction

        assign wbin_inc = wbin + 1'b1;
        assign rbin_inc = rbin + 1'b1;
        assign wgray_inc = (wbin_inc >> 1) ^ wbin_inc;
        assign rgray_inc = (rbin_inc >> 1) ^ rbin_inc;
        assign rbin_sync = gray_to_bin(rq2_wgray);
        assign wr_count_full = wbin - rbin_sync;

        assign wgray_full_cmp = {~rq2_wgray[PTR_W-1:PTR_W-2], rq2_wgray[PTR_W-3:0]};
        assign full  = (wgray_inc == wgray_full_cmp);
        assign empty = (rgray == wq2_rgray);
        assign dout  = mem[rbin[ADDR_W-1:0]];
        assign wr_data_count = wr_count_full[COUNT_W-1:0];

        always @(posedge wr_clk) begin
            if (rst) begin
                wbin <= 0;
                wgray <= 0;
                rq1_wgray <= 0;
                rq2_wgray <= 0;
            end else begin
                rq1_wgray <= rgray;
                rq2_wgray <= rq1_wgray;

                if (wr_en && !full) begin
                    mem[wbin[ADDR_W-1:0]] <= din;
                    wbin <= wbin_inc;
                    wgray <= wgray_inc;
                end
            end
        end

        always @(posedge rd_clk) begin
            if (rst) begin
                rbin <= 0;
                rgray <= 0;
                wq1_rgray <= 0;
                wq2_rgray <= 0;
            end else begin
                wq1_rgray <= wgray;
                wq2_rgray <= wq1_rgray;

                if (rd_en && !empty) begin
                    rbin <= rbin_inc;
                    rgray <= rgray_inc;
                end
            end
        end
    end
endgenerate

endmodule
