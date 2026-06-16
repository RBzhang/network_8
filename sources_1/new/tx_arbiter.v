`timescale 1ns / 1ps

//------------------------------------------------------------------------------
// tx_arbiter: arbitrates frame descriptors, then starts selected frame_tx blocks.
//------------------------------------------------------------------------------
module tx_arbiter #(
    parameter NUM_PORTS = 2,
    parameter PORT_W    = (NUM_PORTS <= 1) ? 1 : $clog2(NUM_PORTS)
) (
    input  wire clk,
    input  wire rst,
    input  wire [7:0] my_id,
    input  wire       local_req,
    output reg        local_accept,
    input  wire [7:0] local_dst_id,
    input  wire [15:0] local_count,
    input  wire [15:0] local_len16,
    input  wire       forward_req,
    output reg        forward_accept,
    input  wire [NUM_PORTS-1:0] forward_port_mask,
    input  wire [7:0]  forward_src_id,
    input  wire [7:0]  forward_dst_id,
    input  wire [15:0] forward_count,
    input  wire [15:0] forward_len16,
    input  wire [PORT_W-1:0] forward_payload_port,
    input  wire [NUM_PORTS-1:0] tx_busy,
    input  wire [NUM_PORTS-1:0] tx_done,
    input  wire [NUM_PORTS*16-1:0] tx_payload_addr_flat,
    output reg  [NUM_PORTS-1:0] tx_start,
    output reg  [7:0]  tx_src_id,
    output reg  [7:0]  tx_dst_id,
    output reg  [15:0] tx_count,
    output reg  [15:0] tx_len16,
    output reg         tx_payload_is_forward,
    output reg  [PORT_W-1:0] tx_forward_payload_port,
    output reg  [15:0] shared_payload_addr
);
    localparam [1:0] S_IDLE = 2'd0;
    localparam [1:0] S_BUSY = 2'd1;
    localparam [1:0] S_WAIT_DROP = 2'd2;

    reg [1:0] st;
    reg [NUM_PORTS-1:0] active_mask;
    reg active_forward;
    integer i;

    always @(*) begin
        shared_payload_addr = 16'd0;
        for (i = 0; i < NUM_PORTS; i = i + 1)
            if (active_mask[i])
                shared_payload_addr = tx_payload_addr_flat[i*16 +: 16];
    end

    always @(posedge clk) begin
        if (rst) begin
            st <= S_IDLE;
            active_mask <= {NUM_PORTS{1'b0}};
            active_forward <= 1'b0;
            tx_start <= {NUM_PORTS{1'b0}};
            tx_src_id <= 8'd0;
            tx_dst_id <= 8'd0;
            tx_count <= 16'd0;
            tx_len16 <= 16'd0;
            tx_payload_is_forward <= 1'b0;
            tx_forward_payload_port <= {PORT_W{1'b0}};
            local_accept <= 1'b0;
            forward_accept <= 1'b0;
        end else begin
            tx_start <= {NUM_PORTS{1'b0}};
            local_accept <= 1'b0;
            forward_accept <= 1'b0;

            case (st)
                S_IDLE: begin
                    if (forward_req && ((forward_port_mask & tx_busy) == {NUM_PORTS{1'b0}})) begin
                        active_mask <= forward_port_mask;
                        tx_start <= forward_port_mask;
                        tx_src_id <= forward_src_id;
                        tx_dst_id <= forward_dst_id;
                        tx_count <= forward_count;
                        tx_len16 <= forward_len16;
                        tx_payload_is_forward <= 1'b1;
                        tx_forward_payload_port <= forward_payload_port;
                        active_forward <= 1'b1;
                        st <= S_BUSY;
                    end else if (local_req && (tx_busy == {NUM_PORTS{1'b0}})) begin
                        active_mask <= {NUM_PORTS{1'b1}};
                        tx_start <= {NUM_PORTS{1'b1}};
                        tx_src_id <= my_id;
                        tx_dst_id <= local_dst_id;
                        tx_count <= local_count;
                        tx_len16 <= local_len16;
                        tx_payload_is_forward <= 1'b0;
                        tx_forward_payload_port <= {PORT_W{1'b0}};
                        active_forward <= 1'b0;
                        local_accept <= 1'b1;
                        st <= S_BUSY;
                    end
                end

                S_BUSY: begin
                    if ((tx_done & active_mask) == active_mask) begin
                        active_mask <= {NUM_PORTS{1'b0}};
                        if (active_forward) begin
                            forward_accept <= 1'b1;
                            st <= S_WAIT_DROP;
                        end else begin
                            st <= S_IDLE;
                        end
                    end
                end

                S_WAIT_DROP: begin
                    forward_accept <= 1'b1;
                    if (!forward_req) begin
                        forward_accept <= 1'b0;
                        active_forward <= 1'b0;
                        st <= S_IDLE;
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
