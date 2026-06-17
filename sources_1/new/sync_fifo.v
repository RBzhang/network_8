`timescale 1ns / 1ps
//------------------------------------------------------------------------------
// Synchronous FIFO (async FIFO placeholder — replace with Xilinx/Altera IP)
//------------------------------------------------------------------------------
module sync_fifo #(
    parameter DEPTH = 8192,
    parameter WIDTH = 32,
    parameter PTR_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH),
    parameter CNT_W = $clog2(DEPTH + 1)
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        wr_en,
    input  wire [WIDTH-1:0] din,
    input  wire        rd_en,
    output wire [WIDTH-1:0] dout,
    output wire        empty,
    output wire        full,
    output wire [CNT_W-1:0] data_count
);
    reg [WIDTH-1:0] mem [0:DEPTH-1];
    reg [PTR_W-1:0] wr_ptr, rd_ptr;
    reg [CNT_W-1:0] count;

    assign empty      = (count == 0);
    assign full       = (count == DEPTH);
    assign dout       = mem[rd_ptr];
    assign data_count = count;

    always @(posedge clk) begin
        if (rst) begin wr_ptr <= 0; rd_ptr <= 0; count <= 0; end
        else begin
            case ({wr_en && !full, rd_en && !empty})
            2'b10: begin
                mem[wr_ptr] <= din;
                wr_ptr <= wr_ptr == DEPTH-1 ? 0 : wr_ptr + 1;
                count  <= count + 1;
            end
            2'b01: begin
                rd_ptr <= rd_ptr == DEPTH-1 ? 0 : rd_ptr + 1;
                count  <= count - 1;
            end
            2'b11: begin
                mem[wr_ptr] <= din;
                wr_ptr <= wr_ptr == DEPTH-1 ? 0 : wr_ptr + 1;
                rd_ptr <= rd_ptr == DEPTH-1 ? 0 : rd_ptr + 1;
            end
            default: begin
                count <= count;
            end
            endcase
        end
    end

endmodule
