`timescale 1ns / 1ps

//------------------------------------------------------------------------------
// node_core: parameterized network-node core.
//------------------------------------------------------------------------------
module node_core #(
    parameter SYNC_WORD    = 32'hA31E57BD,
    parameter BROADCAST    = 8'hFF,
    parameter MAX_PAYLOAD  = 256,
    parameter LIVENESS_WIN = 5,
    parameter NODE_COUNT   = 255,
    parameter DEDUP_DEPTH  = 64,
    parameter FIFO_DEPTH   = 8192,
    parameter RX_REPORT_FIFO_DEPTH = 2048,
    parameter CLK_FREQ_HZ  = 160_000_000,
    parameter CONGEST_TIMEOUT_SEC = 5,
    parameter NUM_PORTS    = 2
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        node_id_valid,
    input  wire [7:0]  node_id,
    input  wire [NUM_PORTS-1:0] rx_clk,
    input  wire [NUM_PORTS-1:0] tx_clk,
    input  wire [NUM_PORTS*32-1:0] in_flat,
    input  wire [NUM_PORTS-1:0] valid_in,
    input  wire        app_frame_valid,
    output wire        app_frame_ready,
    output wire        app_frame_accepted,
    output wire        app_frame_done,
    input  wire [7:0]  app_dst_id,
    input  wire [15:0] app_len16,
    output wire [15:0] app_payload_addr,
    input  wire [31:0] app_payload_data,
    output wire        app_rx_frame_valid,
    input  wire        app_rx_frame_ready,
    output wire [7:0]  app_rx_src_id,
    output wire [7:0]  app_rx_dst_id,
    output wire [15:0] app_rx_count,
    output wire [15:0] app_rx_len16,
    output wire        app_rx_payload_valid,
    input  wire        app_rx_payload_ready,
    output wire [15:0] app_rx_payload_addr,
    output wire [31:0] app_rx_payload_data,
    output wire [NUM_PORTS*32-1:0] out_flat,
    output wire [NUM_PORTS-1:0] valid_out,
    output wire        liveness_valid,
    output wire [7:0]  liveness_node,
    output wire        liveness_alive,
    output wire        network_congested,
    output wire        app_len_error
);
    localparam PORT_W = (NUM_PORTS <= 1) ? 1 : $clog2(NUM_PORTS);
    localparam FIFO_COUNT_W = (FIFO_DEPTH <= 1) ? 1 : $clog2(FIFO_DEPTH);
    localparam RX_REPORT_FIFO_COUNT_W = 12;

    wire [7:0] my_id;
    wire       id_locked;
    node_id_latch u_id (
        .clk(clk),
        .rst(rst),
        .node_id_valid(node_id_valid),
        .node_id(node_id),
        .my_id(my_id),
        .id_locked(id_locked)
    );

    wire [NUM_PORTS-1:0] rx_empty;
    wire [NUM_PORTS-1:0] rx_full;
    wire [NUM_PORTS-1:0] rx_rd_en;
    wire [31:0]          rx_dout [0:NUM_PORTS-1];
    wire [NUM_PORTS*32-1:0] rx_dout_flat;

    wire [NUM_PORTS-1:0] tx_empty;
    wire [NUM_PORTS-1:0] tx_full;
    wire [NUM_PORTS*FIFO_COUNT_W-1:0] tx_wr_data_count_flat;
    wire [NUM_PORTS-1:0] tx_wr_en;
    wire [31:0]          tx_din  [0:NUM_PORTS-1];
    wire [31:0]          tx_dout [0:NUM_PORTS-1];
    wire [NUM_PORTS*32-1:0] tx_din_flat;
    wire [NUM_PORTS*32-1:0] tx_dout_flat;

    genvar bus_p;
    generate
        for (bus_p = 0; bus_p < NUM_PORTS; bus_p = bus_p + 1) begin : g_bus_pack
            assign rx_dout[bus_p] = rx_dout_flat[bus_p*32 +: 32];
            assign tx_din_flat[bus_p*32 +: 32] = tx_din[bus_p];
            assign tx_dout[bus_p] = tx_dout_flat[bus_p*32 +: 32];
        end
    endgenerate

    port_cdc #(
        .FIFO_DEPTH(FIFO_DEPTH),
        .NUM_PORTS(NUM_PORTS)
    ) u_cdc (
        .rst(rst),
        .id_locked(id_locked),
        .clk(clk),
        .rx_clk(rx_clk),
        .tx_clk(tx_clk),
        .in_flat(in_flat),
        .valid_in(valid_in),
        .rx_rd_en(rx_rd_en),
        .rx_dout_flat(rx_dout_flat),
        .rx_empty(rx_empty),
        .rx_full(rx_full),
        .tx_wr_en(tx_wr_en),
        .tx_din_flat(tx_din_flat),
        .tx_full(tx_full),
        .tx_wr_data_count_flat(tx_wr_data_count_flat),
        .tx_dout_flat(tx_dout_flat),
        .tx_empty(tx_empty),
        .out_flat(out_flat),
        .valid_out(valid_out)
    );

    wire [NUM_PORTS-1:0] frame_ready;
    wire [NUM_PORTS-1:0] frame_consumed;
    wire [7:0]           rx_src_id [0:NUM_PORTS-1];
    wire [7:0]           rx_dst_id [0:NUM_PORTS-1];
    wire [15:0]          rx_count  [0:NUM_PORTS-1];
    wire [15:0]          rx_len16  [0:NUM_PORTS-1];
    wire [15:0]          rx_payload_index [0:NUM_PORTS-1];
    wire [31:0]          rx_payload_data [0:NUM_PORTS-1];
    wire [NUM_PORTS-1:0] rx_is_broadcast;
    wire [NUM_PORTS*8-1:0]  rx_src_id_flat;
    wire [NUM_PORTS*8-1:0]  rx_dst_id_flat;
    wire [NUM_PORTS*16-1:0] rx_count_flat;
    wire [NUM_PORTS*16-1:0] rx_len16_flat;
    wire [NUM_PORTS*16-1:0] rx_dispatch_payload_index_flat;
    wire [NUM_PORTS*32-1:0] rx_payload_data_flat;
    wire                    tx_payload_is_forward;
    wire [PORT_W-1:0]       tx_forward_payload_port;
    wire [15:0]             tx_shared_payload_index;

    genvar p;
    generate
        for (p = 0; p < NUM_PORTS; p = p + 1) begin : g_rx
            frame_rx #(
                .SYNC_WORD(SYNC_WORD),
                .MAX_PAYLOAD(MAX_PAYLOAD),
                .CLK_FREQ_HZ(CLK_FREQ_HZ),
                .CONGEST_TIMEOUT_SEC(CONGEST_TIMEOUT_SEC)
            ) u_frame_rx (
                .clk(clk),
                .rst(rst || !id_locked),
                .rx_pause(network_congested),
                .fifo_dout(rx_dout[p]),
                .fifo_empty(rx_empty[p]),
                .fifo_rd_en(rx_rd_en[p]),
                .frame_ready(frame_ready[p]),
                .rx_src_id(rx_src_id[p]),
                .rx_dst_id(rx_dst_id[p]),
                .rx_count(rx_count[p]),
                .rx_len16(rx_len16[p]),
                .payload_index(rx_payload_index[p]),
                .rx_payload(rx_payload_data[p]),
                .rx_is_broadcast(rx_is_broadcast[p]),
                .frame_consumed(frame_consumed[p])
            );
            assign rx_src_id_flat[p*8 +: 8] = rx_src_id[p];
            assign rx_dst_id_flat[p*8 +: 8] = rx_dst_id[p];
            assign rx_count_flat[p*16 +: 16] = rx_count[p];
            assign rx_len16_flat[p*16 +: 16] = rx_len16[p];
            assign rx_payload_index[p] = (tx_payload_is_forward && (tx_forward_payload_port == p))
                                       ? tx_shared_payload_index
                                       : rx_dispatch_payload_index_flat[p*16 +: 16];
            assign rx_payload_data_flat[p*32 +: 32] = rx_payload_data[p];
        end
    endgenerate

    wire       forward_candidate_valid;
    wire       forward_candidate_ready;
    wire       forward_candidate_done;
    wire       forward_candidate_duplicate;
    wire       forward_candidate_should_forward;
    wire [PORT_W-1:0] forward_candidate_port;
    wire [7:0]        forward_candidate_src;
    wire [7:0]        forward_candidate_dst;
    wire [15:0]       forward_candidate_count;
    wire [15:0]       forward_candidate_len;

    wire       live_update;
    wire [7:0] live_update_src;
    wire       tick_1s;
    wire       rx_report_wr_en;
    wire [31:0] rx_report_din;
    wire       rx_report_full;
    wire [RX_REPORT_FIFO_COUNT_W-1:0] rx_report_data_count;

    rx_dispatcher #(
        .BROADCAST(BROADCAST),
        .NUM_PORTS(NUM_PORTS),
        .RX_REPORT_FIFO_DEPTH(RX_REPORT_FIFO_DEPTH),
        .RX_REPORT_FIFO_COUNT_W(RX_REPORT_FIFO_COUNT_W),
        .REPORT_DEDUP_DEPTH(DEDUP_DEPTH)
    ) u_rx_dispatcher (
        .clk(clk),
        .rst(rst || !id_locked),
        .my_id(my_id),
        .frame_ready(frame_ready),
        .frame_consumed(frame_consumed),
        .rx_src_id_flat(rx_src_id_flat),
        .rx_dst_id_flat(rx_dst_id_flat),
        .rx_count_flat(rx_count_flat),
        .rx_len16_flat(rx_len16_flat),
        .rx_payload_index_flat(rx_dispatch_payload_index_flat),
        .rx_payload_data_flat(rx_payload_data_flat),
        .rx_is_broadcast(rx_is_broadcast),
        .rx_report_wr_en(rx_report_wr_en),
        .rx_report_din(rx_report_din),
        .rx_report_full(rx_report_full),
        .rx_report_data_count(rx_report_data_count),
        .liveness_update(live_update),
        .liveness_update_src(live_update_src),
        .forward_valid(forward_candidate_valid),
        .forward_ready(forward_candidate_ready),
        .forward_done(forward_candidate_done),
        .forward_duplicate(forward_candidate_duplicate),
        .forward_should_forward(forward_candidate_should_forward),
        .forward_rx_port(forward_candidate_port),
        .forward_src_id(forward_candidate_src),
        .forward_dst_id(forward_candidate_dst),
        .forward_count(forward_candidate_count),
        .forward_len16(forward_candidate_len)
    );

    rx_report_fifo #(
        .DEPTH(RX_REPORT_FIFO_DEPTH),
        .COUNT_W(RX_REPORT_FIFO_COUNT_W)
    ) u_rx_report_fifo (
        .clk(clk),
        .rst(rst || !id_locked),
        .wr_en(rx_report_wr_en),
        .din(rx_report_din),
        .full(rx_report_full),
        .data_count(rx_report_data_count),
        .app_rx_frame_valid(app_rx_frame_valid),
        .app_rx_frame_ready(app_rx_frame_ready),
        .app_rx_src_id(app_rx_src_id),
        .app_rx_dst_id(app_rx_dst_id),
        .app_rx_count(app_rx_count),
        .app_rx_len16(app_rx_len16),
        .app_rx_payload_valid(app_rx_payload_valid),
        .app_rx_payload_ready(app_rx_payload_ready),
        .app_rx_payload_addr(app_rx_payload_addr),
        .app_rx_payload_data(app_rx_payload_data)
    );

    liveness_timer #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) u_liveness_timer (
        .clk(clk),
        .rst(rst || !id_locked),
        .tick_1s(tick_1s)
    );

    liveness_table #(
        .MAX_NODES(NODE_COUNT),
        .WINDOW(LIVENESS_WIN)
    ) u_liveness (
        .clk(clk),
        .rst(rst),
        .tick_1s(tick_1s),
        .update(live_update),
        .update_src(live_update_src),
        .upload_valid(liveness_valid),
        .upload_node(liveness_node),
        .upload_alive(liveness_alive)
    );

    wire       local_req;
    wire       local_accept;
    wire       local_is_app;
    wire       local_app_done;
    wire [7:0] local_dst_id;
    wire [15:0] local_count;
    wire [15:0] local_len16;

    local_packet_generator #(
        .BROADCAST(BROADCAST),
        .MAX_PAYLOAD(MAX_PAYLOAD)
    ) u_local_packet_generator (
        .clk(clk),
        .rst(rst || !id_locked),
        .tick_1s(tick_1s),
        .tx_congested(network_congested),
        .app_frame_valid(app_frame_valid),
        .app_frame_ready(app_frame_ready),
        .app_frame_accepted(app_frame_accepted),
        .app_frame_done(app_frame_done),
        .app_dst_id(app_dst_id),
        .app_len16(app_len16),
        .packet_req(local_req),
        .packet_accept(local_accept),
        .packet_app_done(local_app_done),
        .packet_is_app(local_is_app),
        .packet_dst_id(local_dst_id),
        .packet_count(local_count),
        .packet_len16(local_len16),
        .app_len_error(app_len_error)
    );

    wire       forward_req;
    wire       forward_accept;
    wire       forward_dropped;
    wire [NUM_PORTS-1:0] forward_port_mask;
    wire [7:0]  forward_src_id;
    wire [7:0]  forward_dst_id;
    wire [15:0] forward_count;
    wire [15:0] forward_len16;
    wire [PORT_W-1:0] forward_payload_port;

    forward_engine #(
        .DEDUP_DEPTH(DEDUP_DEPTH),
        .NUM_PORTS(NUM_PORTS)
    ) u_forward_engine (
        .clk(clk),
        .rst(rst || !id_locked),
        .candidate_valid(forward_candidate_valid),
        .candidate_ready(forward_candidate_ready),
        .candidate_done(forward_candidate_done),
        .candidate_rx_port(forward_candidate_port),
        .candidate_src_id(forward_candidate_src),
        .candidate_dst_id(forward_candidate_dst),
        .candidate_count(forward_candidate_count),
        .candidate_len16(forward_candidate_len),
        .candidate_should_forward(forward_candidate_should_forward),
        .forward_req(forward_req),
        .forward_accept(forward_accept),
        .forward_dropped(forward_dropped),
        .forward_port_mask(forward_port_mask),
        .forward_src_id(forward_src_id),
        .forward_dst_id(forward_dst_id),
        .forward_count(forward_count),
        .forward_len16(forward_len16),
        .payload_port(forward_payload_port),
        .candidate_duplicate(forward_candidate_duplicate)
    );

    wire [NUM_PORTS-1:0] tx_start;
    wire [NUM_PORTS-1:0] tx_busy;
    wire [NUM_PORTS-1:0] tx_done;
    wire [15:0]          tx_payload_index [0:NUM_PORTS-1];
    wire [NUM_PORTS*16-1:0] tx_payload_index_flat;
    wire [7:0]           tx_src_id;
    wire [7:0]           tx_dst_id;
    wire [15:0]          tx_count;
    wire [15:0]          tx_len16;
    wire [31:0]          tx_payload_data;

    tx_arbiter #(
        .NUM_PORTS(NUM_PORTS),
        .FIFO_DEPTH(FIFO_DEPTH),
        .FIFO_COUNT_W(FIFO_COUNT_W),
        .MAX_PAYLOAD(MAX_PAYLOAD),
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .CONGEST_TIMEOUT_SEC(CONGEST_TIMEOUT_SEC)
    ) u_tx_arbiter (
        .clk(clk),
        .rst(rst || !id_locked),
        .my_id(my_id),
        .local_req(local_req),
        .local_accept(local_accept),
        .local_is_app(local_is_app),
        .local_app_done(local_app_done),
        .local_dst_id(local_dst_id),
        .local_count(local_count),
        .local_len16(local_len16),
        .forward_req(forward_req),
        .forward_accept(forward_accept),
        .forward_dropped(forward_dropped),
        .forward_port_mask(forward_port_mask),
        .forward_src_id(forward_src_id),
        .forward_dst_id(forward_dst_id),
        .forward_count(forward_count),
        .forward_len16(forward_len16),
        .forward_payload_port(forward_payload_port),
        .tx_busy(tx_busy),
        .tx_done(tx_done),
        .tx_full(tx_full),
        .tx_wr_data_count_flat(tx_wr_data_count_flat),
        .tx_payload_index_flat(tx_payload_index_flat),
        .tx_start(tx_start),
        .tx_src_id(tx_src_id),
        .tx_dst_id(tx_dst_id),
        .tx_count(tx_count),
        .tx_len16(tx_len16),
        .tx_payload_is_forward(tx_payload_is_forward),
        .tx_forward_payload_port(tx_forward_payload_port),
        .shared_payload_index(tx_shared_payload_index),
        .network_congested(network_congested)
    );

    assign app_payload_addr = tx_payload_is_forward ? 16'd0 : tx_shared_payload_index;
    assign tx_payload_data = tx_payload_is_forward
                           ? rx_payload_data[tx_forward_payload_port]
                           : app_payload_data;

    genvar t;
    generate
        for (t = 0; t < NUM_PORTS; t = t + 1) begin : g_tx
            frame_tx #(
                .SYNC_WORD(SYNC_WORD)
            ) u_frame_tx (
                .clk(clk),
                .rst(rst || !id_locked),
                .start(tx_start[t]),
                .src_id(tx_src_id),
                .dst_id(tx_dst_id),
                .count(tx_count),
                .len16(tx_len16),
                .payload_index(tx_payload_index[t]),
                .payload_data(tx_payload_data),
                .tx_full(tx_full[t]),
                .tx_wr_en(tx_wr_en[t]),
                .tx_din(tx_din[t]),
                .busy(tx_busy[t]),
                .done(tx_done[t])
            );
            assign tx_payload_index_flat[t*16 +: 16] = tx_payload_index[t];
        end
    endgenerate
endmodule
