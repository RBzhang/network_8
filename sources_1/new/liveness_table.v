`timescale 1ns / 1ps
//------------------------------------------------------------------------------
// Liveness Table (sliding window, 5-period)
//   Every tick_1s pulse: shift all windows left, start uploading table.
//   update=1 sets LSB of window[update_src] to 1 (packet received).
//   Upload: one node per cycle, upload_alive = |window[node] (0=offline).
//
// The window array is NOT cleared by rst (requirement: liveness data must
// survive warm resets). Instead, it is cleared once by init_pulse (the
// first id_locked edge produced by node_id_latch). This is fully
// synthesizable and does not rely on FPGA power-on initial values.
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
    input  wire        init_pulse,
    output reg         upload_valid,
    output reg  [7:0]  upload_node,
    output reg         upload_alive
);
    reg [WINDOW-1:0] w [0:MAX_NODES-1];
    reg [NODE_W-1:0] idx;
    reg       up;
    reg       initialized = 1'b0;
    integer i;

    always @(posedge clk) begin
        if (rst) begin
            up <= 1'b0;
            idx <= {NODE_W{1'b0}};
            upload_valid <= 1'b0;
            upload_node <= 8'd0;
            upload_alive <= 1'b0;
            // initialized <= 1'b0;
        end else begin
            upload_valid <= 1'b0;

            // One-time initialization on the first id_locked edge.
            // Resets window memory (NOT affected by normal rst).
            if (!initialized && init_pulse) begin
                initialized <= 1'b1;
                for (i = 0; i < MAX_NODES; i = i + 1)
                    w[i] <= {WINDOW{1'b0}};
            end

            if (tick_1s) begin
                up <= 1'b1;
                idx <= {NODE_W{1'b0}};
                for (i = 0; i < MAX_NODES; i = i + 1)
                    w[i] <= {w[i][WINDOW-2:0], 1'b0};
                if (update && update_src < MAX_NODES)
                    w[update_src] <= {w[update_src][WINDOW-2:0], 1'b1};
            end else begin
                if (update && update_src < MAX_NODES)
                    w[update_src][0] <= 1'b1;

                if (up) begin
                    upload_node <= idx;
                    upload_alive <= |w[idx];
                    upload_valid <= 1'b1;

                    if (idx == MAX_NODES - 1) begin
                        up <= 1'b0;
                        idx <= {NODE_W{1'b0}};
                    end else begin
                        idx <= idx + 1'b1;
                    end
                end
            end
        end
    end

endmodule
