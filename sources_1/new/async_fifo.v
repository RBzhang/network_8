`timescale 1ns / 1ps
//------------------------------------------------------------------------------
// Dual-clock FIFO for CDC between a per-port clock and the internal core clock.
// DEPTH should be a power of two for the Gray-pointer full/empty logic.
//------------------------------------------------------------------------------
module async_fifo #(
    parameter DEPTH = 512,
    parameter WIDTH = 32,
    parameter ADDR_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH),
    parameter PTR_W  = ADDR_W + 1
) (
    input  wire              wr_clk,
    input  wire              rst,
    input  wire              wr_en,
    input  wire [WIDTH-1:0]  din,
    output wire              full,

    input  wire              rd_clk,
    input  wire              rd_en,
    output wire [WIDTH-1:0]  dout,
    output wire              empty
);
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

    assign wbin_inc = wbin + 1'b1;
    assign rbin_inc = rbin + 1'b1;
    assign wgray_inc = (wbin_inc >> 1) ^ wbin_inc;
    assign rgray_inc = (rbin_inc >> 1) ^ rbin_inc;

    assign wgray_full_cmp = {~rq2_wgray[PTR_W-1:PTR_W-2], rq2_wgray[PTR_W-3:0]};
    assign full  = (wgray_inc == wgray_full_cmp);
    assign empty = (rgray == wq2_rgray);
    assign dout  = mem[rbin[ADDR_W-1:0]];

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

endmodule
