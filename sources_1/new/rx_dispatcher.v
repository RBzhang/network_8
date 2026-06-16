`timescale 1ns / 1ps

//------------------------------------------------------------------------------
// rx_dispatcher: classifies received frames and performs only local dispatch.
//------------------------------------------------------------------------------
module rx_dispatcher #(
    parameter BROADCAST = 8'hFF,
    parameter NUM_PORTS = 2,
    parameter PORT_W    = (NUM_PORTS <= 1) ? 1 : $clog2(NUM_PORTS),
    parameter SCAN_W    = $clog2(NUM_PORTS + 1)
) (
    input  wire clk,
    input  wire rst,
    input  wire [7:0] my_id,
    input  wire [NUM_PORTS-1:0] frame_ready,
    output reg  [NUM_PORTS-1:0] frame_consumed,
    input  wire [NUM_PORTS*8-1:0]  rx_src_id_flat,
    input  wire [NUM_PORTS*8-1:0]  rx_dst_id_flat,
    input  wire [NUM_PORTS*16-1:0] rx_count_flat,
    input  wire [NUM_PORTS*16-1:0] rx_len16_flat,
    output wire [NUM_PORTS*16-1:0] rx_payload_addr_flat,
    input  wire [NUM_PORTS*32-1:0] rx_payload_data_flat,
    input  wire [NUM_PORTS-1:0] rx_is_broadcast,
    output reg         app_rx_frame_valid,
    input  wire        app_rx_frame_ready,
    output reg  [7:0]  app_rx_src_id,
    output reg  [7:0]  app_rx_dst_id,
    output reg  [15:0] app_rx_count,
    output reg  [15:0] app_rx_len16,
    output reg         app_rx_payload_valid,
    input  wire        app_rx_payload_ready,
    output reg  [15:0] app_rx_payload_addr,
    output reg  [31:0] app_rx_payload_data,
    output reg         liveness_update,
    output reg  [7:0]  liveness_update_src,
    output reg         forward_valid,
    input  wire        forward_ready,
    input  wire        forward_done,
    output reg  [PORT_W-1:0] forward_rx_port,
    output reg  [7:0]  forward_src_id,
    output reg  [7:0]  forward_dst_id,
    output reg  [15:0] forward_count,
    output reg  [15:0] forward_len16
);
    localparam [2:0] S_POLL      = 3'd0;
    localparam [2:0] S_CLASSIFY  = 3'd1;
    localparam [2:0] S_LOCAL_HDR = 3'd2;
    localparam [2:0] S_LOCAL_LOAD = 3'd3;
    localparam [2:0] S_LOCAL_PAY  = 3'd4;
    localparam [2:0] S_FWD_REQ    = 3'd5;
    localparam [2:0] S_FWD_WAIT   = 3'd6;

    reg [2:0] st;
    reg [PORT_W-1:0] scan_port;
    reg [PORT_W-1:0] poll_base;
    reg [SCAN_W-1:0] scan_count;
    reg [PORT_W-1:0] active_port;
    reg [15:0] payload_index;
    reg        local_needs_forward;
    reg [15:0] rx_payload_addr_r [0:NUM_PORTS-1];
    integer i;

    wire [7:0]  active_src_id = rx_src_id_flat[active_port*8 +: 8];
    wire [7:0]  active_dst_id = rx_dst_id_flat[active_port*8 +: 8];
    wire [15:0] active_count  = rx_count_flat[active_port*16 +: 16];
    wire [15:0] active_len16  = rx_len16_flat[active_port*16 +: 16];
    wire [31:0] active_payload_data = rx_payload_data_flat[active_port*32 +: 32];

    genvar rp;
    generate
        for (rp = 0; rp < NUM_PORTS; rp = rp + 1) begin : g_addr_flat
            assign rx_payload_addr_flat[rp*16 +: 16] = rx_payload_addr_r[rp];
        end
    endgenerate

    always @(posedge clk) begin
        if (rst) begin
            st <= S_POLL;
            scan_port <= {PORT_W{1'b0}};
            poll_base <= {PORT_W{1'b0}};
            scan_count <= {SCAN_W{1'b0}};
            active_port <= {PORT_W{1'b0}};
            payload_index <= 16'd0;
            local_needs_forward <= 1'b0;
            frame_consumed <= {NUM_PORTS{1'b0}};
            app_rx_frame_valid <= 1'b0;
            app_rx_src_id <= 8'd0;
            app_rx_dst_id <= 8'd0;
            app_rx_count <= 16'd0;
            app_rx_len16 <= 16'd0;
            app_rx_payload_valid <= 1'b0;
            app_rx_payload_addr <= 16'd0;
            app_rx_payload_data <= 32'd0;
            liveness_update <= 1'b0;
            liveness_update_src <= 8'd0;
            forward_valid <= 1'b0;
            forward_rx_port <= {PORT_W{1'b0}};
            forward_src_id <= 8'd0;
            forward_dst_id <= 8'd0;
            forward_count <= 16'd0;
            forward_len16 <= 16'd0;
            for (i = 0; i < NUM_PORTS; i = i + 1)
                rx_payload_addr_r[i] <= 16'd0;
        end else begin
            frame_consumed <= {NUM_PORTS{1'b0}};
            liveness_update <= 1'b0;

            case (st)
                S_POLL: begin
                    forward_valid <= 1'b0;
                    if (scan_count == 0) begin
                        scan_port <= poll_base;
                        scan_count <= 1;
                    end else if (frame_ready[scan_port]) begin
                        active_port <= scan_port;
                        poll_base <= (scan_port == NUM_PORTS - 1) ? {PORT_W{1'b0}} : scan_port + 1'b1;
                        scan_count <= 0;
                        st <= S_CLASSIFY;
                    end else if (scan_count == NUM_PORTS) begin
                        poll_base <= (poll_base == NUM_PORTS - 1) ? {PORT_W{1'b0}} : poll_base + 1'b1;
                        scan_count <= 0;
                    end else begin
                        scan_port <= (scan_port == NUM_PORTS - 1) ? {PORT_W{1'b0}} : scan_port + 1'b1;
                        scan_count <= scan_count + 1'b1;
                    end
                end

                S_CLASSIFY: begin
                    if (active_src_id == my_id) begin
                        frame_consumed[active_port] <= 1'b1;
                        st <= S_POLL;
                    end else begin
                        liveness_update <= 1'b1;
                        liveness_update_src <= active_src_id;

                        if (active_dst_id == my_id || (rx_is_broadcast[active_port] && active_len16 != 0)) begin
                            app_rx_src_id <= active_src_id;
                            app_rx_dst_id <= active_dst_id;
                            app_rx_count <= active_count;
                            app_rx_len16 <= active_len16;
                            app_rx_frame_valid <= 1'b1;
                            local_needs_forward <= rx_is_broadcast[active_port] && (active_len16 != 0);
                            payload_index <= 16'd0;
                            rx_payload_addr_r[active_port] <= 16'd0;
                            st <= S_LOCAL_HDR;
                        end else begin
                            forward_rx_port <= active_port;
                            forward_src_id <= active_src_id;
                            forward_dst_id <= active_dst_id;
                            forward_count <= active_count;
                            forward_len16 <= active_len16;
                            forward_valid <= 1'b1;
                            st <= S_FWD_REQ;
                        end
                    end
                end

                S_LOCAL_HDR: begin
                    if (app_rx_frame_valid && app_rx_frame_ready) begin
                        app_rx_frame_valid <= 1'b0;
                        if (app_rx_len16 == 0) begin
                            if (local_needs_forward) begin
                                forward_rx_port <= active_port;
                                forward_src_id <= active_src_id;
                                forward_dst_id <= active_dst_id;
                                forward_count <= active_count;
                                forward_len16 <= active_len16;
                                forward_valid <= 1'b1;
                                st <= S_FWD_REQ;
                            end else begin
                                frame_consumed[active_port] <= 1'b1;
                                st <= S_POLL;
                            end
                        end else begin
                            payload_index <= 16'd0;
                            rx_payload_addr_r[active_port] <= 16'd0;
                            st <= S_LOCAL_LOAD;
                        end
                    end
                end

                S_LOCAL_LOAD: begin
                    app_rx_payload_addr <= payload_index;
                    app_rx_payload_data <= active_payload_data;
                    app_rx_payload_valid <= 1'b1;
                    st <= S_LOCAL_PAY;
                end

                S_LOCAL_PAY: begin
                    if (app_rx_payload_valid && app_rx_payload_ready) begin
                        app_rx_payload_valid <= 1'b0;
                        if (payload_index == app_rx_len16 - 1) begin
                            if (local_needs_forward) begin
                                forward_rx_port <= active_port;
                                forward_src_id <= active_src_id;
                                forward_dst_id <= active_dst_id;
                                forward_count <= active_count;
                                forward_len16 <= active_len16;
                                forward_valid <= 1'b1;
                                st <= S_FWD_REQ;
                            end else begin
                                frame_consumed[active_port] <= 1'b1;
                                st <= S_POLL;
                            end
                        end else begin
                            payload_index <= payload_index + 1'b1;
                            rx_payload_addr_r[active_port] <= payload_index + 1'b1;
                            st <= S_LOCAL_LOAD;
                        end
                    end
                end

                S_FWD_REQ: begin
                    if (forward_valid && forward_ready) begin
                        forward_valid <= 1'b0;
                        st <= S_FWD_WAIT;
                    end
                end

                S_FWD_WAIT: begin
                    if (forward_done) begin
                        frame_consumed[active_port] <= 1'b1;
                        st <= S_POLL;
                    end
                end

                default: st <= S_POLL;
            endcase
        end
    end
endmodule
