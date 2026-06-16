`timescale 1ns / 1ps
//------------------------------------------------------------------------------
// Liveness Table (sliding window, 5-period)
//   Every tick_1s pulse: shift all windows left, start uploading table.
//   update=1 sets LSB of window[update_src] to 1 (packet received).
//   Upload: one node per cycle, upload_alive = |window[node] (0=offline).
//------------------------------------------------------------------------------
module liveness_table #(
    parameter MAX_NODES = 255,
    parameter WINDOW    = 5,
    parameter NODE_W    = (MAX_NODES <= 1) ? 1 : $clog2(MAX_NODES)
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        tick_1s,
    input  wire        update,
    input  wire [7:0]  update_src,
    output reg         upload_valid,
    output reg  [7:0]  upload_node,
    output reg         upload_alive
);
    reg [WINDOW-1:0] w [0:MAX_NODES-1];
    reg [NODE_W-1:0] idx;
    reg       up;
    integer i;

    initial begin
        up = 0;
        idx = 0;
        upload_valid = 0;
        upload_node = 0;
        upload_alive = 0;
        for (i = 0; i < MAX_NODES; i = i + 1)
            w[i] = {WINDOW{1'b0}};
    end

    always @(posedge clk) begin
        if (rst) begin
            up <= 0; idx <= 0;
            upload_valid <= 0; upload_node <= 0; upload_alive <= 0;
        end else begin

            if (update)
                w[update_src][0] = 1;

            if (tick_1s) begin
                up  <= 1;
                idx <= 0;
                upload_valid <= 0;
                upload_node  <= 0;
                upload_alive <= upload_alive;
                for (i = 0; i < MAX_NODES; i = i + 1)
                    w[i] <= {w[i][WINDOW-2:0], 1'b0};
            end


            if (up) begin
                upload_node  <= idx;
                upload_alive <= |w[idx];
                if (idx == MAX_NODES - 1) begin
                    up <= 0;
                    idx <= 0;
                    upload_valid <= 0;
                end else begin
                    up <= 1'b1;
                    idx <= idx + 1;
                    upload_valid <= 1;
                end
            end
        end
    end

endmodule
