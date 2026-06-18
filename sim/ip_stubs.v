`timescale 1ns / 1ps

module fifo_generator_32_512 (
    input  wire        rst,
    input  wire        wr_clk,
    input  wire        rd_clk,
    input  wire [31:0] din,
    input  wire        wr_en,
    input  wire        rd_en,
    output reg  [31:0] dout,
    output reg         full,
    output reg  [12:0] wr_data_count,
    output reg         empty,
    output wire        wr_rst_busy,
    output wire        rd_rst_busy
);
    assign wr_rst_busy = 1'b0;
    assign rd_rst_busy = 1'b0;
    always @(posedge wr_clk or posedge rst) begin
        if (rst) begin
            full <= 1'b0;
            wr_data_count <= 13'd0;
        end
    end
    always @(posedge rd_clk or posedge rst) begin
        if (rst) begin
            dout <= 32'd0;
            empty <= 1'b0;
        end
    end
endmodule

module fifo_generator_sync (
    input  wire        clk,
    input  wire        srst,
    input  wire [31:0] din,
    input  wire        wr_en,
    input  wire        rd_en,
    output reg  [31:0] dout,
    output reg         full,
    output reg         empty,
    output reg  [11:0] data_count
);
    always @(posedge clk or posedge srst) begin
        if (srst) begin
            dout <= 32'd0;
            full <= 1'b0;
            empty <= 1'b0;
            data_count <= 12'd0;
        end
    end
endmodule
