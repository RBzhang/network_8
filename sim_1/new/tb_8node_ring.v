`timescale 1ns / 1ps

//------------------------------------------------------------------------------
// tb_8node_ring: 8-node bidirectional ring network testbench
//   Instantiates 8 node_top modules connected in a ring topology.
//   Tests unicast, broadcast, continuous small packets, and max payload.
//------------------------------------------------------------------------------
module tb_8node_ring;

    localparam ENABLE_VERBOSE_DEBUG = 0;
    localparam ENABLE_TEST1_DEBUG   = 0;
    localparam ENABLE_TEST2_DEBUG   = 0;
    localparam ENABLE_SUMMARY_ONLY  = 1;

    localparam NUM_NODES   = 8;
    localparam CLK_PERIOD  = 10;          // 10 ns = 100 MHz
    localparam SIM_CLK_FREQ = 500000000; // tick_1s every 5e8 cycles (~5s), slow enough to not interfere
    localparam TIMEOUT_CYCLES = 500000;   // max wait cycles per test
    localparam BROADCAST   = 8'hFF;
    localparam MAX_PAYLOAD = 256;

    //--------------------------------------------------------------------------
    // Clock and reset
    //--------------------------------------------------------------------------
    reg clk;
    reg rst;

    always #(CLK_PERIOD/2) clk = ~clk;

    initial begin
        #100_000_000;  // 100 ms at 1 ns timescale.
        $display("GLOBAL TIMEOUT: simulation did not finish in 100 ms");
        $fatal(1);
    end
    //--------------------------------------------------------------------------
    // Per-node signals
    //--------------------------------------------------------------------------
    reg  [NUM_NODES-1:0] node_id_valid;
    reg  [7:0] node_id [0:NUM_NODES-1];

    wire [31:0]  out0 [0:NUM_NODES-1];
    wire [31:0]  out1 [0:NUM_NODES-1];
    wire         valid_out0 [0:NUM_NODES-1];
    wire         valid_out1 [0:NUM_NODES-1];

    // Pipeline delayed link signals (1 cycle delay)
    reg  [31:0]  link_data_cw  [0:NUM_NODES-1];  // clockwise data
    reg          link_valid_cw [0:NUM_NODES-1];
    reg  [31:0]  link_data_ccw [0:NUM_NODES-1];  // counter-clockwise data
    reg          link_valid_ccw [0:NUM_NODES-1];

    wire [31:0]  in0 [0:NUM_NODES-1];
    wire [31:0]  in1 [0:NUM_NODES-1];
    wire         valid_in0 [0:NUM_NODES-1];
    wire         valid_in1 [0:NUM_NODES-1];

    // App TX interface
    reg          app_frame_valid [0:NUM_NODES-1];
    wire         app_frame_ready [0:NUM_NODES-1];
    wire         app_frame_accepted [0:NUM_NODES-1];
    wire         app_frame_done [0:NUM_NODES-1];
    reg  [7:0]   app_dst_id [0:NUM_NODES-1];
    reg  [15:0]  app_len16 [0:NUM_NODES-1];
    wire [15:0]  app_payload_addr [0:NUM_NODES-1];
    wire [31:0]  app_payload_data [0:NUM_NODES-1];

    // App RX interface
    wire         app_rx_frame_valid [0:NUM_NODES-1];
    reg          app_rx_frame_ready [0:NUM_NODES-1];
    wire [7:0]   app_rx_src_id [0:NUM_NODES-1];
    wire [7:0]   app_rx_dst_id [0:NUM_NODES-1];
    wire [15:0]  app_rx_count [0:NUM_NODES-1];
    wire [15:0]  app_rx_len16 [0:NUM_NODES-1];
    wire         app_rx_payload_valid [0:NUM_NODES-1];
    reg          app_rx_payload_ready [0:NUM_NODES-1];
    wire [15:0]  app_rx_payload_addr [0:NUM_NODES-1];
    wire [31:0]  app_rx_payload_data [0:NUM_NODES-1];

    // Misc outputs
    wire         liveness_valid [0:NUM_NODES-1];
    wire [7:0]   liveness_node [0:NUM_NODES-1];
    wire         liveness_alive [0:NUM_NODES-1];
    wire         network_congested [0:NUM_NODES-1];
    wire         app_len_error [0:NUM_NODES-1];
    wire         rx_overflow [0:NUM_NODES-1];

    // rx_clk / tx_clk all tied to main clk for simplified simulation
    wire clk_w = clk;

    //--------------------------------------------------------------------------
    // Payload RAM model (combinational read: data valid same cycle as addr)
    //--------------------------------------------------------------------------
    reg [31:0] payload_mem [0:NUM_NODES-1][0:MAX_PAYLOAD-1];
    reg [31:0] app_payload_data_r [0:NUM_NODES-1];

    genvar gi;
    generate
        for (gi = 0; gi < NUM_NODES; gi = gi + 1) begin : g_payload
            always @(*) begin
                app_payload_data_r[gi] = payload_mem[gi][app_payload_addr[gi]];
            end
            assign app_payload_data[gi] = app_payload_data_r[gi];
        end
    endgenerate

    genvar gnode;
    generate
        for (gnode = 0; gnode < NUM_NODES; gnode = gnode + 1) begin : g_node
            node_top #(
                .SYNC_WORD(32'hA31E57BD),
                .BROADCAST(BROADCAST),
                .MAX_PAYLOAD(MAX_PAYLOAD),
                .LIVENESS_WIN(5),
                .NODE_COUNT(255),
                .DEDUP_DEPTH(64),
                .FIFO_DEPTH(8192),
                .RX_REPORT_FIFO_DEPTH(2048),
                .CLK_FREQ_HZ(SIM_CLK_FREQ),
                .CONGEST_TIMEOUT_SEC(5)
            ) u_node (
                .clk(clk),
                .rst(rst),
                .node_id_valid(node_id_valid[gnode]),
                .node_id(node_id[gnode]),
                .rx_clk0(clk_w),
                .rx_clk1(clk_w),
                .tx_clk0(clk_w),
                .tx_clk1(clk_w),
                .in0(in0[gnode]),
                .in1(in1[gnode]),
                .valid_in0(valid_in0[gnode]),
                .valid_in1(valid_in1[gnode]),
                .app_frame_valid(app_frame_valid[gnode]),
                .app_frame_ready(app_frame_ready[gnode]),
                .app_frame_accepted(app_frame_accepted[gnode]),
                .app_frame_done(app_frame_done[gnode]),
                .app_dst_id(app_dst_id[gnode]),
                .app_len16(app_len16[gnode]),
                .app_payload_addr(app_payload_addr[gnode]),
                .app_payload_data(app_payload_data[gnode]),
                .app_rx_frame_valid(app_rx_frame_valid[gnode]),
                .app_rx_frame_ready(app_rx_frame_ready[gnode]),
                .app_rx_src_id(app_rx_src_id[gnode]),
                .app_rx_dst_id(app_rx_dst_id[gnode]),
                .app_rx_count(app_rx_count[gnode]),
                .app_rx_len16(app_rx_len16[gnode]),
                .app_rx_payload_valid(app_rx_payload_valid[gnode]),
                .app_rx_payload_ready(app_rx_payload_ready[gnode]),
                .app_rx_payload_addr(app_rx_payload_addr[gnode]),
                .app_rx_payload_data(app_rx_payload_data[gnode]),
                .out0(out0[gnode]),
                .out1(out1[gnode]),
                .valid_out0(valid_out0[gnode]),
                .valid_out1(valid_out1[gnode]),
                .liveness_valid(liveness_valid[gnode]),
                .liveness_node(liveness_node[gnode]),
                .liveness_alive(liveness_alive[gnode]),
                .network_congested(network_congested[gnode]),
                .app_len_error(app_len_error[gnode]),
                .rx_overflow(rx_overflow[gnode])
            );
        end
    endgenerate

    //--------------------------------------------------------------------------
    // Ring connections with 1-cycle pipeline delay
    //   node[i].out0 -> pipeline -> node[(i+1)%8].in1  (clockwise)
    //   node[i].out1 -> pipeline -> node[(i+7)%8].in0  (counter-clockwise)
    //--------------------------------------------------------------------------
    genvar gi2;
    generate
        for (gi2 = 0; gi2 < NUM_NODES; gi2 = gi2 + 1) begin : g_link
            // Clockwise: out0[i] -> in1[i+1]
            assign in1[gi2] = link_data_cw[(gi2 + NUM_NODES - 1) % NUM_NODES];
            assign valid_in1[gi2] = link_valid_cw[(gi2 + NUM_NODES - 1) % NUM_NODES];

            // Counter-clockwise: out1[i] -> in0[i-1]
            assign in0[gi2] = link_data_ccw[(gi2 + 1) % NUM_NODES];
            assign valid_in0[gi2] = link_valid_ccw[(gi2 + 1) % NUM_NODES];
        end
    endgenerate

    always @(posedge clk) begin
        if (rst) begin
            for (integer i_pipe = 0; i_pipe < NUM_NODES; i_pipe = i_pipe + 1) begin
                link_data_cw[i_pipe]  <= 32'd0;
                link_valid_cw[i_pipe] <= 1'b0;
                link_data_ccw[i_pipe] <= 32'd0;
                link_valid_ccw[i_pipe] <= 1'b0;
            end
        end else begin
            for (integer i_pipe = 0; i_pipe < NUM_NODES; i_pipe = i_pipe + 1) begin
                link_data_cw[i_pipe]  <= out0[i_pipe];
                link_valid_cw[i_pipe] <= valid_out0[i_pipe];
                link_data_ccw[i_pipe] <= out1[i_pipe];
                link_valid_ccw[i_pipe] <= valid_out1[i_pipe];
            end
        end
    end

    //--------------------------------------------------------------------------
    // Received frame tracking
    //--------------------------------------------------------------------------
    reg [31:0] rx_payload_mem [0:NUM_NODES-1][0:MAX_PAYLOAD-1];
    reg [15:0] ri [0:NUM_NODES-1];
    integer    received_frame_count [0:NUM_NODES-1];
    reg [7:0]  last_rx_src [0:NUM_NODES-1];
    reg [7:0]  last_rx_dst [0:NUM_NODES-1];
    reg [15:0] last_rx_len [0:NUM_NODES-1];
    reg [15:0] last_rx_count [0:NUM_NODES-1];

    // Test 1 layered debug flags
    reg test1_debug_active;
    reg seen_node1_in1_sync;
    reg seen_node7_in0_sync;
    reg seen_node1_frame_ready;
    reg seen_node7_frame_ready;
    reg seen_node1_forward_req;
    reg seen_node7_forward_req;
    reg seen_node1_valid_out;
    reg seen_node7_valid_out;
    reg node4_frame_ready;
    reg node4_app_rx_frame_valid;
    integer node1_link_seq_idx;
    integer node7_link_seq_idx;
    integer node1_rx_seq_idx;
    integer node7_rx_seq_idx;
    integer node1_link_sync_count;
    integer node7_link_sync_count;
    integer node1_rx_sync_count;
    integer node7_rx_sync_count;
    integer node0_enq_port0_seq_idx;
    integer node0_enq_port1_seq_idx;
    integer node0_q_port0_seq_idx;
    integer node0_q_port1_seq_idx;
    integer node0_txwr_port0_seq_idx;
    integer node0_txwr_port1_seq_idx;
    integer node0_txfifo_port0_seq_idx;
    integer node0_txfifo_port1_seq_idx;
    integer node0_out_port0_seq_idx;
    integer node0_out_port1_seq_idx;
    reg [31:0] node1_link_first_words [0:7];
    reg [31:0] node7_link_first_words [0:7];
    reg [31:0] node1_rx_first_words [0:7];
    reg [31:0] node7_rx_first_words [0:7];
    reg [31:0] node0_enq_port0_first_words [0:7];
    reg [31:0] node0_enq_port1_first_words [0:7];
    reg [31:0] node0_q_port0_first_words [0:7];
    reg [31:0] node0_q_port1_first_words [0:7];
    reg [31:0] node0_txwr_port0_first_words [0:7];
    reg [31:0] node0_txwr_port1_first_words [0:7];
    reg [31:0] node0_txfifo_port0_first_words [0:7];
    reg [31:0] node0_txfifo_port1_first_words [0:7];
    reg [31:0] node0_out_port0_first_words [0:7];
    reg [31:0] node0_out_port1_first_words [0:7];

    // Test 1 SRC0CHK source-side latches (Node0): captured during Test1 to
    // diagnose which TX layer the source frame stalls in.  These are only
    // ever SET during test1_debug_active (and cleared on reset / Test1 entry).
    reg        src0_id_locked;            // Node0 id_locked ever high during Test1
    reg        src0_app_frame_ready;      // app_frame_ready[0] ever high
    reg        src0_app_frame_accepted;   // app_frame_accepted[0] ever high
    reg        src0_app_frame_done;       // app_frame_done[0] ever high
    reg        src0_network_congested;    // network_congested[0] ever high
    reg        src0_app_len_error;        // app_len_error[0] ever high
    reg        src0_local_req;            // local_packet_generator.packet_req
    reg        src0_local_accept;         // local_packet_generator.packet_accept
    reg        src0_local_app_done;       // local_packet_generator.packet_app_done
    reg        src0_q_wr;                 // tx_frame_queue_wr_en != 0
    reg        src0_txwr;                 // tx_wr_en != 0
    reg        src0_valid_out;            // valid_out0[0] || valid_out1[0]
    reg [2:0]  src0_enq_st_last;          // last seen tx_enqueue_engine.st
    reg [33:0] src0_q_din0_last;          // last tx_frame_queue_din_flat port0 word
    reg [33:0] src0_q_din1_last;          // last tx_frame_queue_din_flat port1 word
    reg [31:0] src0_tx_din0_last;         // last tx_din_flat port0 word
    reg [31:0] src0_tx_din1_last;         // last tx_din_flat port1 word
    reg [31:0] src0_out0_last;            // last out0[0] when valid
    reg [31:0] src0_out1_last;            // last out1[0] when valid

    // Test 2 focused debug and automatic diagnosis state.
    reg test2_debug_active;
    integer test2_debug_cycles;
    integer test2_forward_req_5_0_count [0:NUM_NODES-1];
    integer test2_forward_req_5_0_dup0_count [0:NUM_NODES-1];
    reg test2_dedup_issue;
    reg test2_consumed_before_payload_done;
    reg test2_payload_read_zero;
    reg test2_queue_write_zero;
    reg test2_queue_payload_ok;
    reg test2_len_mismatch_after_good_forward;
    reg [15:0] test2_max_payload_idx [0:NUM_NODES-1];
    reg [31:0] test2_payload_seen [0:NUM_NODES-1][0:2];
    reg [31:0] test2_queue_seen [0:NUM_NODES-1][0:2];

    genvar gn;
    generate
        for (gn = 0; gn < NUM_NODES; gn = gn + 1) begin : g_rx_mon
            always @(posedge clk) begin
                if (rst) begin
                    ri[gn] <= 16'd0;
                    received_frame_count[gn] <= 0;
                    last_rx_src[gn] <= 8'd0;
                    last_rx_dst[gn] <= 8'd0;
                    last_rx_len[gn] <= 16'd0;
                    last_rx_count[gn] <= 16'd0;
                end else begin
                    if (app_rx_frame_valid[gn] && app_rx_frame_ready[gn]) begin
                        received_frame_count[gn] <= received_frame_count[gn] + 1;
                        last_rx_src[gn] <= app_rx_src_id[gn];
                        last_rx_dst[gn] <= app_rx_dst_id[gn];
                        last_rx_len[gn] <= app_rx_len16[gn];
                        last_rx_count[gn] <= app_rx_count[gn];
                        ri[gn] <= 16'd0;
                    end
                    if (app_rx_payload_valid[gn] && app_rx_payload_ready[gn]) begin
                        rx_payload_mem[gn][app_rx_payload_addr[gn]] <= app_rx_payload_data[gn];
                        ri[gn] <= app_rx_payload_addr[gn] + 1'b1;
                    end
                end
            end
        end
    endgenerate

    // Monitor: print when any valid_out goes high
    always @(posedge clk) begin
        for (integer mi = 0; mi < NUM_NODES; mi = mi + 1) begin
            if (ENABLE_VERBOSE_DEBUG && ENABLE_TEST1_DEBUG && test1_debug_active && (valid_out0[mi] || valid_out1[mi]))
                $display("  MONITOR time=%0t: node%0d vout0=%0d vout1=%0d",
                         $time, mi, valid_out0[mi], valid_out1[mi]);
        end
    end

    // Node0 TX-side sequence debug for Test 1.
    //   IMPORTANT: collection of first_words / seq_idx is gated ONLY by
    //   test1_debug_active so the diagnostic summary stays meaningful even when
    //   ENABLE_VERBOSE_DEBUG=0 / ENABLE_TEST1_DEBUG=0.  Only the per-beat
    //   $display traces are gated by ENABLE_VERBOSE_DEBUG && ENABLE_TEST1_DEBUG.
    always @(posedge clk) begin
        if (rst) begin
            node0_enq_port0_seq_idx <= 0;
            node0_enq_port1_seq_idx <= 0;
            node0_q_port0_seq_idx <= 0;
            node0_q_port1_seq_idx <= 0;
            node0_txwr_port0_seq_idx <= 0;
            node0_txwr_port1_seq_idx <= 0;
            node0_txfifo_port0_seq_idx <= 0;
            node0_txfifo_port1_seq_idx <= 0;
            node0_out_port0_seq_idx <= 0;
            node0_out_port1_seq_idx <= 0;
            for (integer tx_rst_i = 0; tx_rst_i < 8; tx_rst_i = tx_rst_i + 1) begin
                node0_enq_port0_first_words[tx_rst_i] <= 32'd0;
                node0_enq_port1_first_words[tx_rst_i] <= 32'd0;
                node0_q_port0_first_words[tx_rst_i] <= 32'd0;
                node0_q_port1_first_words[tx_rst_i] <= 32'd0;
                node0_txwr_port0_first_words[tx_rst_i] <= 32'd0;
                node0_txwr_port1_first_words[tx_rst_i] <= 32'd0;
                node0_txfifo_port0_first_words[tx_rst_i] <= 32'd0;
                node0_txfifo_port1_first_words[tx_rst_i] <= 32'd0;
                node0_out_port0_first_words[tx_rst_i] <= 32'd0;
                node0_out_port1_first_words[tx_rst_i] <= 32'd0;
            end
        end else if (test1_debug_active) begin
            // ---- Always collect first_words / counters (no verbose gate) ----
            if (g_node[0].u_node.u_node_core.tx_frame_queue_wr_en[0]) begin
                if (node0_enq_port0_seq_idx < 8)
                    node0_enq_port0_first_words[node0_enq_port0_seq_idx] <=
                        g_node[0].u_node.u_node_core.tx_frame_queue_din_flat[0*34 +: 32];
                node0_enq_port0_seq_idx <= node0_enq_port0_seq_idx + 1;
            end
            if (g_node[0].u_node.u_node_core.tx_frame_queue_wr_en[1]) begin
                if (node0_enq_port1_seq_idx < 8)
                    node0_enq_port1_first_words[node0_enq_port1_seq_idx] <=
                        g_node[0].u_node.u_node_core.tx_frame_queue_din_flat[1*34 +: 32];
                node0_enq_port1_seq_idx <= node0_enq_port1_seq_idx + 1;
            end
            if (g_node[0].u_node.u_node_core.tx_frame_queue_rd_en[0]) begin
                if (node0_q_port0_seq_idx < 8)
                    node0_q_port0_first_words[node0_q_port0_seq_idx] <=
                        g_node[0].u_node.u_node_core.tx_frame_queue_dout_flat[0*34 +: 32];
                node0_q_port0_seq_idx <= node0_q_port0_seq_idx + 1;
            end
            if (g_node[0].u_node.u_node_core.tx_frame_queue_rd_en[1]) begin
                if (node0_q_port1_seq_idx < 8)
                    node0_q_port1_first_words[node0_q_port1_seq_idx] <=
                        g_node[0].u_node.u_node_core.tx_frame_queue_dout_flat[1*34 +: 32];
                node0_q_port1_seq_idx <= node0_q_port1_seq_idx + 1;
            end
            if (g_node[0].u_node.u_node_core.tx_wr_en[0]) begin
                if (node0_txwr_port0_seq_idx < 8)
                    node0_txwr_port0_first_words[node0_txwr_port0_seq_idx] <=
                        g_node[0].u_node.u_node_core.tx_din_flat[0*32 +: 32];
                node0_txwr_port0_seq_idx <= node0_txwr_port0_seq_idx + 1;
            end
            if (g_node[0].u_node.u_node_core.tx_wr_en[1]) begin
                if (node0_txwr_port1_seq_idx < 8)
                    node0_txwr_port1_first_words[node0_txwr_port1_seq_idx] <=
                        g_node[0].u_node.u_node_core.tx_din_flat[1*32 +: 32];
                node0_txwr_port1_seq_idx <= node0_txwr_port1_seq_idx + 1;
            end
            if (!g_node[0].u_node.u_node_core.tx_empty[0]) begin
                if (node0_txfifo_port0_seq_idx < 8)
                    node0_txfifo_port0_first_words[node0_txfifo_port0_seq_idx] <=
                        g_node[0].u_node.u_node_core.tx_dout_flat[0*32 +: 32];
                node0_txfifo_port0_seq_idx <= node0_txfifo_port0_seq_idx + 1;
            end
            if (!g_node[0].u_node.u_node_core.tx_empty[1]) begin
                if (node0_txfifo_port1_seq_idx < 8)
                    node0_txfifo_port1_first_words[node0_txfifo_port1_seq_idx] <=
                        g_node[0].u_node.u_node_core.tx_dout_flat[1*32 +: 32];
                node0_txfifo_port1_seq_idx <= node0_txfifo_port1_seq_idx + 1;
            end
            if (valid_out0[0]) begin
                if (node0_out_port0_seq_idx < 8)
                    node0_out_port0_first_words[node0_out_port0_seq_idx] <= out0[0];
                node0_out_port0_seq_idx <= node0_out_port0_seq_idx + 1;
            end
            if (valid_out1[0]) begin
                if (node0_out_port1_seq_idx < 8)
                    node0_out_port1_first_words[node0_out_port1_seq_idx] <= out1[0];
                node0_out_port1_seq_idx <= node0_out_port1_seq_idx + 1;
            end
        end
        // ---- Per-beat $display traces only when verbose enabled ----
        if (!rst && ENABLE_VERBOSE_DEBUG && ENABLE_TEST1_DEBUG && test1_debug_active) begin
            if (g_node[0].u_node.u_node_core.tx_frame_queue_wr_en[0])
                $display("ENQSEQ node=0 port=0 idx=%0d sof=%0d eof=%0d data=%08h",
                         node0_enq_port0_seq_idx,
                         g_node[0].u_node.u_node_core.tx_frame_queue_din_flat[0*34 + 33],
                         g_node[0].u_node.u_node_core.tx_frame_queue_din_flat[0*34 + 32],
                         g_node[0].u_node.u_node_core.tx_frame_queue_din_flat[0*34 +: 32]);
            if (g_node[0].u_node.u_node_core.tx_frame_queue_wr_en[1])
                $display("ENQSEQ node=0 port=1 idx=%0d sof=%0d eof=%0d data=%08h",
                         node0_enq_port1_seq_idx,
                         g_node[0].u_node.u_node_core.tx_frame_queue_din_flat[1*34 + 33],
                         g_node[0].u_node.u_node_core.tx_frame_queue_din_flat[1*34 + 32],
                         g_node[0].u_node.u_node_core.tx_frame_queue_din_flat[1*34 +: 32]);
            if (g_node[0].u_node.u_node_core.tx_frame_queue_rd_en[0])
                $display("QSEQ node=0 port=0 idx=%0d sof=%0d eof=%0d data=%08h",
                         node0_q_port0_seq_idx,
                         g_node[0].u_node.u_node_core.tx_frame_queue_dout_flat[0*34 + 33],
                         g_node[0].u_node.u_node_core.tx_frame_queue_dout_flat[0*34 + 32],
                         g_node[0].u_node.u_node_core.tx_frame_queue_dout_flat[0*34 +: 32]);
            if (g_node[0].u_node.u_node_core.tx_frame_queue_rd_en[1])
                $display("QSEQ node=0 port=1 idx=%0d sof=%0d eof=%0d data=%08h",
                         node0_q_port1_seq_idx,
                         g_node[0].u_node.u_node_core.tx_frame_queue_dout_flat[1*34 + 33],
                         g_node[0].u_node.u_node_core.tx_frame_queue_dout_flat[1*34 + 32],
                         g_node[0].u_node.u_node_core.tx_frame_queue_dout_flat[1*34 +: 32]);
            if (g_node[0].u_node.u_node_core.tx_wr_en[0])
                $display("TXWRSEQ node=0 port=0 idx=%0d data=%08h",
                         node0_txwr_port0_seq_idx,
                         g_node[0].u_node.u_node_core.tx_din_flat[0*32 +: 32]);
            if (g_node[0].u_node.u_node_core.tx_wr_en[1])
                $display("TXWRSEQ node=0 port=1 idx=%0d data=%08h",
                         node0_txwr_port1_seq_idx,
                         g_node[0].u_node.u_node_core.tx_din_flat[1*32 +: 32]);
            if (!g_node[0].u_node.u_node_core.tx_empty[0])
                $display("TXFIFOSEQ node=0 port=0 idx=%0d data=%08h",
                         node0_txfifo_port0_seq_idx,
                         g_node[0].u_node.u_node_core.tx_dout_flat[0*32 +: 32]);
            if (!g_node[0].u_node.u_node_core.tx_empty[1])
                $display("TXFIFOSEQ node=0 port=1 idx=%0d data=%08h",
                         node0_txfifo_port1_seq_idx,
                         g_node[0].u_node.u_node_core.tx_dout_flat[1*32 +: 32]);
            if (valid_out0[0])
                $display("OUTSEQ node=0 port=0 idx=%0d data=%08h",
                         node0_out_port0_seq_idx, out0[0]);
            if (valid_out1[0])
                $display("OUTSEQ node=0 port=1 idx=%0d data=%08h",
                         node0_out_port1_seq_idx, out1[0]);
        end
    end

    // First-hop link debug for Test 1:
    // Node0.out0 -> Node1.in1, Node0.out1 -> Node7.in0.
    //   first_words / sync_count / seen flags are gated ONLY by test1_debug_active;
    //   $display traces are gated by ENABLE_VERBOSE_DEBUG && ENABLE_TEST1_DEBUG.
    always @(posedge clk) begin
        if (rst) begin
            seen_node1_in1_sync <= 1'b0;
            seen_node7_in0_sync <= 1'b0;
            node1_link_seq_idx <= 0;
            node7_link_seq_idx <= 0;
            node1_link_sync_count <= 0;
            node7_link_sync_count <= 0;
            for (integer link_rst_i = 0; link_rst_i < 8; link_rst_i = link_rst_i + 1) begin
                node1_link_first_words[link_rst_i] <= 32'd0;
                node7_link_first_words[link_rst_i] <= 32'd0;
            end
        end else if (test1_debug_active) begin
            // ---- Always collect (no verbose gate) ----
            if (valid_in1[1]) begin
                if (node1_link_seq_idx < 8)
                    node1_link_first_words[node1_link_seq_idx] <= in1[1];
                if (in1[1] == 32'hA31E57BD) begin
                    seen_node1_in1_sync <= 1'b1;
                    node1_link_sync_count <= node1_link_sync_count + 1;
                end
                node1_link_seq_idx <= node1_link_seq_idx + 1;
            end
            if (valid_in0[7]) begin
                if (node7_link_seq_idx < 8)
                    node7_link_first_words[node7_link_seq_idx] <= in0[7];
                if (in0[7] == 32'hA31E57BD) begin
                    seen_node7_in0_sync <= 1'b1;
                    node7_link_sync_count <= node7_link_sync_count + 1;
                end
                node7_link_seq_idx <= node7_link_seq_idx + 1;
            end
        end
        // ---- Per-beat $display traces only when verbose enabled ----
        if (!rst && ENABLE_VERBOSE_DEBUG && ENABLE_TEST1_DEBUG && test1_debug_active) begin
            if (valid_in1[1]) begin
                $display("LINKSEQ node=1 port=1 idx=%0d data=%08h", node1_link_seq_idx, in1[1]);
                $display("LINKDBG time=%0t node=1 port=1 data=%08h", $time, in1[1]);
            end
            if (valid_in0[7]) begin
                $display("LINKSEQ node=7 port=0 idx=%0d data=%08h", node7_link_seq_idx, in0[7]);
                $display("LINKDBG time=%0t node=7 port=0 data=%08h", $time, in0[7]);
            end
        end
    end

    // RX FIFO / frame_rx debug on first-hop receivers.
    //   first_words / sync_count / seq_idx / seen flags gated ONLY by
    //   test1_debug_active; $display traces gated by verbose flags.
    always @(posedge clk) begin
        if (rst) begin
            seen_node1_frame_ready <= 1'b0;
            seen_node7_frame_ready <= 1'b0;
            node4_frame_ready <= 1'b0;
            node4_app_rx_frame_valid <= 1'b0;
            node1_rx_seq_idx <= 0;
            node7_rx_seq_idx <= 0;
            node1_rx_sync_count <= 0;
            node7_rx_sync_count <= 0;
            for (integer rx_rst_i = 0; rx_rst_i < 8; rx_rst_i = rx_rst_i + 1) begin
                node1_rx_first_words[rx_rst_i] <= 32'd0;
                node7_rx_first_words[rx_rst_i] <= 32'd0;
            end
        end else if (test1_debug_active) begin
            // ---- Always collect (no verbose gate) ----
            if (g_node[1].u_node.u_node_core.rx_rd_en[1]) begin
                if (node1_rx_seq_idx < 8)
                    node1_rx_first_words[node1_rx_seq_idx] <= g_node[1].u_node.u_node_core.rx_dout_flat[1*32 +: 32];
                if (g_node[1].u_node.u_node_core.rx_dout_flat[1*32 +: 32] == 32'hA31E57BD)
                    node1_rx_sync_count <= node1_rx_sync_count + 1;
                node1_rx_seq_idx <= node1_rx_seq_idx + 1;
            end
            if (g_node[7].u_node.u_node_core.rx_rd_en[0]) begin
                if (node7_rx_seq_idx < 8)
                    node7_rx_first_words[node7_rx_seq_idx] <= g_node[7].u_node.u_node_core.rx_dout_flat[0*32 +: 32];
                if (g_node[7].u_node.u_node_core.rx_dout_flat[0*32 +: 32] == 32'hA31E57BD)
                    node7_rx_sync_count <= node7_rx_sync_count + 1;
                node7_rx_seq_idx <= node7_rx_seq_idx + 1;
            end
            if (g_node[1].u_node.u_node_core.frame_ready[1])
                seen_node1_frame_ready <= 1'b1;
            if (g_node[7].u_node.u_node_core.frame_ready[0])
                seen_node7_frame_ready <= 1'b1;
            if (|g_node[4].u_node.u_node_core.frame_ready)
                node4_frame_ready <= 1'b1;
            if (app_rx_frame_valid[4])
                node4_app_rx_frame_valid <= 1'b1;
        end
        // ---- Per-beat $display traces only when verbose enabled ----
        if (!rst && ENABLE_VERBOSE_DEBUG && ENABLE_TEST1_DEBUG && test1_debug_active) begin
            if (g_node[1].u_node.u_node_core.rx_rd_en[1])
                $display("RXSEQ node=1 port=1 idx=%0d dout=%08h st=%0d",
                         node1_rx_seq_idx,
                         g_node[1].u_node.u_node_core.rx_dout_flat[1*32 +: 32],
                         g_node[1].u_node.u_node_core.g_rx[1].u_frame_rx.st);
            if (g_node[7].u_node.u_node_core.rx_rd_en[0])
                $display("RXSEQ node=7 port=0 idx=%0d dout=%08h st=%0d",
                         node7_rx_seq_idx,
                         g_node[7].u_node.u_node_core.rx_dout_flat[0*32 +: 32],
                         g_node[7].u_node.u_node_core.g_rx[0].u_frame_rx.st);
            if (g_node[1].u_node.u_node_core.rx_rd_en[1] ||
                g_node[1].u_node.u_node_core.frame_ready[1] ||
                g_node[1].u_node.u_node_core.frame_consumed[1])
                $display("RXDBG time=%0t node=1 port=1 empty=%0d rd_en=%0d dout=%08h ready=%0d consumed=%0d st=%0d crc_res=%08h crc_rcv=%08h sid=%02h did=%02h cnt=%04h plen=%04h tlen=%04h wi=%04h",
                         $time,
                         g_node[1].u_node.u_node_core.rx_empty[1],
                         g_node[1].u_node.u_node_core.rx_rd_en[1],
                         g_node[1].u_node.u_node_core.rx_dout_flat[1*32 +: 32],
                         g_node[1].u_node.u_node_core.frame_ready[1],
                         g_node[1].u_node.u_node_core.frame_consumed[1],
                         g_node[1].u_node.u_node_core.g_rx[1].u_frame_rx.st,
                         g_node[1].u_node.u_node_core.g_rx[1].u_frame_rx.crc_res,
                         g_node[1].u_node.u_node_core.g_rx[1].u_frame_rx.crc_rcv,
                         g_node[1].u_node.u_node_core.g_rx[1].u_frame_rx.sid,
                         g_node[1].u_node.u_node_core.g_rx[1].u_frame_rx.did,
                         g_node[1].u_node.u_node_core.g_rx[1].u_frame_rx.cnt,
                         g_node[1].u_node.u_node_core.g_rx[1].u_frame_rx.plen,
                         g_node[1].u_node.u_node_core.g_rx[1].u_frame_rx.tlen,
                         g_node[1].u_node.u_node_core.g_rx[1].u_frame_rx.wi);
            if (g_node[7].u_node.u_node_core.rx_rd_en[0] ||
                g_node[7].u_node.u_node_core.frame_ready[0] ||
                g_node[7].u_node.u_node_core.frame_consumed[0])
                $display("RXDBG time=%0t node=7 port=0 empty=%0d rd_en=%0d dout=%08h ready=%0d consumed=%0d st=%0d crc_res=%08h crc_rcv=%08h sid=%02h did=%02h cnt=%04h plen=%04h tlen=%04h wi=%04h",
                         $time,
                         g_node[7].u_node.u_node_core.rx_empty[0],
                         g_node[7].u_node.u_node_core.rx_rd_en[0],
                         g_node[7].u_node.u_node_core.rx_dout_flat[0*32 +: 32],
                         g_node[7].u_node.u_node_core.frame_ready[0],
                         g_node[7].u_node.u_node_core.frame_consumed[0],
                         g_node[7].u_node.u_node_core.g_rx[0].u_frame_rx.st,
                         g_node[7].u_node.u_node_core.g_rx[0].u_frame_rx.crc_res,
                         g_node[7].u_node.u_node_core.g_rx[0].u_frame_rx.crc_rcv,
                         g_node[7].u_node.u_node_core.g_rx[0].u_frame_rx.sid,
                         g_node[7].u_node.u_node_core.g_rx[0].u_frame_rx.did,
                         g_node[7].u_node.u_node_core.g_rx[0].u_frame_rx.cnt,
                         g_node[7].u_node.u_node_core.g_rx[0].u_frame_rx.plen,
                         g_node[7].u_node.u_node_core.g_rx[0].u_frame_rx.tlen,
                         g_node[7].u_node.u_node_core.g_rx[0].u_frame_rx.wi);
        end
    end

    // Forwarding path debug on first-hop receivers.
    //   seen flags gated ONLY by test1_debug_active; $display traces gated by
    //   ENABLE_VERBOSE_DEBUG && ENABLE_TEST1_DEBUG.
    always @(posedge clk) begin
        if (rst) begin
            seen_node1_forward_req <= 1'b0;
            seen_node7_forward_req <= 1'b0;
            seen_node1_valid_out <= 1'b0;
            seen_node7_valid_out <= 1'b0;
        end else if (test1_debug_active) begin
            // ---- Always collect seen flags (no verbose gate) ----
            if (g_node[1].u_node.u_node_core.forward_req)
                seen_node1_forward_req <= 1'b1;
            if (g_node[7].u_node.u_node_core.forward_req)
                seen_node7_forward_req <= 1'b1;
            if (valid_out0[1] || valid_out1[1])
                seen_node1_valid_out <= 1'b1;
            if (valid_out0[7] || valid_out1[7])
                seen_node7_valid_out <= 1'b1;
        end
        // ---- Per-beat $display traces only when verbose enabled ----
        if (!rst && ENABLE_VERBOSE_DEBUG && ENABLE_TEST1_DEBUG && test1_debug_active) begin
            if (g_node[1].u_node.u_node_core.forward_candidate_valid ||
                g_node[1].u_node.u_node_core.forward_candidate_done ||
                g_node[1].u_node.u_node_core.forward_req ||
                g_node[1].u_node.u_node_core.forward_accept ||
                g_node[1].u_node.u_node_core.forward_dropped ||
                |g_node[1].u_node.u_node_core.tx_frame_queue_wr_en ||
                valid_out0[1] || valid_out1[1]) begin
                $display("FWDDBG time=%0t node=1 fvalid=%0d fready=%0d fdone=%0d freq=%0d faccept=%0d fdrop=%0d fmask=%b q_wr=%b vout0=%0d vout1=%0d",
                         $time,
                         g_node[1].u_node.u_node_core.forward_candidate_valid,
                         g_node[1].u_node.u_node_core.forward_candidate_ready,
                         g_node[1].u_node.u_node_core.forward_candidate_done,
                         g_node[1].u_node.u_node_core.forward_req,
                         g_node[1].u_node.u_node_core.forward_accept,
                         g_node[1].u_node.u_node_core.forward_dropped,
                         g_node[1].u_node.u_node_core.forward_port_mask,
                         g_node[1].u_node.u_node_core.tx_frame_queue_wr_en,
                         valid_out0[1],
                         valid_out1[1]);
            end
            if (g_node[7].u_node.u_node_core.forward_candidate_valid ||
                g_node[7].u_node.u_node_core.forward_candidate_done ||
                g_node[7].u_node.u_node_core.forward_req ||
                g_node[7].u_node.u_node_core.forward_accept ||
                g_node[7].u_node.u_node_core.forward_dropped ||
                |g_node[7].u_node.u_node_core.tx_frame_queue_wr_en ||
                valid_out0[7] || valid_out1[7]) begin
                $display("FWDDBG time=%0t node=7 fvalid=%0d fready=%0d fdone=%0d freq=%0d faccept=%0d fdrop=%0d fmask=%b q_wr=%b vout0=%0d vout1=%0d",
                         $time,
                         g_node[7].u_node.u_node_core.forward_candidate_valid,
                         g_node[7].u_node.u_node_core.forward_candidate_ready,
                         g_node[7].u_node.u_node_core.forward_candidate_done,
                         g_node[7].u_node.u_node_core.forward_req,
                         g_node[7].u_node.u_node_core.forward_accept,
                         g_node[7].u_node.u_node_core.forward_dropped,
                         g_node[7].u_node.u_node_core.forward_port_mask,
                         g_node[7].u_node.u_node_core.tx_frame_queue_wr_en,
                         valid_out0[7],
                         valid_out1[7]);
            end
        end
    end

    // Source-side Test1 diagnostic.  Keep this independent of verbose flags so
    // a Vivado timeout can say whether Node0 stalled before enqueue, before TX
    // FIFO write, before port output, or at the testbench link.
    always @(posedge clk) begin
        if (rst) begin
            src0_id_locked <= 1'b0;
            src0_app_frame_ready <= 1'b0;
            src0_app_frame_accepted <= 1'b0;
            src0_app_frame_done <= 1'b0;
            src0_network_congested <= 1'b0;
            src0_app_len_error <= 1'b0;
            src0_local_req <= 1'b0;
            src0_local_accept <= 1'b0;
            src0_local_app_done <= 1'b0;
            src0_q_wr <= 1'b0;
            src0_txwr <= 1'b0;
            src0_valid_out <= 1'b0;
            src0_enq_st_last <= 3'd0;
            src0_q_din0_last <= 34'd0;
            src0_q_din1_last <= 34'd0;
            src0_tx_din0_last <= 32'd0;
            src0_tx_din1_last <= 32'd0;
            src0_out0_last <= 32'd0;
            src0_out1_last <= 32'd0;
        end else if (test1_debug_active) begin
            if (g_node[0].u_node.u_node_core.id_locked)
                src0_id_locked <= 1'b1;
            if (app_frame_ready[0])
                src0_app_frame_ready <= 1'b1;
            if (app_frame_valid[0] && app_frame_ready[0])
                src0_app_frame_accepted <= 1'b1;
            if (app_frame_done[0])
                src0_app_frame_done <= 1'b1;
            if (network_congested[0])
                src0_network_congested <= 1'b1;
            if (app_len_error[0])
                src0_app_len_error <= 1'b1;
            if (g_node[0].u_node.u_node_core.local_req)
                src0_local_req <= 1'b1;
            if (g_node[0].u_node.u_node_core.local_accept)
                src0_local_accept <= 1'b1;
            if (g_node[0].u_node.u_node_core.local_app_done)
                src0_local_app_done <= 1'b1;
            src0_enq_st_last <= g_node[0].u_node.u_node_core.u_tx_enqueue_engine.st;
            if (|g_node[0].u_node.u_node_core.tx_frame_queue_wr_en) begin
                src0_q_wr <= 1'b1;
                src0_q_din0_last <= g_node[0].u_node.u_node_core.tx_frame_queue_din_flat[0*34 +: 34];
                src0_q_din1_last <= g_node[0].u_node.u_node_core.tx_frame_queue_din_flat[1*34 +: 34];
            end
            if (|g_node[0].u_node.u_node_core.tx_wr_en) begin
                src0_txwr <= 1'b1;
                src0_tx_din0_last <= g_node[0].u_node.u_node_core.tx_din_flat[0*32 +: 32];
                src0_tx_din1_last <= g_node[0].u_node.u_node_core.tx_din_flat[1*32 +: 32];
            end
            if (valid_out0[0]) begin
                src0_valid_out <= 1'b1;
                src0_out0_last <= out0[0];
            end
            if (valid_out1[0]) begin
                src0_valid_out <= 1'b1;
                src0_out1_last <= out1[0];
            end
        end
    end
    genvar dbg_n;
    generate
        for (dbg_n = 0; dbg_n < NUM_NODES; dbg_n = dbg_n + 1) begin : g_test2_debug
            always @(posedge clk) begin
                if (rst) begin
                    test2_forward_req_5_0_count[dbg_n] <= 0;
                    test2_forward_req_5_0_dup0_count[dbg_n] <= 0;
                    test2_max_payload_idx[dbg_n] <= 16'd0;
                    test2_payload_seen[dbg_n][0] <= 32'd0;
                    test2_payload_seen[dbg_n][1] <= 32'd0;
                    test2_payload_seen[dbg_n][2] <= 32'd0;
                    test2_queue_seen[dbg_n][0] <= 32'd0;
                    test2_queue_seen[dbg_n][1] <= 32'd0;
                    test2_queue_seen[dbg_n][2] <= 32'd0;
                end else if (ENABLE_VERBOSE_DEBUG && ENABLE_TEST2_DEBUG && test2_debug_active) begin
                    if (test2_debug_cycles < 1200) begin
                        if (g_node[dbg_n].u_node.u_node_core.forward_candidate_valid ||
                            g_node[dbg_n].u_node.u_node_core.forward_req ||
                            g_node[dbg_n].u_node.u_node_core.forward_accept ||
                            g_node[dbg_n].u_node.u_node_core.forward_dropped ||
                            g_node[dbg_n].u_node.u_node_core.forward_candidate_done ||
                            g_node[dbg_n].u_node.u_node_core.forward_candidate_duplicate) begin
                            $display("FWD2DBG time=%0t node=%0d cand_port=%0d src=%02h dst=%02h count=%04h len=%04h should=%0d mask=%b payload_port=%0d req=%0d accept=%0d drop=%0d done=%0d duplicate=%0d",
                                     $time, dbg_n,
                                     g_node[dbg_n].u_node.u_node_core.forward_candidate_port,
                                     g_node[dbg_n].u_node.u_node_core.forward_candidate_src,
                                     g_node[dbg_n].u_node.u_node_core.forward_candidate_dst,
                                     g_node[dbg_n].u_node.u_node_core.forward_candidate_count,
                                     g_node[dbg_n].u_node.u_node_core.forward_candidate_len,
                                     g_node[dbg_n].u_node.u_node_core.forward_candidate_should_forward,
                                     g_node[dbg_n].u_node.u_node_core.forward_port_mask,
                                     g_node[dbg_n].u_node.u_node_core.forward_payload_port,
                                     g_node[dbg_n].u_node.u_node_core.forward_req,
                                     g_node[dbg_n].u_node.u_node_core.forward_accept,
                                     g_node[dbg_n].u_node.u_node_core.forward_dropped,
                                     g_node[dbg_n].u_node.u_node_core.forward_candidate_done,
                                     g_node[dbg_n].u_node.u_node_core.forward_candidate_duplicate);
                        end

                        if (g_node[dbg_n].u_node.u_node_core.u_forward_engine.forward_dedup_lookup ||
                            g_node[dbg_n].u_node.u_node_core.u_forward_engine.forward_dedup_insert) begin
                            $display("DEDUP2DBG time=%0t node=%0d lookup=%0d lookup_src=%02h lookup_count=%04h found=%0d insert=%0d insert_src=%02h insert_count=%04h",
                                     $time, dbg_n,
                                     g_node[dbg_n].u_node.u_node_core.u_forward_engine.forward_dedup_lookup,
                                     g_node[dbg_n].u_node.u_node_core.u_forward_engine.forward_dedup_src,
                                     g_node[dbg_n].u_node.u_node_core.u_forward_engine.forward_dedup_count,
                                     g_node[dbg_n].u_node.u_node_core.u_forward_engine.forward_dedup_found,
                                     g_node[dbg_n].u_node.u_node_core.u_forward_engine.forward_dedup_insert,
                                     g_node[dbg_n].u_node.u_node_core.u_forward_engine.forward_dedup_src,
                                     g_node[dbg_n].u_node.u_node_core.u_forward_engine.forward_dedup_count);
                        end
                    end

                    if (g_node[dbg_n].u_node.u_node_core.forward_accept &&
                        !g_node[dbg_n].u_node.u_node_core.forward_dropped &&
                        g_node[dbg_n].u_node.u_node_core.forward_src_id == 8'd5 &&
                        g_node[dbg_n].u_node.u_node_core.forward_count == 16'd0) begin
                        test2_forward_req_5_0_count[dbg_n] <= test2_forward_req_5_0_count[dbg_n] + 1;
                        if (!g_node[dbg_n].u_node.u_node_core.forward_candidate_duplicate) begin
                            test2_forward_req_5_0_dup0_count[dbg_n] <= test2_forward_req_5_0_dup0_count[dbg_n] + 1;
                            if (test2_forward_req_5_0_dup0_count[dbg_n] >= 1)
                                test2_dedup_issue <= 1'b1;
                        end
                    end

                    if (g_node[dbg_n].u_node.u_node_core.u_tx_enqueue_engine.active_forward &&
                        g_node[dbg_n].u_node.u_node_core.u_tx_enqueue_engine.active_src == 8'd5 &&
                        g_node[dbg_n].u_node.u_node_core.u_tx_enqueue_engine.active_count == 16'd0) begin
                        if (g_node[dbg_n].u_node.u_node_core.u_tx_enqueue_engine.payload_idx > test2_max_payload_idx[dbg_n])
                            test2_max_payload_idx[dbg_n] <= g_node[dbg_n].u_node.u_node_core.u_tx_enqueue_engine.payload_idx;

                        if (g_node[dbg_n].u_node.u_node_core.u_tx_enqueue_engine.st == 3'd4) begin
                            if (test2_debug_cycles < 1200) begin
                                $display("PAYLOAD2DBG time=%0t node=%0d st=%0d active_forward=%0d src=%02h dst=%02h count=%04h len=%04h payload_idx=%0d enqueue_idx=%0d payload_port=%0d rx_idx0=%0d rx_data0=%08h rx_idx1=%0d rx_data1=%08h enqueue_data=%08h q_wr=%b q_data0=%08h q_data1=%08h",
                                         $time, dbg_n,
                                         g_node[dbg_n].u_node.u_node_core.u_tx_enqueue_engine.st,
                                         g_node[dbg_n].u_node.u_node_core.u_tx_enqueue_engine.active_forward,
                                         g_node[dbg_n].u_node.u_node_core.u_tx_enqueue_engine.active_src,
                                         g_node[dbg_n].u_node.u_node_core.u_tx_enqueue_engine.active_dst,
                                         g_node[dbg_n].u_node.u_node_core.u_tx_enqueue_engine.active_count,
                                         g_node[dbg_n].u_node.u_node_core.u_tx_enqueue_engine.active_len,
                                         g_node[dbg_n].u_node.u_node_core.u_tx_enqueue_engine.payload_idx,
                                         g_node[dbg_n].u_node.u_node_core.enqueue_payload_index,
                                         g_node[dbg_n].u_node.u_node_core.enqueue_payload_forward_port,
                                         g_node[dbg_n].u_node.u_node_core.rx_payload_index[0],
                                         g_node[dbg_n].u_node.u_node_core.rx_payload_data[0],
                                         g_node[dbg_n].u_node.u_node_core.rx_payload_index[1],
                                         g_node[dbg_n].u_node.u_node_core.rx_payload_data[1],
                                         g_node[dbg_n].u_node.u_node_core.enqueue_payload_data,
                                         g_node[dbg_n].u_node.u_node_core.tx_frame_queue_wr_en,
                                         g_node[dbg_n].u_node.u_node_core.tx_frame_queue_din_flat[0*34 +: 32],
                                         g_node[dbg_n].u_node.u_node_core.tx_frame_queue_din_flat[1*34 +: 32]);
                            end

                            if (g_node[dbg_n].u_node.u_node_core.u_tx_enqueue_engine.payload_idx < 3) begin
                                test2_payload_seen[dbg_n][g_node[dbg_n].u_node.u_node_core.u_tx_enqueue_engine.payload_idx] <=
                                    g_node[dbg_n].u_node.u_node_core.enqueue_payload_data;
                                test2_queue_seen[dbg_n][g_node[dbg_n].u_node.u_node_core.u_tx_enqueue_engine.payload_idx] <=
                                    g_node[dbg_n].u_node.u_node_core.tx_frame_queue_din_flat[0*34 +: 32];
                                if (g_node[dbg_n].u_node.u_node_core.enqueue_payload_data == 32'd0)
                                    test2_payload_read_zero <= 1'b1;
                                if ((g_node[dbg_n].u_node.u_node_core.enqueue_payload_data == (32'hB000_0000 + g_node[dbg_n].u_node.u_node_core.u_tx_enqueue_engine.payload_idx)) &&
                                    (g_node[dbg_n].u_node.u_node_core.tx_frame_queue_din_flat[0*34 +: 32] == 32'd0))
                                    test2_queue_write_zero <= 1'b1;
                                if (g_node[dbg_n].u_node.u_node_core.enqueue_payload_data == (32'hB000_0000 + g_node[dbg_n].u_node.u_node_core.u_tx_enqueue_engine.payload_idx))
                                    test2_queue_payload_ok <= 1'b1;
                            end
                        end
                    end

                    if (test2_debug_cycles < 1200 &&
                        (|g_node[dbg_n].u_node.u_node_core.frame_ready ||
                         |g_node[dbg_n].u_node.u_node_core.frame_consumed)) begin
                        $display("RXCONSUME2DBG time=%0t node=%0d ready=%b consumed=%b src0=%02h dst0=%02h count0=%04h len0=%04h st0=%0d idx0=%0d data0=%08h src1=%02h dst1=%02h count1=%04h len1=%04h st1=%0d idx1=%0d data1=%08h",
                                 $time, dbg_n,
                                 g_node[dbg_n].u_node.u_node_core.frame_ready,
                                 g_node[dbg_n].u_node.u_node_core.frame_consumed,
                                 g_node[dbg_n].u_node.u_node_core.rx_src_id[0],
                                 g_node[dbg_n].u_node.u_node_core.rx_dst_id[0],
                                 g_node[dbg_n].u_node.u_node_core.rx_count[0],
                                 g_node[dbg_n].u_node.u_node_core.rx_len16[0],
                                 g_node[dbg_n].u_node.u_node_core.g_rx[0].u_frame_rx.st,
                                 g_node[dbg_n].u_node.u_node_core.rx_payload_index[0],
                                 g_node[dbg_n].u_node.u_node_core.rx_payload_data[0],
                                 g_node[dbg_n].u_node.u_node_core.rx_src_id[1],
                                 g_node[dbg_n].u_node.u_node_core.rx_dst_id[1],
                                 g_node[dbg_n].u_node.u_node_core.rx_count[1],
                                 g_node[dbg_n].u_node.u_node_core.rx_len16[1],
                                 g_node[dbg_n].u_node.u_node_core.g_rx[1].u_frame_rx.st,
                                 g_node[dbg_n].u_node.u_node_core.rx_payload_index[1],
                                 g_node[dbg_n].u_node.u_node_core.rx_payload_data[1]);
                    end

                    if (g_node[dbg_n].u_node.u_node_core.u_tx_enqueue_engine.active_forward &&
                        g_node[dbg_n].u_node.u_node_core.u_tx_enqueue_engine.active_src == 8'd5 &&
                        g_node[dbg_n].u_node.u_node_core.u_tx_enqueue_engine.active_count == 16'd0 &&
                        |g_node[dbg_n].u_node.u_node_core.frame_consumed &&
                        (test2_max_payload_idx[dbg_n] < 16'd2))
                        test2_consumed_before_payload_done <= 1'b1;
                end
            end
        end
    endgenerate

    always @(posedge clk) begin
        if (rst || !test2_debug_active) begin
            test2_debug_cycles <= 0;
        end else begin
            test2_debug_cycles <= test2_debug_cycles + 1;
            if (ENABLE_VERBOSE_DEBUG && ENABLE_TEST2_DEBUG && test2_debug_cycles < 1200) begin
                if (app_rx_frame_valid[1] || app_rx_payload_valid[1]) begin
                    $display("APP2DBG time=%0t node=1 frame_valid=%0d src=%02h dst=%02h count=%04h len=%04h payload_valid=%0d addr=%0d data=%08h rfifo_st=%0d",
                             $time, app_rx_frame_valid[1], app_rx_src_id[1], app_rx_dst_id[1], app_rx_count[1], app_rx_len16[1],
                             app_rx_payload_valid[1], app_rx_payload_addr[1], app_rx_payload_data[1],
                             g_node[1].u_node.u_node_core.u_rx_report_fifo.st);
                end
                if (g_node[1].u_node.u_node_core.rx_report_wr_en) begin
                    $display("RXREPORT2DBG time=%0t node=1 st=%0d active_port=%0d payload_index=%0d enq_fwd=%0d enq_idx=%0d rx_idx0=%0d rx_data0=%08h rx_idx1=%0d rx_data1=%08h wr_din=%08h",
                             $time,
                             g_node[1].u_node.u_node_core.u_rx_dispatcher.st,
                             g_node[1].u_node.u_node_core.u_rx_dispatcher.active_port,
                             g_node[1].u_node.u_node_core.u_rx_dispatcher.payload_index,
                             g_node[1].u_node.u_node_core.enqueue_payload_is_forward,
                             g_node[1].u_node.u_node_core.enqueue_payload_index,
                             g_node[1].u_node.u_node_core.rx_payload_index[0],
                             g_node[1].u_node.u_node_core.rx_payload_data[0],
                             g_node[1].u_node.u_node_core.rx_payload_index[1],
                             g_node[1].u_node.u_node_core.rx_payload_data[1],
                             g_node[1].u_node.u_node_core.rx_report_din);
                end
                if (app_frame_done[5] || |g_node[5].u_node.u_node_core.tx_wr_en || valid_out0[5] || valid_out1[5]) begin
                    $display("SRC2DBG time=%0t node=5 app_done=%0d tx_wr=%b tx_din0=%08h tx_din1=%08h vout0=%0d out0=%08h vout1=%0d out1=%08h",
                             $time, app_frame_done[5], g_node[5].u_node.u_node_core.tx_wr_en,
                             g_node[5].u_node.u_node_core.tx_din_flat[0*32 +: 32],
                             g_node[5].u_node.u_node_core.tx_din_flat[1*32 +: 32],
                             valid_out0[5], out0[5], valid_out1[5], out1[5]);
                end
                if (link_valid_ccw[5] || link_valid_cw[5] || valid_in0[4] || valid_in1[6]) begin
                    $display("RXIN2DBG time=%0t link_ccw5_v=%0d link_ccw5=%08h link_cw5_v=%0d link_cw5=%08h in4p0_v=%0d in4p0=%08h in6p1_v=%0d in6p1=%08h",
                             $time, link_valid_ccw[5], link_data_ccw[5], link_valid_cw[5], link_data_cw[5],
                             valid_in0[4], in0[4], valid_in1[6], in1[6]);
                end
            end
        end
    end
    //--------------------------------------------------------------------------
    // Node ID assignment task
    //--------------------------------------------------------------------------
    task assign_node_ids;
        reg [7:0] nid;
        begin
            repeat (5) @(posedge clk);
            for (nid = 0; nid < NUM_NODES; nid = nid + 1) begin
                node_id[nid] = nid;
                node_id_valid[nid] = 1'b1;
            end
            @(posedge clk);
            for (nid = 0; nid < NUM_NODES; nid = nid + 1)
                node_id_valid[nid] = 1'b0;
            @(posedge clk);
            // Wait for all nodes to lock their IDs
            repeat (20) @(posedge clk);
        end
    endtask

    //--------------------------------------------------------------------------
    // Send app frame task
    //--------------------------------------------------------------------------
    task send_app_frame;
        input integer src_node;
        input [7:0] dst_id;
        input integer len;       // number of 32-bit payload words
        input [31:0] base_data;
        integer k;
        begin
            // Write payload data to the source node's payload RAM
            for (k = 0; k < len; k = k + 1)
                payload_mem[src_node][k] = base_data + k;

            // Set up the app interface
            app_dst_id[src_node] = dst_id;
            app_len16[src_node] = len;
            app_frame_valid[src_node] = 1'b1;

            // Wait for acceptance (valid & ready handshake)
            while (!app_frame_ready[src_node] || !app_frame_valid[src_node])
                @(posedge clk);
            @(posedge clk);
            app_frame_valid[src_node] <= 1'b0;
            app_dst_id[src_node] <= 8'd0;
            app_len16[src_node] <= 16'd0;

            // Wait for frame done
            while (!app_frame_done[src_node])
                @(posedge clk);

            // Wait for payload busy to clear (extra cycle)
            @(posedge clk);
        end
    endtask

    //--------------------------------------------------------------------------
    // Wait for a node to receive a specific number of new frames
    //--------------------------------------------------------------------------
    task wait_for_rx_frames;
        input integer node;
        input integer target_count;
        input integer timeout_cycles;
        integer cycles;
        begin
            cycles = 0;
            while (received_frame_count[node] < target_count && cycles < timeout_cycles) begin
                @(posedge clk);
                cycles = cycles + 1;
            end
            if (cycles >= timeout_cycles && received_frame_count[node] < target_count)
                $fatal(1, "TIMEOUT: Node %0d expected %0d frames, got %0d after %0d cycles",
                       node, target_count, received_frame_count[node], cycles);
        end
    endtask

    task wait_for_rx_frames_no_fatal;
        input integer node;
        input integer target_count;
        input integer timeout_cycles;
        output integer timed_out;
        integer cycles;
        begin
            cycles = 0;
            timed_out = 0;
            while (received_frame_count[node] < target_count && cycles < timeout_cycles) begin
                @(posedge clk);
                cycles = cycles + 1;
            end
            if (cycles >= timeout_cycles && received_frame_count[node] < target_count) begin
                timed_out = 1;
                $display("TIMEOUT: Node %0d expected %0d frames, got %0d after %0d cycles",
                         node, target_count, received_frame_count[node], cycles);
            end
        end
    endtask

    task print_test1_diagnostic;
        begin
            $display("  DIAG Test1 summary:");
            $display("    seen_node1_in1_sync       = %0d", seen_node1_in1_sync);
            $display("    seen_node7_in0_sync       = %0d", seen_node7_in0_sync);
            $display("    seen_node1_frame_ready    = %0d", seen_node1_frame_ready);
            $display("    seen_node7_frame_ready    = %0d", seen_node7_frame_ready);
            $display("    seen_node1_forward_req    = %0d", seen_node1_forward_req);
            $display("    seen_node7_forward_req    = %0d", seen_node7_forward_req);
            $display("    seen_node1_valid_out      = %0d", seen_node1_valid_out);
            $display("    seen_node7_valid_out      = %0d", seen_node7_valid_out);
            $display("    node4_frame_ready         = %0d", node4_frame_ready);
            $display("    node4_app_rx_frame_valid  = %0d", node4_app_rx_frame_valid);
            $display("    node1_link_sync_count     = %0d", node1_link_sync_count);
            $display("    node7_link_sync_count     = %0d", node7_link_sync_count);
            $display("    node1_rx_sync_count       = %0d", node1_rx_sync_count);
            $display("    node7_rx_sync_count       = %0d", node7_rx_sync_count);
            $display("    node0_enq_port0_first_words    = %08h %08h %08h %08h %08h %08h %08h %08h",
                     node0_enq_port0_first_words[0], node0_enq_port0_first_words[1],
                     node0_enq_port0_first_words[2], node0_enq_port0_first_words[3],
                     node0_enq_port0_first_words[4], node0_enq_port0_first_words[5],
                     node0_enq_port0_first_words[6], node0_enq_port0_first_words[7]);
            $display("    node0_enq_port1_first_words    = %08h %08h %08h %08h %08h %08h %08h %08h",
                     node0_enq_port1_first_words[0], node0_enq_port1_first_words[1],
                     node0_enq_port1_first_words[2], node0_enq_port1_first_words[3],
                     node0_enq_port1_first_words[4], node0_enq_port1_first_words[5],
                     node0_enq_port1_first_words[6], node0_enq_port1_first_words[7]);
            $display("    node0_q_port0_first_words      = %08h %08h %08h %08h %08h %08h %08h %08h",
                     node0_q_port0_first_words[0], node0_q_port0_first_words[1],
                     node0_q_port0_first_words[2], node0_q_port0_first_words[3],
                     node0_q_port0_first_words[4], node0_q_port0_first_words[5],
                     node0_q_port0_first_words[6], node0_q_port0_first_words[7]);
            $display("    node0_q_port1_first_words      = %08h %08h %08h %08h %08h %08h %08h %08h",
                     node0_q_port1_first_words[0], node0_q_port1_first_words[1],
                     node0_q_port1_first_words[2], node0_q_port1_first_words[3],
                     node0_q_port1_first_words[4], node0_q_port1_first_words[5],
                     node0_q_port1_first_words[6], node0_q_port1_first_words[7]);
            $display("    node0_txwr_port0_first_words   = %08h %08h %08h %08h %08h %08h %08h %08h",
                     node0_txwr_port0_first_words[0], node0_txwr_port0_first_words[1],
                     node0_txwr_port0_first_words[2], node0_txwr_port0_first_words[3],
                     node0_txwr_port0_first_words[4], node0_txwr_port0_first_words[5],
                     node0_txwr_port0_first_words[6], node0_txwr_port0_first_words[7]);
            $display("    node0_txwr_port1_first_words   = %08h %08h %08h %08h %08h %08h %08h %08h",
                     node0_txwr_port1_first_words[0], node0_txwr_port1_first_words[1],
                     node0_txwr_port1_first_words[2], node0_txwr_port1_first_words[3],
                     node0_txwr_port1_first_words[4], node0_txwr_port1_first_words[5],
                     node0_txwr_port1_first_words[6], node0_txwr_port1_first_words[7]);
            $display("    node0_txfifo_port0_first_words = %08h %08h %08h %08h %08h %08h %08h %08h",
                     node0_txfifo_port0_first_words[0], node0_txfifo_port0_first_words[1],
                     node0_txfifo_port0_first_words[2], node0_txfifo_port0_first_words[3],
                     node0_txfifo_port0_first_words[4], node0_txfifo_port0_first_words[5],
                     node0_txfifo_port0_first_words[6], node0_txfifo_port0_first_words[7]);
            $display("    node0_txfifo_port1_first_words = %08h %08h %08h %08h %08h %08h %08h %08h",
                     node0_txfifo_port1_first_words[0], node0_txfifo_port1_first_words[1],
                     node0_txfifo_port1_first_words[2], node0_txfifo_port1_first_words[3],
                     node0_txfifo_port1_first_words[4], node0_txfifo_port1_first_words[5],
                     node0_txfifo_port1_first_words[6], node0_txfifo_port1_first_words[7]);
            $display("    node0_out_port0_first_words    = %08h %08h %08h %08h %08h %08h %08h %08h",
                     node0_out_port0_first_words[0], node0_out_port0_first_words[1],
                     node0_out_port0_first_words[2], node0_out_port0_first_words[3],
                     node0_out_port0_first_words[4], node0_out_port0_first_words[5],
                     node0_out_port0_first_words[6], node0_out_port0_first_words[7]);
            $display("    node0_out_port1_first_words    = %08h %08h %08h %08h %08h %08h %08h %08h",
                     node0_out_port1_first_words[0], node0_out_port1_first_words[1],
                     node0_out_port1_first_words[2], node0_out_port1_first_words[3],
                     node0_out_port1_first_words[4], node0_out_port1_first_words[5],
                     node0_out_port1_first_words[6], node0_out_port1_first_words[7]);
            $display("    node1_link_first_words    = %08h %08h %08h %08h %08h %08h %08h %08h",
                     node1_link_first_words[0], node1_link_first_words[1],
                     node1_link_first_words[2], node1_link_first_words[3],
                     node1_link_first_words[4], node1_link_first_words[5],
                     node1_link_first_words[6], node1_link_first_words[7]);
            $display("    node1_rx_first_words      = %08h %08h %08h %08h %08h %08h %08h %08h",
                     node1_rx_first_words[0], node1_rx_first_words[1],
                     node1_rx_first_words[2], node1_rx_first_words[3],
                     node1_rx_first_words[4], node1_rx_first_words[5],
                     node1_rx_first_words[6], node1_rx_first_words[7]);
            $display("    node7_link_first_words    = %08h %08h %08h %08h %08h %08h %08h %08h",
                     node7_link_first_words[0], node7_link_first_words[1],
                     node7_link_first_words[2], node7_link_first_words[3],
                     node7_link_first_words[4], node7_link_first_words[5],
                     node7_link_first_words[6], node7_link_first_words[7]);
            $display("    node7_rx_first_words      = %08h %08h %08h %08h %08h %08h %08h %08h",
                     node7_rx_first_words[0], node7_rx_first_words[1],
                     node7_rx_first_words[2], node7_rx_first_words[3],
                     node7_rx_first_words[4], node7_rx_first_words[5],
                     node7_rx_first_words[6], node7_rx_first_words[7]);
            $display("    SRC0CHK ever: id_locked=%0d app_ready=%0d app_accept=%0d app_done=%0d congested=%0d len_error=%0d",
                     src0_id_locked, src0_app_frame_ready, src0_app_frame_accepted,
                     src0_app_frame_done, src0_network_congested, src0_app_len_error);
            $display("    SRC0CHK ever: local_req=%0d local_accept=%0d local_app_done=%0d q_wr=%0d tx_wr=%0d valid_out=%0d enq_st_last=%0d",
                     src0_local_req, src0_local_accept, src0_local_app_done,
                     src0_q_wr, src0_txwr, src0_valid_out, src0_enq_st_last);
            $display("    SRC0CHK last: q_din0=%09h q_din1=%09h tx_din0=%08h tx_din1=%08h out0=%08h out1=%08h",
                     src0_q_din0_last, src0_q_din1_last,
                     src0_tx_din0_last, src0_tx_din1_last,
                     src0_out0_last, src0_out1_last);

            if (!src0_app_frame_ready)
                $display("  SRC0CHK conclusion: Node0 source not ready; inspect id_locked, network_congested, app_len_error, FIFO room/data_count.");
            else if (!src0_app_frame_accepted)
                $display("  SRC0CHK conclusion: Testbench asserted Test1 send but Node0 app_frame_valid/ready handshake was not observed.");
            else if (src0_app_frame_done && !src0_q_wr)
                $display("  SRC0CHK conclusion: app_frame_done occurred but tx_frame_queue_wr_en never appeared; suspect local_packet_generator/tx_enqueue_engine handshake.");
            else if (src0_q_wr && !src0_txwr)
                $display("  SRC0CHK conclusion: tx_frame_queue_wr_en appeared but tx_wr_en never appeared; suspect tx_frame_fifo/frame_meta_fifo/port_tx_queue_sender or FIFO full.");
            else if (src0_txwr && !src0_valid_out)
                $display("  SRC0CHK conclusion: tx_wr_en appeared but valid_out0/valid_out1 never appeared; suspect TX async FIFO/port_cdc/Vivado FIFO model.");
            else if (src0_valid_out && !seen_node1_in1_sync && !seen_node7_in0_sync)
                $display("  SRC0CHK conclusion: Node0 valid_out appeared but first-hop link did not see SYNC; suspect testbench ring link pipeline or valid/data sampling.");

            if (((node0_enq_port0_first_words[0] == 32'hA31E57BD) &&
                 (node0_enq_port0_first_words[1] == 32'hA31E57BD)) ||
                ((node0_enq_port1_first_words[0] == 32'hA31E57BD) &&
                 (node0_enq_port1_first_words[1] == 32'hA31E57BD))) begin
                $display("  DIAG TX detail: tx_enqueue_engine or tx_frame_fifo write side repeats SYNC.");
            end else if (((node0_q_port0_first_words[0] == 32'hA31E57BD) &&
                          (node0_q_port0_first_words[1] == 32'hA31E57BD)) ||
                         ((node0_q_port1_first_words[0] == 32'hA31E57BD) &&
                          (node0_q_port1_first_words[1] == 32'hA31E57BD))) begin
                $display("  DIAG TX detail: ENQSEQ is clean, but QSEQ repeats SYNC; suspect tx_frame_fifo/sync_fifo readout or port_tx_queue_sender read protocol.");
            end else if (((node0_txwr_port0_first_words[0] == 32'hA31E57BD) &&
                          (node0_txwr_port0_first_words[1] == 32'hA31E57BD)) ||
                         ((node0_txwr_port1_first_words[0] == 32'hA31E57BD) &&
                          (node0_txwr_port1_first_words[1] == 32'hA31E57BD))) begin
                $display("  DIAG TX detail: QSEQ is clean, but TXWRSEQ repeats SYNC; suspect port_tx_queue_sender writes TX FIFO twice.");
            end else if (((node0_txfifo_port0_first_words[0] == 32'hA31E57BD) &&
                          (node0_txfifo_port0_first_words[1] == 32'hA31E57BD)) ||
                         ((node0_txfifo_port1_first_words[0] == 32'hA31E57BD) &&
                          (node0_txfifo_port1_first_words[1] == 32'hA31E57BD))) begin
                $display("  DIAG TX detail: TXWRSEQ is clean, but TXFIFOSEQ repeats SYNC; suspect TX async FIFO or port_cdc TX FIFO read timing.");
            end else if (((node0_out_port0_first_words[0] == 32'hA31E57BD) &&
                          (node0_out_port0_first_words[1] == 32'hA31E57BD)) ||
                         ((node0_out_port1_first_words[0] == 32'hA31E57BD) &&
                          (node0_out_port1_first_words[1] == 32'hA31E57BD))) begin
                $display("  DIAG TX detail: TXFIFOSEQ is clean, but OUTSEQ repeats SYNC; suspect port_cdc output valid/data alignment.");
            end else if (((node1_link_first_words[0] == 32'hA31E57BD) &&
                          (node1_link_first_words[1] == 32'hA31E57BD)) ||
                         ((node7_link_first_words[0] == 32'hA31E57BD) &&
                          (node7_link_first_words[1] == 32'hA31E57BD))) begin
                $display("  DIAG TX detail: OUTSEQ is clean, but LINKSEQ repeats SYNC; suspect testbench link pipeline sampling or valid/data alignment.");
            end

            if (((node1_link_first_words[0] == 32'hA31E57BD) &&
                 (node1_link_first_words[1] == 32'hA31E57BD)) ||
                ((node7_link_first_words[0] == 32'hA31E57BD) &&
                 (node7_link_first_words[1] == 32'hA31E57BD))) begin
                $display("  DIAG detail: TX/link layer already repeats the first word on one first-hop port.");
            end else if (((node1_rx_first_words[0] == 32'hA31E57BD) &&
                          (node1_rx_first_words[1] == 32'hA31E57BD)) ||
                         ((node7_rx_first_words[0] == 32'hA31E57BD) &&
                          (node7_rx_first_words[1] == 32'hA31E57BD))) begin
                $display("  DIAG detail: LINKSEQ is clean, but RXSEQ repeats the first word; suspect RX FIFO/FWFT model.");
            end else if ((node1_link_seq_idx != 0) && (node1_rx_seq_idx != 0) &&
                         !seen_node1_frame_ready && !seen_node7_frame_ready) begin
                $display("  DIAG detail: LINKSEQ/RXSEQ do not show first-word duplication; suspect frame_rx FIFO read consumption timing.");
            end

            if (!src0_app_frame_ready)
                $display("  DIAG conclusion: Node0 source not ready; check id_locked/network_congested/app_len_error/FIFO room before suspecting ring link.");
            else if (!src0_app_frame_accepted)
                $display("  DIAG conclusion: Test1 send_app_frame did not complete an app_frame_valid/ready handshake on Node0.");
            else if (src0_app_frame_done && !src0_q_wr)
                $display("  DIAG conclusion: Node0 accepted/done but no tx_frame_queue_wr_en; local_packet_generator/tx_enqueue_engine handshake layer.");
            else if (src0_q_wr && !src0_txwr)
                $display("  DIAG conclusion: Node0 queued a frame but never wrote TX FIFO; tx_frame_fifo/frame_meta_fifo/port_tx_queue_sender layer.");
            else if (src0_txwr && !src0_valid_out)
                $display("  DIAG conclusion: Node0 wrote TX FIFO but produced no valid_out; TX async FIFO/port_cdc/Vivado FIFO model layer.");
            else if (((node0_txwr_port0_first_words[0] == 32'hA31E57BD) &&
                 (node0_txwr_port0_first_words[1] == 32'hA31E57BD)) ||
                ((node0_txwr_port1_first_words[0] == 32'hA31E57BD) &&
                 (node0_txwr_port1_first_words[1] == 32'hA31E57BD)))
                $display("  DIAG conclusion: port_tx_queue_sender TX FIFO write timing repeats the first queue word.");
            else if (!seen_node1_in1_sync && !seen_node7_in0_sync)
                $display("  DIAG conclusion: testbench ring link or valid/data pipeline problem.");
            else if (!seen_node1_frame_ready && !seen_node7_frame_ready)
                $display("  DIAG conclusion: RX FIFO/frame_rx/CRC parse problem; inspect frame_rx.st, crc_res, crc_rcv.");
            else if (!seen_node1_forward_req && !seen_node7_forward_req)
                $display("  DIAG conclusion: rx_dispatcher/forward_engine entry problem.");
            else if (!seen_node1_valid_out && !seen_node7_valid_out)
                $display("  DIAG conclusion: forward enqueue or TX sender problem.");
            else if (!node4_app_rx_frame_valid)
                $display("  DIAG conclusion: multi-hop propagation or Node4 local report path problem.");
            else
                $display("  DIAG conclusion: Node4 app_rx became valid but received counter/checker did not complete.");
        end
    endtask

    //--------------------------------------------------------------------------
    // Wait for all nodes' TX queues to drain (network idle)
    //--------------------------------------------------------------------------
    task wait_network_idle;
        input integer timeout_cycles;
        integer cycles;
        integer n;
        integer idle_cycles;
        reg idle_now;
        begin
            cycles = 0;
            idle_cycles = 0;
            repeat (100) @(posedge clk); // let frames propagate initially
            while ((cycles < timeout_cycles) && (idle_cycles < 200)) begin
                @(posedge clk);
                cycles = cycles + 1;
                idle_now = 1'b1;
                for (n = 0; n < NUM_NODES; n = n + 1) begin
                    if (network_congested[n] || valid_out0[n] || valid_out1[n] ||
                        valid_in0[n] || valid_in1[n] ||
                        link_valid_cw[n] || link_valid_ccw[n])
                        idle_now = 1'b0;
                end
                if (idle_now)
                    idle_cycles = idle_cycles + 1;
                else
                    idle_cycles = 0;
            end
            if (cycles >= timeout_cycles)
                $display("WARNING: wait_network_idle reached timeout_cycles=%0d", timeout_cycles);
        end
    endtask

    task print_test2_diagnostic;
        integer dn;
        begin
            $display("============================================================");
            $display(" TEST2 DIAGNOSTIC SUMMARY");
            $display("============================================================");
            for (dn = 0; dn < NUM_NODES; dn = dn + 1) begin
                if (test2_forward_req_5_0_count[dn] != 0 ||
                    test2_payload_seen[dn][0] != 32'd0 ||
                    test2_payload_seen[dn][1] != 32'd0 ||
                    test2_payload_seen[dn][2] != 32'd0) begin
                    $display("  Node%0d: forward_req(src=5,count=0)=%0d duplicate0_req=%0d max_payload_idx=%0d payload_seen=%08h/%08h/%08h queue_seen=%08h/%08h/%08h",
                             dn,
                             test2_forward_req_5_0_count[dn],
                             test2_forward_req_5_0_dup0_count[dn],
                             test2_max_payload_idx[dn],
                             test2_payload_seen[dn][0],
                             test2_payload_seen[dn][1],
                             test2_payload_seen[dn][2],
                             test2_queue_seen[dn][0],
                             test2_queue_seen[dn][1],
                             test2_queue_seen[dn][2]);
                end
            end
            if (test2_dedup_issue)
                $display("  DIAG A: forward dedup insert/lookup problem: same node issued multiple forward_req for src=5,count=0 with duplicate=0.");
            if (test2_consumed_before_payload_done)
                $display("  DIAG B: rx_dispatcher released frame_rx before tx_enqueue_engine finished reading forward payload.");
            if (test2_payload_read_zero)
                $display("  DIAG C: forward payload read timing problem: active_forward payload_idx 0/1/2 saw enqueue_payload_data=0.");
            if (test2_queue_write_zero)
                $display("  DIAG D: tx_enqueue_engine queue write timing problem: enqueue_payload_data was correct but queue_din_flat wrote 0.");
            if (test2_len_mismatch_after_good_forward)
                $display("  DIAG E: forwarded payload reached queue correctly, but Node1 app_rx checker saw len mismatch; suspect rx_report_fifo/app_rx checker or multi-frame overwrite.");
            if (!test2_dedup_issue && !test2_consumed_before_payload_done &&
                !test2_payload_read_zero && !test2_queue_write_zero &&
                !test2_len_mismatch_after_good_forward)
                $display("  DIAG: no A-E signature latched after current fix.");
        end
    endtask
    //--------------------------------------------------------------------------
    // Check that a unicast frame was received correctly
    //--------------------------------------------------------------------------
    task check_unicast_received;
        input integer dst_node;
        input [7:0] expected_src;
        input [7:0] expected_dst;
        input integer expected_len;
        input [31:0] base_data;
        input integer expect_count;    // expected received_frame_count after this
        integer k;
        integer cycles;
        begin
            // Check header
            if (last_rx_src[dst_node] !== expected_src) begin
                $error("FAIL Node %0d: expected src=%0d, got src=%0d",
                       dst_node, expected_src, last_rx_src[dst_node]);
                $fatal;
            end
            if (last_rx_dst[dst_node] !== expected_dst) begin
                $error("FAIL Node %0d: expected dst=%0d, got dst=%0d",
                       dst_node, expected_dst, last_rx_dst[dst_node]);
                $fatal;
            end
            if (last_rx_len[dst_node] !== expected_len[15:0]) begin
                $error("FAIL Node %0d: expected len=%0d, got len=%0d",
                       dst_node, expected_len, last_rx_len[dst_node]);
                if (test2_debug_active && dst_node == 1 && expected_src == 8'd5) begin
                    if (test2_queue_payload_ok && !test2_payload_read_zero && !test2_queue_write_zero)
                        test2_len_mismatch_after_good_forward = 1'b1;
                    print_test2_diagnostic();
                end
                $fatal;
            end

            cycles = 0;
            while ((expected_len > 0) && (ri[dst_node] < expected_len[15:0]) &&
                   (cycles < TIMEOUT_CYCLES)) begin
                @(posedge clk);
                cycles = cycles + 1;
            end
            if ((expected_len > 0) && (ri[dst_node] < expected_len[15:0])) begin
                $error("FAIL Node %0d: expected %0d payload words, got %0d",
                       dst_node, expected_len, ri[dst_node]);
                $fatal;
            end

            // Check payload
            for (k = 0; k < expected_len; k = k + 1) begin
                if (rx_payload_mem[dst_node][k] !== (base_data + k)) begin
                    $error("FAIL Node %0d payload[%0d]: expected 32'h%8h, got 32'h%8h",
                           dst_node, k, base_data + k, rx_payload_mem[dst_node][k]);
                    $fatal;
                end
            end

            // Check frame count
            if (received_frame_count[dst_node] !== expect_count) begin
                $error("FAIL Node %0d: expected %0d frames, got %0d",
                       dst_node, expect_count, received_frame_count[dst_node]);
                $fatal;
            end

            $display("  OK: Node %0d received frame from Node %0d, len=%0d, payload correct",
                     dst_node, expected_src, expected_len);
        end
    endtask

    //--------------------------------------------------------------------------
    // Global expected_counts_g array (iverilog does not support array task ports)
    //--------------------------------------------------------------------------
    integer expected_counts_g [0:NUM_NODES-1];

    //--------------------------------------------------------------------------
    // Check that a broadcast was received by all nodes except the source
    //--------------------------------------------------------------------------
    task check_broadcast_received;
        input integer src_node;
        input [7:0] expected_src;
        input integer expected_len;
        input [31:0] base_data;
        integer n, k;
        begin
            for (n = 0; n < NUM_NODES; n = n + 1) begin
                if (n == src_node) begin
                    if (received_frame_count[n] !== expected_counts_g[n]) begin
                        $display("FAIL Node %0d (source): expected %0d frames, got %0d",
                               n, expected_counts_g[n], received_frame_count[n]);
                        $fatal;
                    end
                end else begin
                    if (received_frame_count[n] !== expected_counts_g[n]) begin
                        $display("FAIL Node %0d: expected %0d frames, got %0d",
                               n, expected_counts_g[n], received_frame_count[n]);
                        $fatal;
                    end
                end
            end
            $display("  OK: Broadcast from Node %0d received by all %0d other nodes",
                     src_node, NUM_NODES - 1);
        end
    endtask

    //--------------------------------------------------------------------------
    // Check no unexpected frames at non-target nodes
    //--------------------------------------------------------------------------
    task check_no_unexpected_frames;
        input integer src_node;
        input integer dst_node;
        integer n;
        begin
            for (n = 0; n < NUM_NODES; n = n + 1) begin
                if (n == dst_node || (dst_node == BROADCAST && n != src_node)) begin
                    // Target nodes OK
                end else if (received_frame_count[n] !== expected_counts_g[n]) begin
                    $display("FAIL Node %0d (non-target): expected %0d frames, got %0d",
                           n, expected_counts_g[n], received_frame_count[n]);
                    $fatal;
                end
            end
            $display("  OK: Non-target nodes did not receive unexpected frames");
        end
    endtask

    //--------------------------------------------------------------------------
    // Main test sequence
    //--------------------------------------------------------------------------
    integer test_frames_before;
    integer n;
    integer test1_timed_out;

    initial begin
        // Initialize
        clk = 0;
        rst = 1;
        for (n = 0; n < NUM_NODES; n = n + 1) begin
            node_id_valid[n] = 1'b0;
            node_id[n] = 8'd0;
            app_frame_valid[n] = 1'b0;
            app_dst_id[n] = 8'd0;
            app_len16[n] = 16'd0;
            app_rx_frame_ready[n] = 1'b1;   // always ready
            app_rx_payload_ready[n] = 1'b1; // always ready
            received_frame_count[n] = 0;
        end
        test1_debug_active = 1'b0;
        test2_debug_active = 1'b0;
        test2_debug_cycles = 0;
        test2_dedup_issue = 1'b0;
        test2_consumed_before_payload_done = 1'b0;
        test2_payload_read_zero = 1'b0;
        test2_queue_write_zero = 1'b0;
        test2_queue_payload_ok = 1'b0;
        test2_len_mismatch_after_good_forward = 1'b0;
        for (n = 0; n < NUM_NODES; n = n + 1) begin
            test2_forward_req_5_0_count[n] = 0;
            test2_forward_req_5_0_dup0_count[n] = 0;
            test2_max_payload_idx[n] = 16'd0;
            test2_payload_seen[n][0] = 32'd0;
            test2_payload_seen[n][1] = 32'd0;
            test2_payload_seen[n][2] = 32'd0;
            test2_queue_seen[n][0] = 32'd0;
            test2_queue_seen[n][1] = 32'd0;
            test2_queue_seen[n][2] = 32'd0;
        end

        // Reset sequence
        repeat (20) @(posedge clk);
        rst = 1'b0;
        @(posedge clk);

        // Assign node IDs
        assign_node_ids();

        // Capture baseline frame counts (may include liveness frames)
        @(posedge clk);
        for (n = 0; n < NUM_NODES; n = n + 1)
            test_frames_before = test_frames_before + received_frame_count[n];

        $display("============================================================");
        $display(" TEST 1: Unicast cross-ring (Node0 -> Node4)");
        $display("============================================================");
        test1_debug_active = 1'b1;

        // Record baseline counts
        for (n = 0; n < NUM_NODES; n = n + 1)
            expected_counts_g[n] = received_frame_count[n];

        seen_node1_in1_sync = 1'b0;
        seen_node7_in0_sync = 1'b0;
        seen_node1_frame_ready = 1'b0;
        seen_node7_frame_ready = 1'b0;
        seen_node1_forward_req = 1'b0;
        seen_node7_forward_req = 1'b0;
        seen_node1_valid_out = 1'b0;
        seen_node7_valid_out = 1'b0;
        node4_frame_ready = 1'b0;
        node4_app_rx_frame_valid = 1'b0;
        src0_id_locked = 1'b0;
        src0_app_frame_ready = 1'b0;
        src0_app_frame_accepted = 1'b0;
        src0_app_frame_done = 1'b0;
        src0_network_congested = 1'b0;
        src0_app_len_error = 1'b0;
        src0_local_req = 1'b0;
        src0_local_accept = 1'b0;
        src0_local_app_done = 1'b0;
        src0_q_wr = 1'b0;
        src0_txwr = 1'b0;
        src0_valid_out = 1'b0;
        src0_enq_st_last = 3'd0;
        src0_q_din0_last = 34'd0;
        src0_q_din1_last = 34'd0;
        src0_tx_din0_last = 32'd0;
        src0_tx_din1_last = 32'd0;
        src0_out0_last = 32'd0;
        src0_out1_last = 32'd0;
        node1_link_seq_idx = 0;
        node7_link_seq_idx = 0;
        node1_rx_seq_idx = 0;
        node7_rx_seq_idx = 0;
        node1_link_sync_count = 0;
        node7_link_sync_count = 0;
        node1_rx_sync_count = 0;
        node7_rx_sync_count = 0;
        node0_enq_port0_seq_idx = 0;
        node0_enq_port1_seq_idx = 0;
        node0_q_port0_seq_idx = 0;
        node0_q_port1_seq_idx = 0;
        node0_txwr_port0_seq_idx = 0;
        node0_txwr_port1_seq_idx = 0;
        node0_txfifo_port0_seq_idx = 0;
        node0_txfifo_port1_seq_idx = 0;
        node0_out_port0_seq_idx = 0;
        node0_out_port1_seq_idx = 0;
        for (n = 0; n < 8; n = n + 1) begin
            node1_link_first_words[n] = 32'd0;
            node7_link_first_words[n] = 32'd0;
            node1_rx_first_words[n] = 32'd0;
            node7_rx_first_words[n] = 32'd0;
            node0_enq_port0_first_words[n] = 32'd0;
            node0_enq_port1_first_words[n] = 32'd0;
            node0_q_port0_first_words[n] = 32'd0;
            node0_q_port1_first_words[n] = 32'd0;
            node0_txwr_port0_first_words[n] = 32'd0;
            node0_txwr_port1_first_words[n] = 32'd0;
            node0_txfifo_port0_first_words[n] = 32'd0;
            node0_txfifo_port1_first_words[n] = 32'd0;
            node0_out_port0_first_words[n] = 32'd0;
            node0_out_port1_first_words[n] = 32'd0;
        end

        send_app_frame(0, 8'd4, 4, 32'hA000_0000);
        expected_counts_g[4] = expected_counts_g[4] + 1;

        // Debug: check TX path activity after send_frame
        if (ENABLE_VERBOSE_DEBUG && ENABLE_TEST1_DEBUG) begin
            $display("  DEBUG: send_app_frame completed at time %0t", $time);
            $display("  DEBUG: node0 app_frame_done=%0d network_congested=%0d",
                     app_frame_done[0], network_congested[0]);
        end
        repeat (50) @(posedge clk);
        if (ENABLE_VERBOSE_DEBUG && ENABLE_TEST1_DEBUG) begin
            $display("  DEBUG after 50 cycles: node0 out0=%0h v0=%0d out1=%0h v1=%0d",
                     out0[0], valid_out0[0], out1[0], valid_out1[0]);
            $display("  DEBUG: all valid_outs: %0d%0d%0d%0d%0d%0d%0d%0d",
                     valid_out0[0],valid_out0[1],valid_out0[2],valid_out0[3],
                     valid_out0[4],valid_out0[5],valid_out0[6],valid_out0[7]);
        end

        wait_for_rx_frames_no_fatal(4, expected_counts_g[4], TIMEOUT_CYCLES, test1_timed_out);

        // Debug: show received frame counts
        if (ENABLE_VERBOSE_DEBUG && ENABLE_TEST1_DEBUG) begin
            for (n = 0; n < NUM_NODES; n = n + 1)
                $display("  DEBUG Node %0d: received_frame_count=%0d last_rx_src=%0d last_rx_dst=%0d",
                         n, received_frame_count[n], last_rx_src[n], last_rx_dst[n]);
        end

        if (test1_timed_out) begin
            $display("Node4 δ�յ��κ� app_rx ֡");
            print_test1_diagnostic();
            $fatal(1, "TEST 1 failed before checking last_rx fields");
        end

        check_unicast_received(4, 8'd0, 8'd4, 4, 32'hA000_0000, expected_counts_g[4]);
        check_no_unexpected_frames(0, 4);
        test1_debug_active = 1'b0;
        wait_network_idle(10000);

        $display("============================================================");
        $display(" TEST 2: Reverse unicast (Node5 -> Node1)");
        $display("============================================================");

        for (n = 0; n < NUM_NODES; n = n + 1)
            expected_counts_g[n] = received_frame_count[n];

        test2_debug_active = 1'b0;
        test2_debug_cycles = 0;
        test2_dedup_issue = 1'b0;
        test2_consumed_before_payload_done = 1'b0;
        test2_payload_read_zero = 1'b0;
        test2_queue_write_zero = 1'b0;
        test2_queue_payload_ok = 1'b0;
        test2_len_mismatch_after_good_forward = 1'b0;
        for (n = 0; n < NUM_NODES; n = n + 1) begin
            test2_forward_req_5_0_count[n] = 0;
            test2_forward_req_5_0_dup0_count[n] = 0;
            test2_max_payload_idx[n] = 16'd0;
            test2_payload_seen[n][0] = 32'd0;
            test2_payload_seen[n][1] = 32'd0;
            test2_payload_seen[n][2] = 32'd0;
            test2_queue_seen[n][0] = 32'd0;
            test2_queue_seen[n][1] = 32'd0;
            test2_queue_seen[n][2] = 32'd0;
        end
        test2_debug_active = 1'b1;
        send_app_frame(5, 8'd1, 3, 32'hB000_0000);

        expected_counts_g[1] = expected_counts_g[1] + 1;
        wait_for_rx_frames(1, expected_counts_g[1], TIMEOUT_CYCLES);
        wait_network_idle(1000);
        check_unicast_received(1, 8'd5, 8'd1, 3, 32'hB000_0000, expected_counts_g[1]);
        check_no_unexpected_frames(5, 1);
        if (ENABLE_VERBOSE_DEBUG && ENABLE_TEST2_DEBUG)
            print_test2_diagnostic();
        test2_debug_active = 1'b0;

        $display("============================================================");
        $display(" TEST 3: Broadcast data (Node2 -> all others)");
        $display("============================================================");

        for (n = 0; n < NUM_NODES; n = n + 1)
            expected_counts_g[n] = received_frame_count[n];
        for (n = 0; n < NUM_NODES; n = n + 1)
            if (n != 2)
                expected_counts_g[n] = expected_counts_g[n] + 1;

        send_app_frame(2, BROADCAST, 2, 32'hC000_0000);
        wait_network_idle(TIMEOUT_CYCLES);
        // Extra wait for broadcast to propagate fully
        repeat (2000) @(posedge clk);

        check_broadcast_received(2, 8'd2, 2, 32'hC000_0000);

        $display("============================================================");
        $display(" TEST 4: Continuous small packets (Node0 -> Node3, 5 packets)");
        $display("============================================================");

        for (n = 0; n < NUM_NODES; n = n + 1)
            expected_counts_g[n] = received_frame_count[n];
        expected_counts_g[3] = expected_counts_g[3] + 5;

        for (n = 0; n < 5; n = n + 1) begin
            send_app_frame(0, 8'd3, 1, 32'hD000_0000 + n);
        end
        wait_network_idle(TIMEOUT_CYCLES);
        repeat (3000) @(posedge clk);

        if (received_frame_count[3] !== expected_counts_g[3]) begin
            $error("FAIL Node 3: expected %0d frames, got %0d",
                   expected_counts_g[3], received_frame_count[3]);
            $fatal;
        end
        $display("  OK: Node 3 received 5 small packets from Node 0");

        $display("============================================================");
        $display(" TEST 5: Max payload (Node6 -> Node7, len=256)");
        $display("============================================================");

        for (n = 0; n < NUM_NODES; n = n + 1)
            expected_counts_g[n] = received_frame_count[n];

        send_app_frame(6, 8'd7, MAX_PAYLOAD, 32'hE000_0000);
        wait_network_idle(TIMEOUT_CYCLES);
        repeat (5000) @(posedge clk);

        expected_counts_g[7] = expected_counts_g[7] + 1;
        check_unicast_received(7, 8'd6, 8'd7, MAX_PAYLOAD, 32'hE000_0000, expected_counts_g[7]);

        // Check no RX overflow
        for (n = 0; n < NUM_NODES; n = n + 1) begin
            if (rx_overflow[n]) begin
                $display("WARNING: Node %0d rx_overflow asserted", n);
            end
        end

        // Check no app_len_error after tests
        for (n = 0; n < NUM_NODES; n = n + 1) begin
            if (app_len_error[n]) begin
                $display("WARNING: Node %0d app_len_error asserted", n);
            end
        end

        $display("============================================================");
        $display(" ALL TESTS PASSED");
        $display(" 8-node ring network basic communication works");
        $display("============================================================");
        $finish;
    end
    always @(posedge clk) begin
    if (ENABLE_VERBOSE_DEBUG && ENABLE_TEST1_DEBUG && test1_debug_active &&
        (g_node[0].u_node.u_node_core.tx_frame_queue_wr_en != 0 ||
        g_node[0].u_node.u_node_core.tx_frame_meta_wr_en != 0 ||
        g_node[0].u_node.u_node_core.tx_wr_en != 0 ||
        valid_out0[0] || valid_out1[0])) begin

        $display("TXDBG t=%0t q_wr=%b meta_wr=%b q_empty=%b meta_empty=%b q_rd=%b meta_rd=%b tx_wr=%b tx_full=%b tx_empty=%b vout=%b%b",
            $time,
            g_node[0].u_node.u_node_core.tx_frame_queue_wr_en,
            g_node[0].u_node.u_node_core.tx_frame_meta_wr_en,
            g_node[0].u_node.u_node_core.tx_frame_queue_empty,
            g_node[0].u_node.u_node_core.tx_frame_meta_empty,
            g_node[0].u_node.u_node_core.tx_frame_queue_rd_en,
            g_node[0].u_node.u_node_core.tx_frame_meta_rd_en,
            g_node[0].u_node.u_node_core.tx_wr_en,
            g_node[0].u_node.u_node_core.tx_full,
            g_node[0].u_node.u_node_core.tx_empty,
            valid_out0[0],
            valid_out1[0]
        );
    end
end
endmodule
