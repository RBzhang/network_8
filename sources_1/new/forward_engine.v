`timescale 1ns / 1ps

//------------------------------------------------------------------------------
// forward_engine: tracks forwarded frames and produces forwarded descriptors.
//------------------------------------------------------------------------------
module forward_engine #(
    parameter DEDUP_DEPTH = 64,
    parameter NUM_PORTS   = 2,
    parameter PORT_W      = (NUM_PORTS <= 1) ? 1 : $clog2(NUM_PORTS)
) (
    input  wire clk,
    input  wire rst,
    input  wire candidate_valid,
    output wire candidate_ready,
    output reg  candidate_done,
    input  wire [PORT_W-1:0] candidate_rx_port,
    input  wire [7:0]  candidate_src_id,
    input  wire [7:0]  candidate_dst_id,
    input  wire [15:0] candidate_count,
    input  wire [15:0] candidate_len16,
    input  wire        candidate_should_forward,
    output reg         forward_req,
    input  wire        forward_accept,
    input  wire        forward_dropped,
    output reg  [NUM_PORTS-1:0] forward_port_mask,
    output reg  [7:0]  forward_src_id,
    output reg  [7:0]  forward_dst_id,
    output reg  [15:0] forward_count,
    output reg  [15:0] forward_len16,
    output reg  [PORT_W-1:0] payload_port,
    output reg         candidate_duplicate
);
    localparam [1:0] S_IDLE   = 2'd0;
    localparam [1:0] S_LOOKUP = 2'd1;
    localparam [1:0] S_DECIDE = 2'd2;
    localparam [1:0] S_REQ    = 2'd3;

    reg [1:0] st;
    reg       forward_dedup_lookup;
    reg       forward_dedup_insert;
    reg [7:0] forward_dedup_src;
    reg [15:0] forward_dedup_count;
    wire      forward_dedup_found;
    integer i;

    assign candidate_ready = (st == S_IDLE);

    dedup_table #(.DEPTH(DEDUP_DEPTH)) u_forward_dedup (
        .clk(clk),
        .rst(rst),
        .lookup(forward_dedup_lookup),
        .insert(forward_dedup_insert),
        .lkup_src(forward_dedup_src),
        .ins_src(forward_dedup_src),
        .lkup_cnt(forward_dedup_count),
        .ins_cnt(forward_dedup_count),
        .found(forward_dedup_found)
    );

    always @(posedge clk) begin
        if (rst) begin
            st <= S_IDLE;
            candidate_done <= 1'b0;
            candidate_duplicate <= 1'b0;
            forward_req <= 1'b0;
            forward_port_mask <= {NUM_PORTS{1'b0}};
            forward_src_id <= 8'd0;
            forward_dst_id <= 8'd0;
            forward_count <= 16'd0;
            forward_len16 <= 16'd0;
            payload_port <= {PORT_W{1'b0}};
            forward_dedup_lookup <= 1'b0;
            forward_dedup_insert <= 1'b0;
            forward_dedup_src <= 8'd0;
            forward_dedup_count <= 16'd0;
        end else begin
            candidate_done <= 1'b0;
            candidate_duplicate <= 1'b0;
            forward_dedup_lookup <= 1'b0;
            forward_dedup_insert <= 1'b0;

            case (st)
                S_IDLE: begin
                    forward_req <= 1'b0;
                    if (candidate_valid) begin
                        forward_src_id <= candidate_src_id;
                        forward_dst_id <= candidate_dst_id;
                        forward_count <= candidate_count;
                        forward_len16 <= candidate_len16;
                        payload_port <= candidate_rx_port;
                        forward_port_mask <= {NUM_PORTS{1'b1}};
                        forward_port_mask[candidate_rx_port] <= 1'b0;
                        forward_dedup_src <= candidate_src_id;
                        forward_dedup_count <= candidate_count;
                        forward_dedup_lookup <= 1'b1;
                        st <= S_LOOKUP;
                    end
                end

                S_LOOKUP: begin
                    st <= S_DECIDE;
                end

                S_DECIDE: begin
                    if (forward_dedup_found) begin
                        candidate_done <= 1'b1;
                        candidate_duplicate <= 1'b1;
                        st <= S_IDLE;
                    end else if (!candidate_should_forward) begin
                        candidate_done <= 1'b1;
                        st <= S_IDLE;
                    end else begin
                        forward_req <= 1'b1;
                        st <= S_REQ;
                    end
                end

                S_REQ: begin
                    if (forward_accept) begin
                        if (!forward_dropped)
                            forward_dedup_insert <= 1'b1;
                        forward_req <= 1'b0;
                        candidate_done <= 1'b1;
                        st <= S_IDLE;
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
