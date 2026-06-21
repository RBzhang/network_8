`timescale 1ns / 1ps

//------------------------------------------------------------------------------
// Vivado FIFO IP behavioral stubs for simulation.
//   fifo_generator_32_512: 32-bit wide async FIFO, depth 8192, FWFT
//   fifo_generator_sync:   32-bit wide sync FIFO, depth 2048, FWFT
//
// NOTE: These are simplified models sufficient for functional RTL simulation.
// They do NOT model exact Vivado IP timing (rst_busy, etc.).
//------------------------------------------------------------------------------

module fifo_generator_32_512 (
    input  wire        rst,
    input  wire        wr_clk,
    input  wire        rd_clk,
    input  wire [31:0] din,
    input  wire        wr_en,
    input  wire        rd_en,
    output wire [31:0] dout,
    output wire        full,
    output wire [12:0] wr_data_count,
    output wire        empty,
    output wire        wr_rst_busy,
    output wire        rd_rst_busy
);
    parameter DEPTH = 8192;
    parameter ADDR_W = 13;
    localparam PTR_W = ADDR_W + 1;

    assign wr_rst_busy = 1'b0;
    assign rd_rst_busy = 1'b0;

    reg [31:0] mem [0:DEPTH-1];

    reg [PTR_W-1:0] wptr, rptr;
    reg [PTR_W-1:0] rptr_gray_sync1, rptr_gray_sync2;
    reg [PTR_W-1:0] wptr_gray_sync1, wptr_gray_sync2;
    wire [PTR_W-1:0] wptr_gray, rptr_gray;
    wire [PTR_W-1:0] wptr_next, rptr_next;

    function [PTR_W-1:0] bin2gray;
        input [PTR_W-1:0] bin;
        bin2gray = bin ^ (bin >> 1);
    endfunction

    assign wptr_gray = bin2gray(wptr);
    assign rptr_gray = bin2gray(rptr);
    assign wptr_next = wptr + 1'b1;
    assign rptr_next = rptr + 1'b1;

    assign full  = (wptr_gray == {~rptr_gray_sync2[PTR_W-1:PTR_W-2], rptr_gray_sync2[PTR_W-3:0]});
    assign empty = (rptr_gray == wptr_gray_sync2);
    assign wr_data_count = wptr - {1'b0, rptr_gray_sync2[PTR_W-2:0]};
    assign dout = mem[rptr[ADDR_W-1:0]];

    always @(posedge wr_clk or posedge rst) begin
        if (rst) begin
            wptr <= 0;
            rptr_gray_sync1 <= 0;
            rptr_gray_sync2 <= 0;
        end else begin
            rptr_gray_sync1 <= rptr_gray;
            rptr_gray_sync2 <= rptr_gray_sync1;
            if (wr_en && !full) begin
                mem[wptr[ADDR_W-1:0]] <= din;
                wptr <= wptr_next;
            end
        end
    end

    always @(posedge rd_clk or posedge rst) begin
        if (rst) begin
            rptr <= 0;
            wptr_gray_sync1 <= 0;
            wptr_gray_sync2 <= 0;
        end else begin
            wptr_gray_sync1 <= wptr_gray;
            wptr_gray_sync2 <= wptr_gray_sync1;
            if (rd_en && !empty) begin
                rptr <= rptr_next;
            end
        end
    end
endmodule

//------------------------------------------------------------------------------
// Synchronous FIFO stub
//------------------------------------------------------------------------------
module fifo_generator_sync (
    input  wire        clk,
    input  wire        srst,
    input  wire [31:0] din,
    input  wire        wr_en,
    input  wire        rd_en,
    output wire [31:0] dout,
    output wire        full,
    output wire        empty,
    output wire [11:0] data_count
);
    parameter DEPTH = 2048;
    parameter ADDR_W = 11;

    reg [31:0] mem [0:DEPTH-1];
    reg [ADDR_W:0] count;
    reg [ADDR_W-1:0] wptr, rptr;

    assign empty = (count == 0);
    assign full  = (count == DEPTH);
    assign dout  = mem[rptr];
    assign data_count = count[11:0];

    always @(posedge clk or posedge srst) begin
        if (srst) begin
            wptr <= 0;
            rptr <= 0;
            count <= 0;
        end else begin
            case ({wr_en && !full, rd_en && !empty})
                2'b10: begin
                    mem[wptr] <= din;
                    wptr <= wptr == DEPTH - 1 ? 0 : wptr + 1;
                    count <= count + 1;
                end
                2'b01: begin
                    rptr <= rptr == DEPTH - 1 ? 0 : rptr + 1;
                    count <= count - 1;
                end
                2'b11: begin
                    mem[wptr] <= din;
                    wptr <= wptr == DEPTH - 1 ? 0 : wptr + 1;
                    rptr <= rptr == DEPTH - 1 ? 0 : rptr + 1;
                end
            endcase
        end
    end
endmodule

//------------------------------------------------------------------------------
// tx_frame_fifo IP stub: fifo_generato_txframe
//   34-bit wide sync FIFO, depth 8192, FWFT, srst
//------------------------------------------------------------------------------
module fifo_generato_txframe (
    input  wire        clk,
    input  wire        srst,
    input  wire [33:0] din,
    input  wire        wr_en,
    input  wire        rd_en,
    output wire [33:0] dout,
    output wire        full,
    output wire        empty,
    output wire [13:0] data_count
);
    parameter DEPTH = 8192;
    parameter ADDR_W = 13;

    reg [33:0] mem [0:DEPTH-1];
    reg [ADDR_W:0] count;
    reg [ADDR_W-1:0] wptr, rptr;

    assign empty = (count == 0);
    assign full  = (count == DEPTH);
    assign dout  = mem[rptr];
    assign data_count = count[13:0];

    always @(posedge clk) begin
        if (srst) begin
            wptr <= 0;
            rptr <= 0;
            count <= 0;
        end else begin
            case ({wr_en && !full, rd_en && !empty})
                2'b10: begin
                    mem[wptr] <= din;
                    wptr <= (wptr == DEPTH - 1) ? 0 : wptr + 1;
                    count <= count + 1;
                end
                2'b01: begin
                    rptr <= (rptr == DEPTH - 1) ? 0 : rptr + 1;
                    count <= count - 1;
                end
                2'b11: begin
                    mem[wptr] <= din;
                    wptr <= (wptr == DEPTH - 1) ? 0 : wptr + 1;
                    rptr <= (rptr == DEPTH - 1) ? 0 : rptr + 1;
                end
            endcase
        end
    end
endmodule

//------------------------------------------------------------------------------
// frame_meta_fifo IP stub: fifo_generator_meta
//   48-bit wide sync FIFO, depth 512, FWFT, srst
//------------------------------------------------------------------------------
module fifo_generator_meta (
    input  wire        clk,
    input  wire        srst,
    input  wire [47:0] din,
    input  wire        wr_en,
    input  wire        rd_en,
    output wire [47:0] dout,
    output wire        full,
    output wire        empty,
    output wire [9:0]  data_count
);
    parameter DEPTH = 512;
    parameter ADDR_W = 9;

    reg [47:0] mem [0:DEPTH-1];
    reg [ADDR_W:0] count;
    reg [ADDR_W-1:0] wptr, rptr;

    assign empty = (count == 0);
    assign full  = (count == DEPTH);
    assign dout  = mem[rptr];
    assign data_count = count[9:0];

    always @(posedge clk) begin
        if (srst) begin
            wptr <= 0;
            rptr <= 0;
            count <= 0;
        end else begin
            case ({wr_en && !full, rd_en && !empty})
                2'b10: begin
                    mem[wptr] <= din;
                    wptr <= (wptr == DEPTH - 1) ? 0 : wptr + 1;
                    count <= count + 1;
                end
                2'b01: begin
                    rptr <= (rptr == DEPTH - 1) ? 0 : rptr + 1;
                    count <= count - 1;
                end
                2'b11: begin
                    mem[wptr] <= din;
                    wptr <= (wptr == DEPTH - 1) ? 0 : wptr + 1;
                    rptr <= (rptr == DEPTH - 1) ? 0 : rptr + 1;
                end
            endcase
        end
    end
endmodule
