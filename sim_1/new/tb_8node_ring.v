`timescale 1ns / 1ps

//------------------------------------------------------------------------------
// tb_8node_ring: 8-node bidirectional ring network testbench
//   Instantiates 8 node_top modules connected in a ring topology.
//   Tests unicast, broadcast, continuous small packets, and max payload.
//------------------------------------------------------------------------------
module tb_8node_ring;

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
                    end
                end
            end
        end
    endgenerate

    // Monitor: print when any valid_out goes high
    always @(posedge clk) begin
        for (integer mi = 0; mi < NUM_NODES; mi = mi + 1) begin
            if (valid_out0[mi] || valid_out1[mi])
                $display("  MONITOR time=%0t: node%0d vout0=%0d vout1=%0d",
                         $time, mi, valid_out0[mi], valid_out1[mi]);
        end
    end

    // Node0 TX-side sequence debug for Test 1.
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
        end else begin
            if (g_node[0].u_node.u_node_core.tx_frame_queue_wr_en[0]) begin
                $display("ENQSEQ node=0 port=0 idx=%0d sof=%0d eof=%0d data=%08h",
                         node0_enq_port0_seq_idx,
                         g_node[0].u_node.u_node_core.tx_frame_queue_din_flat[0*34 + 33],
                         g_node[0].u_node.u_node_core.tx_frame_queue_din_flat[0*34 + 32],
                         g_node[0].u_node.u_node_core.tx_frame_queue_din_flat[0*34 +: 32]);
                if (node0_enq_port0_seq_idx < 8)
                    node0_enq_port0_first_words[node0_enq_port0_seq_idx] <=
                        g_node[0].u_node.u_node_core.tx_frame_queue_din_flat[0*34 +: 32];
                node0_enq_port0_seq_idx <= node0_enq_port0_seq_idx + 1;
            end
            if (g_node[0].u_node.u_node_core.tx_frame_queue_wr_en[1]) begin
                $display("ENQSEQ node=0 port=1 idx=%0d sof=%0d eof=%0d data=%08h",
                         node0_enq_port1_seq_idx,
                         g_node[0].u_node.u_node_core.tx_frame_queue_din_flat[1*34 + 33],
                         g_node[0].u_node.u_node_core.tx_frame_queue_din_flat[1*34 + 32],
                         g_node[0].u_node.u_node_core.tx_frame_queue_din_flat[1*34 +: 32]);
                if (node0_enq_port1_seq_idx < 8)
                    node0_enq_port1_first_words[node0_enq_port1_seq_idx] <=
                        g_node[0].u_node.u_node_core.tx_frame_queue_din_flat[1*34 +: 32];
                node0_enq_port1_seq_idx <= node0_enq_port1_seq_idx + 1;
            end

            if (g_node[0].u_node.u_node_core.tx_frame_queue_rd_en[0]) begin
                $display("QSEQ node=0 port=0 idx=%0d sof=%0d eof=%0d data=%08h",
                         node0_q_port0_seq_idx,
                         g_node[0].u_node.u_node_core.tx_frame_queue_dout_flat[0*34 + 33],
                         g_node[0].u_node.u_node_core.tx_frame_queue_dout_flat[0*34 + 32],
                         g_node[0].u_node.u_node_core.tx_frame_queue_dout_flat[0*34 +: 32]);
                if (node0_q_port0_seq_idx < 8)
                    node0_q_port0_first_words[node0_q_port0_seq_idx] <=
                        g_node[0].u_node.u_node_core.tx_frame_queue_dout_flat[0*34 +: 32];
                node0_q_port0_seq_idx <= node0_q_port0_seq_idx + 1;
            end
            if (g_node[0].u_node.u_node_core.tx_frame_queue_rd_en[1]) begin
                $display("QSEQ node=0 port=1 idx=%0d sof=%0d eof=%0d data=%08h",
                         node0_q_port1_seq_idx,
                         g_node[0].u_node.u_node_core.tx_frame_queue_dout_flat[1*34 + 33],
                         g_node[0].u_node.u_node_core.tx_frame_queue_dout_flat[1*34 + 32],
                         g_node[0].u_node.u_node_core.tx_frame_queue_dout_flat[1*34 +: 32]);
                if (node0_q_port1_seq_idx < 8)
                    node0_q_port1_first_words[node0_q_port1_seq_idx] <=
                        g_node[0].u_node.u_node_core.tx_frame_queue_dout_flat[1*34 +: 32];
                node0_q_port1_seq_idx <= node0_q_port1_seq_idx + 1;
            end

            if (g_node[0].u_node.u_node_core.tx_wr_en[0]) begin
                $display("TXWRSEQ node=0 port=0 idx=%0d data=%08h",
                         node0_txwr_port0_seq_idx,
                         g_node[0].u_node.u_node_core.tx_din_flat[0*32 +: 32]);
                if (node0_txwr_port0_seq_idx < 8)
                    node0_txwr_port0_first_words[node0_txwr_port0_seq_idx] <=
                        g_node[0].u_node.u_node_core.tx_din_flat[0*32 +: 32];
                node0_txwr_port0_seq_idx <= node0_txwr_port0_seq_idx + 1;
            end
            if (g_node[0].u_node.u_node_core.tx_wr_en[1]) begin
                $display("TXWRSEQ node=0 port=1 idx=%0d data=%08h",
                         node0_txwr_port1_seq_idx,
                         g_node[0].u_node.u_node_core.tx_din_flat[1*32 +: 32]);
                if (node0_txwr_port1_seq_idx < 8)
                    node0_txwr_port1_first_words[node0_txwr_port1_seq_idx] <=
                        g_node[0].u_node.u_node_core.tx_din_flat[1*32 +: 32];
                node0_txwr_port1_seq_idx <= node0_txwr_port1_seq_idx + 1;
            end

            if (!g_node[0].u_node.u_node_core.tx_empty[0]) begin
                $display("TXFIFOSEQ node=0 port=0 idx=%0d data=%08h",
                         node0_txfifo_port0_seq_idx,
                         g_node[0].u_node.u_node_core.tx_dout_flat[0*32 +: 32]);
                if (node0_txfifo_port0_seq_idx < 8)
                    node0_txfifo_port0_first_words[node0_txfifo_port0_seq_idx] <=
                        g_node[0].u_node.u_node_core.tx_dout_flat[0*32 +: 32];
                node0_txfifo_port0_seq_idx <= node0_txfifo_port0_seq_idx + 1;
            end
            if (!g_node[0].u_node.u_node_core.tx_empty[1]) begin
                $display("TXFIFOSEQ node=0 port=1 idx=%0d data=%08h",
                         node0_txfifo_port1_seq_idx,
                         g_node[0].u_node.u_node_core.tx_dout_flat[1*32 +: 32]);
                if (node0_txfifo_port1_seq_idx < 8)
                    node0_txfifo_port1_first_words[node0_txfifo_port1_seq_idx] <=
                        g_node[0].u_node.u_node_core.tx_dout_flat[1*32 +: 32];
                node0_txfifo_port1_seq_idx <= node0_txfifo_port1_seq_idx + 1;
            end

            if (valid_out0[0]) begin
                $display("OUTSEQ node=0 port=0 idx=%0d data=%08h",
                         node0_out_port0_seq_idx, out0[0]);
                if (node0_out_port0_seq_idx < 8)
                    node0_out_port0_first_words[node0_out_port0_seq_idx] <= out0[0];
                node0_out_port0_seq_idx <= node0_out_port0_seq_idx + 1;
            end
            if (valid_out1[0]) begin
                $display("OUTSEQ node=0 port=1 idx=%0d data=%08h",
                         node0_out_port1_seq_idx, out1[0]);
                if (node0_out_port1_seq_idx < 8)
                    node0_out_port1_first_words[node0_out_port1_seq_idx] <= out1[0];
                node0_out_port1_seq_idx <= node0_out_port1_seq_idx + 1;
            end
        end
    end

    // First-hop link debug for Test 1:
    // Node0.out0 -> Node1.in1, Node0.out1 -> Node7.in0.
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
        end else begin
            if (valid_in1[1]) begin
                $display("LINKSEQ node=1 port=1 idx=%0d data=%08h", node1_link_seq_idx, in1[1]);
                $display("LINKDBG time=%0t node=1 port=1 data=%08h", $time, in1[1]);
                if (node1_link_seq_idx < 8)
                    node1_link_first_words[node1_link_seq_idx] <= in1[1];
                if (in1[1] == 32'hA31E57BD) begin
                    seen_node1_in1_sync <= 1'b1;
                    node1_link_sync_count <= node1_link_sync_count + 1;
                end
                node1_link_seq_idx <= node1_link_seq_idx + 1;
            end
            if (valid_in0[7]) begin
                $display("LINKSEQ node=7 port=0 idx=%0d data=%08h", node7_link_seq_idx, in0[7]);
                $display("LINKDBG time=%0t node=7 port=0 data=%08h", $time, in0[7]);
                if (node7_link_seq_idx < 8)
                    node7_link_first_words[node7_link_seq_idx] <= in0[7];
                if (in0[7] == 32'hA31E57BD) begin
                    seen_node7_in0_sync <= 1'b1;
                    node7_link_sync_count <= node7_link_sync_count + 1;
                end
                node7_link_seq_idx <= node7_link_seq_idx + 1;
            end
        end
    end

    // RX FIFO / frame_rx debug on first-hop receivers.
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
        end else begin
            if (g_node[1].u_node.u_node_core.rx_rd_en[1]) begin
                $display("RXSEQ node=1 port=1 idx=%0d dout=%08h st=%0d",
                         node1_rx_seq_idx,
                         g_node[1].u_node.u_node_core.rx_dout_flat[1*32 +: 32],
                         g_node[1].u_node.u_node_core.g_rx[1].u_frame_rx.st);
                if (node1_rx_seq_idx < 8)
                    node1_rx_first_words[node1_rx_seq_idx] <= g_node[1].u_node.u_node_core.rx_dout_flat[1*32 +: 32];
                if (g_node[1].u_node.u_node_core.rx_dout_flat[1*32 +: 32] == 32'hA31E57BD)
                    node1_rx_sync_count <= node1_rx_sync_count + 1;
                node1_rx_seq_idx <= node1_rx_seq_idx + 1;
            end
            if (g_node[7].u_node.u_node_core.rx_rd_en[0]) begin
                $display("RXSEQ node=7 port=0 idx=%0d dout=%08h st=%0d",
                         node7_rx_seq_idx,
                         g_node[7].u_node.u_node_core.rx_dout_flat[0*32 +: 32],
                         g_node[7].u_node.u_node_core.g_rx[0].u_frame_rx.st);
                if (node7_rx_seq_idx < 8)
                    node7_rx_first_words[node7_rx_seq_idx] <= g_node[7].u_node.u_node_core.rx_dout_flat[0*32 +: 32];
                if (g_node[7].u_node.u_node_core.rx_dout_flat[0*32 +: 32] == 32'hA31E57BD)
                    node7_rx_sync_count <= node7_rx_sync_count + 1;
                node7_rx_seq_idx <= node7_rx_seq_idx + 1;
            end
            if (g_node[1].u_node.u_node_core.rx_rd_en[1] ||
                g_node[1].u_node.u_node_core.frame_ready[1] ||
                g_node[1].u_node.u_node_core.frame_consumed[1]) begin
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
            end
            if (g_node[7].u_node.u_node_core.rx_rd_en[0] ||
                g_node[7].u_node.u_node_core.frame_ready[0] ||
                g_node[7].u_node.u_node_core.frame_consumed[0]) begin
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

            if (g_node[1].u_node.u_node_core.frame_ready[1])
                seen_node1_frame_ready <= 1'b1;
            if (g_node[7].u_node.u_node_core.frame_ready[0])
                seen_node7_frame_ready <= 1'b1;
            if (|g_node[4].u_node.u_node_core.frame_ready)
                node4_frame_ready <= 1'b1;
            if (app_rx_frame_valid[4])
                node4_app_rx_frame_valid <= 1'b1;
        end
    end

    // Forwarding path debug on first-hop receivers.
    always @(posedge clk) begin
        if (rst) begin
            seen_node1_forward_req <= 1'b0;
            seen_node7_forward_req <= 1'b0;
            seen_node1_valid_out <= 1'b0;
            seen_node7_valid_out <= 1'b0;
        end else begin
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

            if (g_node[1].u_node.u_node_core.forward_req)
                seen_node1_forward_req <= 1'b1;
            if (g_node[7].u_node.u_node_core.forward_req)
                seen_node7_forward_req <= 1'b1;
            if (valid_out0[1] || valid_out1[1])
                seen_node1_valid_out <= 1'b1;
            if (valid_out0[7] || valid_out1[7])
                seen_node7_valid_out <= 1'b1;
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

            if (((node0_txwr_port0_first_words[0] == 32'hA31E57BD) &&
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
        begin
            cycles = 0;
            repeat (100) @(posedge clk); // let frames propagate initially
            while (cycles < timeout_cycles) begin
                @(posedge clk);
                cycles = cycles + 1;
            end
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
        $display("  DEBUG: send_app_frame completed at time %0t", $time);
        $display("  DEBUG: node0 app_frame_done=%0d network_congested=%0d",
                 app_frame_done[0], network_congested[0]);
        repeat (50) @(posedge clk);
        $display("  DEBUG after 50 cycles: node0 out0=%0h v0=%0d out1=%0h v1=%0d",
                 out0[0], valid_out0[0], out1[0], valid_out1[0]);
        $display("  DEBUG: all valid_outs: %0d%0d%0d%0d%0d%0d%0d%0d",
                 valid_out0[0],valid_out0[1],valid_out0[2],valid_out0[3],
                 valid_out0[4],valid_out0[5],valid_out0[6],valid_out0[7]);

        wait_for_rx_frames_no_fatal(4, expected_counts_g[4], TIMEOUT_CYCLES, test1_timed_out);

        // Debug: show received frame counts
        for (n = 0; n < NUM_NODES; n = n + 1)
            $display("  DEBUG Node %0d: received_frame_count=%0d last_rx_src=%0d last_rx_dst=%0d",
                     n, received_frame_count[n], last_rx_src[n], last_rx_dst[n]);

        if (test1_timed_out) begin
            $display("Node4 未收到任何 app_rx 帧");
            print_test1_diagnostic();
            $fatal(1, "TEST 1 failed before checking last_rx fields");
        end

        check_unicast_received(4, 8'd0, 8'd4, 4, 32'hA000_0000, expected_counts_g[4]);
        check_no_unexpected_frames(0, 4);

        $display("============================================================");
        $display(" TEST 2: Reverse unicast (Node5 -> Node1)");
        $display("============================================================");

        for (n = 0; n < NUM_NODES; n = n + 1)
            expected_counts_g[n] = received_frame_count[n];

        send_app_frame(5, 8'd1, 3, 32'hB000_0000);
        wait_network_idle(TIMEOUT_CYCLES);

        expected_counts_g[1] = expected_counts_g[1] + 1;
        check_unicast_received(1, 8'd5, 8'd1, 3, 32'hB000_0000, expected_counts_g[1]);
        check_no_unexpected_frames(5, 1);

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
    if (g_node[0].u_node.u_node_core.tx_frame_queue_wr_en != 0 ||
        g_node[0].u_node.u_node_core.tx_frame_meta_wr_en != 0 ||
        g_node[0].u_node.u_node_core.tx_wr_en != 0 ||
        valid_out0[0] || valid_out1[0]) begin

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
