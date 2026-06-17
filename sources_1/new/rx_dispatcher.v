`timescale 1ns / 1ps

//------------------------------------------------------------------------------
// rx_dispatcher: classifies received frames and performs only local dispatch.
//------------------------------------------------------------------------------
module rx_dispatcher #(
    parameter BROADCAST = 8'hFF,
    parameter NUM_PORTS = 2,
    parameter PORT_W    = (NUM_PORTS <= 1) ? 1 : $clog2(NUM_PORTS),
    parameter SCAN_W    = $clog2(NUM_PORTS + 1),
    parameter RX_REPORT_FIFO_DEPTH = 2048,
    parameter RX_REPORT_FIFO_COUNT_W = 12,
    parameter REPORT_DEDUP_DEPTH = 64
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
    output wire [NUM_PORTS*16-1:0] rx_payload_index_flat,
    input  wire [NUM_PORTS*32-1:0] rx_payload_data_flat,
    input  wire [NUM_PORTS-1:0] rx_is_broadcast,
    output reg         rx_report_wr_en,
    output reg  [31:0] rx_report_din,
    input  wire        rx_report_full,
    input  wire [RX_REPORT_FIFO_COUNT_W-1:0] rx_report_data_count,
    output reg         liveness_update,
    output reg  [7:0]  liveness_update_src,
    output reg         forward_valid,
    input  wire        forward_ready,
    input  wire        forward_done,
    input  wire        forward_duplicate,
    output reg         forward_should_forward,
    output reg  [PORT_W-1:0] forward_rx_port,
    output reg  [7:0]  forward_src_id,
    output reg  [7:0]  forward_dst_id,
    output reg  [15:0] forward_count,
    output reg  [15:0] forward_len16
);
    localparam [3:0] S_POLL          = 4'd0;
    localparam [3:0] S_CLASSIFY      = 4'd1;
    localparam [3:0] S_REPORT_LOOKUP = 4'd2;
    localparam [3:0] S_REPORT_DECIDE = 4'd3;
    localparam [3:0] S_FWD_REQ       = 4'd4;
    localparam [3:0] S_FWD_WAIT      = 4'd5;
    localparam [3:0] S_LOCAL_ROOM    = 4'd6;
    localparam [3:0] S_LOCAL_HDR0    = 4'd7;
    localparam [3:0] S_LOCAL_HDR1    = 4'd8;
    localparam [3:0] S_LOCAL_PAY     = 4'd9;

    reg [3:0] st;
    reg [PORT_W-1:0] scan_port;
    reg [PORT_W-1:0] poll_base;
    reg [SCAN_W-1:0] scan_count;
    reg [PORT_W-1:0] active_port;
    reg [15:0] payload_index;
    reg        local_should_deliver;
    reg        report_duplicate;
    reg        report_dedup_lookup;
    reg        report_dedup_insert;
    reg [7:0]  report_dedup_src;
    reg [15:0] report_dedup_count;
    wire       report_dedup_found;
    reg [15:0] rx_payload_index_r [0:NUM_PORTS-1];
    integer i;

    wire [7:0]  active_src_id = rx_src_id_flat[active_port*8 +: 8];
    wire [7:0]  active_dst_id = rx_dst_id_flat[active_port*8 +: 8];
    wire [15:0] active_count  = rx_count_flat[active_port*16 +: 16];
    wire [15:0] active_len16  = rx_len16_flat[active_port*16 +: 16];
    wire [31:0] active_payload_data = rx_payload_data_flat[active_port*32 +: 32];
    wire        active_local_should_deliver = (active_dst_id == my_id) ||
                                              (rx_is_broadcast[active_port] && active_len16 != 0);
    wire        active_should_forward = (active_dst_id != my_id) || rx_is_broadcast[active_port];
    wire [31:0] report_frame_words = 32'd2 + active_len16;
    wire [31:0] report_used_words = rx_report_data_count;
    wire        report_has_room = !rx_report_full &&
                                  ((report_used_words + report_frame_words) <= RX_REPORT_FIFO_DEPTH);

    genvar rp;
    generate
        for (rp = 0; rp < NUM_PORTS; rp = rp + 1) begin : g_addr_flat
            assign rx_payload_index_flat[rp*16 +: 16] = rx_payload_index_r[rp];
        end
    endgenerate

    dedup_table #(.DEPTH(REPORT_DEDUP_DEPTH)) u_report_dedup (
        .clk(clk),
        .rst(rst),
        .lookup(report_dedup_lookup),
        .insert(report_dedup_insert),
        .lkup_src(report_dedup_src),
        .ins_src(report_dedup_src),
        .lkup_cnt(report_dedup_count),
        .ins_cnt(report_dedup_count),
        .found(report_dedup_found)
    );

    always @(posedge clk) begin
        if (rst) begin
            st <= S_POLL;
            scan_port <= {PORT_W{1'b0}};
            poll_base <= {PORT_W{1'b0}};
            scan_count <= {SCAN_W{1'b0}};
            active_port <= {PORT_W{1'b0}};
            payload_index <= 16'd0;
            local_should_deliver <= 1'b0;
            report_duplicate <= 1'b0;
            report_dedup_lookup <= 1'b0;
            report_dedup_insert <= 1'b0;
            report_dedup_src <= 8'd0;
            report_dedup_count <= 16'd0;
            frame_consumed <= {NUM_PORTS{1'b0}};
            rx_report_wr_en <= 1'b0;
            rx_report_din <= 32'd0;
            liveness_update <= 1'b0;
            liveness_update_src <= 8'd0;
            forward_valid <= 1'b0;
            forward_should_forward <= 1'b0;
            forward_rx_port <= {PORT_W{1'b0}};
            forward_src_id <= 8'd0;
            forward_dst_id <= 8'd0;
            forward_count <= 16'd0;
            forward_len16 <= 16'd0;
            for (i = 0; i < NUM_PORTS; i = i + 1)
                rx_payload_index_r[i] <= 16'd0;
        end else begin
            frame_consumed <= {NUM_PORTS{1'b0}};
            liveness_update <= 1'b0;
            rx_report_wr_en <= 1'b0;
            report_dedup_lookup <= 1'b0;
            report_dedup_insert <= 1'b0;

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

                        local_should_deliver <= active_local_should_deliver;
                        report_duplicate <= 1'b0;
                        forward_rx_port <= active_port;
                        forward_src_id <= active_src_id;
                        forward_dst_id <= active_dst_id;
                        forward_count <= active_count;
                        forward_len16 <= active_len16;
                        forward_should_forward <= active_should_forward;
                        if (active_local_should_deliver) begin
                            report_dedup_src <= active_src_id;
                            report_dedup_count <= active_count;
                            report_dedup_lookup <= 1'b1;
                            st <= S_REPORT_LOOKUP;
                        end else begin
                            forward_valid <= 1'b1;
                            st <= S_FWD_REQ;
                        end
                    end
                end

                S_REPORT_LOOKUP: begin
                    st <= S_REPORT_DECIDE;
                end

                S_REPORT_DECIDE: begin
                    report_duplicate <= report_dedup_found;
                    forward_valid <= 1'b1;
                    st <= S_FWD_REQ;
                end

                S_LOCAL_ROOM: begin
                    if (report_has_room) begin
                        payload_index <= 16'd0;
                        rx_payload_index_r[active_port] <= 16'd0;
                        st <= S_LOCAL_HDR0;
                    end
                end

                S_LOCAL_HDR0: begin
                    if (!rx_report_full) begin
                        rx_report_wr_en <= 1'b1;
                        rx_report_din <= {active_src_id, active_dst_id, active_count};
                        st <= S_LOCAL_HDR1;
                    end
                end

                S_LOCAL_HDR1: begin
                    if (!rx_report_full) begin
                        rx_report_wr_en <= 1'b1;
                        rx_report_din <= {active_len16, 16'd0};
                        if (active_len16 == 0) begin
                            report_dedup_insert <= 1'b1;
                            frame_consumed[active_port] <= 1'b1;
                            st <= S_POLL;
                        end else begin
                            payload_index <= 16'd0;
                            rx_payload_index_r[active_port] <= 16'd0;
                            st <= S_LOCAL_PAY;
                        end
                    end
                end

                S_LOCAL_PAY: begin
                    if (!rx_report_full) begin
                        rx_report_wr_en <= 1'b1;
                        rx_report_din <= active_payload_data;
                        if (payload_index == active_len16 - 1) begin
                            report_dedup_insert <= 1'b1;
                            frame_consumed[active_port] <= 1'b1;
                            st <= S_POLL;
                        end else begin
                            payload_index <= payload_index + 1'b1;
                            rx_payload_index_r[active_port] <= payload_index + 1'b1;
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
                        if (!local_should_deliver || report_duplicate) begin
                            frame_consumed[active_port] <= 1'b1;
                            st <= S_POLL;
                        end else begin
                            st <= S_LOCAL_ROOM;
                        end
                    end
                end

                default: st <= S_POLL;
            endcase
        end
    end
endmodule
