`timescale 1ns / 1ps
//------------------------------------------------------------------------------
// Synchronous FIFO (async FIFO placeholder — replace with Xilinx/Altera IP)
//------------------------------------------------------------------------------
module sync_fifo #(
    parameter DEPTH = 512,
    parameter WIDTH = 32
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        wr_en,
    input  wire [WIDTH-1:0] din,
    input  wire        rd_en,
    output wire [WIDTH-1:0] dout,
    output wire        empty,
    output wire        full,
    output wire [$clog2(DEPTH)-1:0] data_count
);
    reg [WIDTH-1:0] mem [0:DEPTH-1];
    reg [$clog2(DEPTH)-1:0] wr_ptr, rd_ptr, count;

    assign empty      = (count == 0);
    assign full       = (count == DEPTH);
    assign dout       = mem[rd_ptr];
    assign data_count = count;

    always @(posedge clk) begin
        if (rst) begin wr_ptr <= 0; rd_ptr <= 0; count <= 0; end
        else begin
            if (wr_en && !full) begin
                mem[wr_ptr] <= din;
                wr_ptr <= wr_ptr == DEPTH-1 ? 0 : wr_ptr + 1;
                count  <= count + 1;
            end
            if (rd_en && !empty) begin
                rd_ptr <= rd_ptr == DEPTH-1 ? 0 : rd_ptr + 1;
                count  <= count - 1;
            end
        end
    end

endmodule
