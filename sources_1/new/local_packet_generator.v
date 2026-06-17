`timescale 1ns / 1ps

//------------------------------------------------------------------------------
// local_packet_generator: produces only locally-originated frame descriptors.
//------------------------------------------------------------------------------
module local_packet_generator #(
    parameter BROADCAST   = 8'hFF,
    parameter MAX_PAYLOAD = 256
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        tick_1s,
    input  wire        tx_congested,
    input  wire        app_frame_valid,
    output wire        app_frame_ready,
    output reg         app_frame_accepted,
    output reg         app_frame_done,
    input  wire [7:0]  app_dst_id,
    input  wire [15:0] app_len16,
    output reg         packet_req,
    input  wire        packet_accept,
    input  wire        packet_app_done,
    output reg         packet_is_app,
    output reg  [7:0]  packet_dst_id,
    output reg  [15:0] packet_count,
    output reg  [15:0] packet_len16,
    output wire app_len_error
);
    reg [15:0] next_count;
    reg        liveness_pending;
    reg        app_payload_busy;

    assign app_frame_ready = !rst && !tx_congested && !packet_req && !app_payload_busy && (app_len16 <= MAX_PAYLOAD) && (app_len16 > 0);
    assign app_len_error = app_frame_valid && (app_len16 > MAX_PAYLOAD);

    always @(posedge clk) begin
        if (rst) begin
            next_count <= 16'd0;
            liveness_pending <= 1'b0;
            app_payload_busy <= 1'b0;
            app_frame_accepted <= 1'b0;
            app_frame_done <= 1'b0;
            packet_req <= 1'b0;
            packet_is_app <= 1'b0;
            packet_dst_id <= BROADCAST;
            packet_count <= 16'd0;
            packet_len16 <= 16'd0;
        end else begin
            app_frame_accepted <= 1'b0;
            app_frame_done <= 1'b0;

            if (packet_app_done) begin
                app_payload_busy <= 1'b0;
                app_frame_done <= 1'b1;
            end

            if (tick_1s)
                liveness_pending <= 1'b1;

            if (packet_req) begin
                if (packet_accept)
                    packet_req <= 1'b0;
            end else if (app_frame_valid && !tx_congested && !app_payload_busy) begin
                packet_req <= 1'b1;
                packet_is_app <= 1'b1;
                packet_dst_id <= app_dst_id;
                packet_count <= next_count;
                packet_len16 <= (app_len16 > MAX_PAYLOAD) ? MAX_PAYLOAD : app_len16;
                next_count <= next_count + 1'b1;
                app_payload_busy <= 1'b1;
                app_frame_accepted <= 1'b1;
            end else if (liveness_pending) begin
                packet_req <= 1'b1;
                packet_is_app <= 1'b0;
                packet_dst_id <= BROADCAST;
                packet_count <= next_count;
                packet_len16 <= 16'd0;
                next_count <= next_count + 1'b1;
                liveness_pending <= 1'b0;
            end
        end
    end
endmodule
