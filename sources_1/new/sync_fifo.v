`timescale 1ns / 1ps
//------------------------------------------------------------------------------
// Synchronous FIFO with explicit FWFT output buffering.
// dout_r always holds the current FIFO head; out_valid indicates validity.
// Writes to an empty FIFO bypass directly to dout_r.
// Reads consume dout_r and load the next item from memory into dout_r.
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
    reg [CNT_W-1:0] mem_count;
    reg [WIDTH-1:0] dout_r;
    reg             out_valid;

    assign dout       = dout_r;
    assign empty      = !out_valid;
    assign data_count = mem_count + {{CNT_W-1{1'b0}}, out_valid};
    assign full       = (data_count >= DEPTH);

    wire wr_ok = wr_en && !full;
    wire rd_ok = rd_en && out_valid;

    wire [PTR_W-1:0] wr_ptr_inc = (wr_ptr == DEPTH - 1) ? {PTR_W{1'b0}} : wr_ptr + 1'b1;
    wire [PTR_W-1:0] rd_ptr_inc = (rd_ptr == DEPTH - 1) ? {PTR_W{1'b0}} : rd_ptr + 1'b1;

    always @(posedge clk) begin
        if (rst) begin
            wr_ptr    <= {PTR_W{1'b0}};
            rd_ptr    <= {PTR_W{1'b0}};
            mem_count <= {CNT_W{1'b0}};
            dout_r    <= {WIDTH{1'b0}};
            out_valid <= 1'b0;
        end else begin
            if (wr_ok && rd_ok) begin
                if (mem_count > 0) begin
                    dout_r      <= mem[rd_ptr];
                    rd_ptr      <= rd_ptr_inc;
                    mem[wr_ptr] <= din;
                    wr_ptr      <= wr_ptr_inc;
                end else begin
                    dout_r <= din;
                end
            end else if (wr_ok) begin
                if (!out_valid) begin
                    dout_r    <= din;
                    out_valid <= 1'b1;
                    mem_count <= {CNT_W{1'b0}};
                end else begin
                    mem[wr_ptr] <= din;
                    wr_ptr      <= wr_ptr_inc;
                    mem_count   <= mem_count + 1'b1;
                end
            end else if (rd_ok) begin
                if (mem_count > 0) begin
                    dout_r    <= mem[rd_ptr];
                    rd_ptr    <= rd_ptr_inc;
                    mem_count <= mem_count - 1'b1;
                end else begin
                    out_valid <= 1'b0;
                    mem_count <= {CNT_W{1'b0}};
                end
            end
        end
    end

endmodule
