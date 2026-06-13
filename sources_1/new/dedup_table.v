`timescale 1ns / 1ps
//------------------------------------------------------------------------------
// Deduplication Table (FIFO-based hardware aging)
//   Stores (srcID, count) pairs. lookup=1 checks for duplicate.
//   insert=1 adds new entry; when full, oldest entry is overwritten.
//------------------------------------------------------------------------------
module dedup_table #(
    parameter DEPTH = 64
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        lookup,
    input  wire        insert,
    input  wire [7:0]  lkup_src,
    input  wire [7:0]  ins_src,
    input  wire [15:0] lkup_cnt,
    input  wire [15:0] ins_cnt,
    output reg         found
);
    reg [7:0]  smem [0:DEPTH-1];
    reg [15:0] cmem [0:DEPTH-1];
    reg        v    [0:DEPTH-1];
    reg [$clog2(DEPTH)-1:0] wp;

    always @(posedge clk) begin
        if (rst) begin wp <= 0; found <= 0; end
        else begin
            found <= 0;
            if (lookup) begin
                for (integer i = 0; i < DEPTH; i = i + 1)
                    if (v[i] && smem[i] == lkup_src && cmem[i] == lkup_cnt)
                        found <= 1;
            end
            if (insert) begin
                smem[wp] <= ins_src;
                cmem[wp] <= ins_cnt;
                v[wp]    <= 1;
                wp       <= (wp == DEPTH - 1) ? 0 : wp + 1;
            end
        end
    end

endmodule
