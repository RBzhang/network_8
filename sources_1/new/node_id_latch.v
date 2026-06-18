`timescale 1ns / 1ps

//------------------------------------------------------------------------------
// node_id_latch: accepts only the first ID pulse after reset release.
//------------------------------------------------------------------------------
module node_id_latch (
    input  wire       clk,
    input  wire       rst,
    input  wire       node_id_valid,
    input  wire [7:0] node_id,
    output reg  [7:0] my_id,
    output reg        id_locked
);
    always @(posedge clk) begin
        if (rst) begin
            my_id <= 8'hFF;
            id_locked <= 1'b0;
        end else if (!id_locked && node_id_valid && node_id != 8'hFF) begin
            my_id <= node_id;
            id_locked <= 1'b1;
        end
        else begin
            my_id <= my_id;
            id_locked <= id_locked;
        end
    end
endmodule
