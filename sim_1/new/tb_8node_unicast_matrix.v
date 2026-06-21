`timescale 1ns / 1ps

//------------------------------------------------------------------------------
// tb_8node_unicast_matrix: full 8x7 unicast matrix test for 8-node ring.
//   Each of the 8 src nodes sends a unicast frame to each of the other
//   7 dst nodes (56 total paths). Payload length rotates through
//   {1,2,3,4,7,16,64,256}. Each packet payload encodes src, dst, and
//   test_index for easy debug. Non-target nodes are verified to not receive
//   unexpected frames.
//------------------------------------------------------------------------------
module tb_8node_unicast_matrix;

    localparam NUM_NODES    = 8;
    localparam CLK_PERIOD   = 10;
    localparam SIM_CLK_FREQ = 500000000;
    localparam TIMEOUT_CYCLES = 500000;
    localparam BROADCAST    = 8'hFF;
    localparam MAX_PAYLOAD  = 256;

    //--------------------------------------------------------------------------
    // Clock and reset
    //--------------------------------------------------------------------------
    reg clk;
    reg rst;

    always #(CLK_PERIOD/2) clk = ~clk;

    initial begin
        #100_000_000;
        $display("GLOBAL TIMEOUT: simulation did not finish in 100 ms");
        $fatal(1);
    end

    //--------------------------------------------------------------------------
    // Per-node signals
    //--------------------------------------------------------------------------
    reg  [NUM_NODES-1:0] node_id_valid;
    reg  [7:0] node_id [0:NUM_NODES-1];

    wire [31:0] out0 [0:NUM_NODES-1];
    wire [31:0] out1 [0:NUM_NODES-1];
    wire        valid_out0 [0:NUM_NODES-1];
    wire        valid_out1 [0:NUM_NODES-1];

    reg  [31:0] link_data_cw  [0:NUM_NODES-1];
    reg         link_valid_cw [0:NUM_NODES-1];
    reg  [31:0] link_data_ccw [0:NUM_NODES-1];
    reg         link_valid_ccw [0:NUM_NODES-1];

    wire [31:0] in0 [0:NUM_NODES-1];
    wire [31:0] in1 [0:NUM_NODES-1];
    wire        valid_in0 [0:NUM_NODES-1];
    wire        valid_in1 [0:NUM_NODES-1];

    reg         app_frame_valid [0:NUM_NODES-1];
    wire        app_frame_ready [0:NUM_NODES-1];
    wire        app_frame_accepted [0:NUM_NODES-1];
    wire        app_frame_done [0:NUM_NODES-1];
    reg  [7:0]  app_dst_id [0:NUM_NODES-1];
    reg  [15:0] app_len16 [0:NUM_NODES-1];
    wire [15:0] app_payload_addr [0:NUM_NODES-1];
    wire [31:0] app_payload_data [0:NUM_NODES-1];

    wire        app_rx_frame_valid [0:NUM_NODES-1];
    reg         app_rx_frame_ready [0:NUM_NODES-1];
    wire [7:0]  app_rx_src_id [0:NUM_NODES-1];
    wire [7:0]  app_rx_dst_id [0:NUM_NODES-1];
    wire [15:0] app_rx_count [0:NUM_NODES-1];
    wire [15:0] app_rx_len16 [0:NUM_NODES-1];
    wire        app_rx_payload_valid [0:NUM_NODES-1];
    reg         app_rx_payload_ready [0:NUM_NODES-1];
    wire [15:0] app_rx_payload_addr [0:NUM_NODES-1];
    wire [31:0] app_rx_payload_data [0:NUM_NODES-1];

    wire        liveness_valid [0:NUM_NODES-1];
    wire [7:0]  liveness_node [0:NUM_NODES-1];
    wire        liveness_alive [0:NUM_NODES-1];
    wire        network_congested [0:NUM_NODES-1];
    wire        app_len_error [0:NUM_NODES-1];
    wire        rx_overflow [0:NUM_NODES-1];

    wire clk_w = clk;

    //--------------------------------------------------------------------------
    // Payload RAM model (combinational read)
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

    //--------------------------------------------------------------------------
    // Node instantiation (8 node_top modules)
    //--------------------------------------------------------------------------
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
            assign in1[gi2] = link_data_cw[(gi2 + NUM_NODES - 1) % NUM_NODES];
            assign valid_in1[gi2] = link_valid_cw[(gi2 + NUM_NODES - 1) % NUM_NODES];

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

    //--------------------------------------------------------------------------
    // Global expected_counts array (shared across checker tasks)
    //--------------------------------------------------------------------------
    integer expected_counts_g [0:NUM_NODES-1];

    //--------------------------------------------------------------------------
    // Tasks
    //--------------------------------------------------------------------------

    // ---- send_app_frame: send a unicast frame from the app side ----
    task send_app_frame;
        input integer src_node;
        input [7:0]  dst_id;
        input integer len;
        input [31:0] base_data;
        integer k;
        begin
            for (k = 0; k < len; k = k + 1)
                payload_mem[src_node][k] = base_data + k;

            app_dst_id[src_node] = dst_id;
            app_len16[src_node] = len;
            app_frame_valid[src_node] = 1'b1;

            while (!app_frame_ready[src_node] || !app_frame_valid[src_node])
                @(posedge clk);
            @(posedge clk);
            app_frame_valid[src_node] <= 1'b0;
            app_dst_id[src_node] <= 8'd0;
            app_len16[src_node] <= 16'd0;

            while (!app_frame_done[src_node])
                @(posedge clk);
            @(posedge clk);
        end
    endtask

    // ---- wait_for_rx_frames: block until node has target_count frames ----
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

    // ---- wait_network_idle: wait until ring is quiet ----
    task wait_network_idle;
        input integer timeout_cycles;
        integer cycles;
        integer n;
        integer idle_cycles;
        reg idle_now;
        begin
            cycles = 0;
            idle_cycles = 0;
            repeat (100) @(posedge clk);
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

    // ---- check_unicast_received: verify header, payload, and count ----
    task check_unicast_received;
        input integer dst_node;
        input [7:0]  expected_src;
        input [7:0]  expected_dst;
        input integer expected_len;
        input [31:0] base_data;
        input integer expect_count;
        integer k;
        integer cycles;
        begin
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

            for (k = 0; k < expected_len; k = k + 1) begin
                if (rx_payload_mem[dst_node][k] !== (base_data + k)) begin
                    $error("FAIL Node %0d payload[%0d]: expected 32'h%08h, got 32'h%08h",
                           dst_node, k, base_data + k, rx_payload_mem[dst_node][k]);
                    $fatal;
                end
            end

            if (received_frame_count[dst_node] !== expect_count) begin
                $error("FAIL Node %0d: expected %0d frames, got %0d",
                       dst_node, expect_count, received_frame_count[dst_node]);
                $fatal;
            end
        end
    endtask

    // ---- check_no_unexpected_frames: non-target nodes must not gain frames ----
    task check_no_unexpected_frames;
        input integer src_node;
        input integer dst_node;
        integer n;
        begin
            for (n = 0; n < NUM_NODES; n = n + 1) begin
                if (n == dst_node) begin
                end else if (received_frame_count[n] !== expected_counts_g[n]) begin
                    $error("FAIL Node %0d (non-target): expected %0d frames, got %0d",
                           n, expected_counts_g[n], received_frame_count[n]);
                    $fatal;
                end
            end
        end
    endtask

    //--------------------------------------------------------------------------
    // Main test sequence
    //--------------------------------------------------------------------------
    integer src;
    integer dst;
    integer test_index;
    integer payload_len;
    integer n;
    integer pass_count;
    integer fail_count;
    integer base_data;

    // Payload length rotation pattern
    integer len_rot [0:7];

    initial begin
        len_rot[0] = 1;
        len_rot[1] = 2;
        len_rot[2] = 3;
        len_rot[3] = 4;
        len_rot[4] = 7;
        len_rot[5] = 16;
        len_rot[6] = 64;
        len_rot[7] = 256;

        clk = 0;
        rst = 1;
        for (n = 0; n < NUM_NODES; n = n + 1) begin
            node_id_valid[n] = 1'b0;
            node_id[n] = 8'd0;
            app_frame_valid[n] = 1'b0;
            app_dst_id[n] = 8'd0;
            app_len16[n] = 16'd0;
            app_rx_frame_ready[n] = 1'b1;
            app_rx_payload_ready[n] = 1'b1;
        end

        repeat (20) @(posedge clk);
        rst = 1'b0;
        @(posedge clk);

        //------------------------------------------------------------------
        // Initialize all 8 nodes with sequential IDs
        //------------------------------------------------------------------
        $display("============================================================");
        $display(" 8-NODE UNICAST MATRIX TEST: 56 paths (8 src x 7 dst)");
        $display("============================================================");
        $display(" Initializing all 8 nodes...");

        for (n = 0; n < NUM_NODES; n = n + 1) begin
            node_id[n] = n[7:0];
            node_id_valid[n] = 1'b1;
        end
        @(posedge clk);
        for (n = 0; n < NUM_NODES; n = n + 1)
            node_id_valid[n] <= 1'b0;
        @(posedge clk);

        repeat (20) @(posedge clk);
        $display(" All nodes initialized.");
        $display("============================================================");

        pass_count = 0;
        fail_count = 0;
        test_index = 0;

        for (src = 0; src < NUM_NODES; src = src + 1) begin
            for (dst = 0; dst < NUM_NODES; dst = dst + 1) begin
                if (src == dst) begin
                    // skip self-send
                end else begin
                    payload_len = len_rot[test_index % 8];

                    // base_data encodes src, dst, and test_index for debug
                    base_data = 32'h1000_0000 +
                                (src[7:0] << 16) +
                                (dst[7:0] << 8) +
                                test_index[7:0];

                    // Snapshot baseline counts
                    for (n = 0; n < NUM_NODES; n = n + 1)
                        expected_counts_g[n] = received_frame_count[n];
                    expected_counts_g[dst] = expected_counts_g[dst] + 1;

                    // Send frame
                    send_app_frame(src, dst[7:0], payload_len, base_data);

                    // Wait for destination to receive
                    wait_for_rx_frames(dst, expected_counts_g[dst], TIMEOUT_CYCLES);

                    // Verify payload content
                    check_unicast_received(dst, src[7:0], dst[7:0],
                                           payload_len, base_data,
                                           expected_counts_g[dst]);

                    // Verify non-target nodes got nothing new
                    check_no_unexpected_frames(src, dst);

                    // Wait for network to drain before next packet
                    wait_network_idle(10000);

                    $display("  PASS [%0d/56] Node%0d -> Node%0d  len=%0d",
                             test_index + 1, src, dst, payload_len);
                    pass_count = pass_count + 1;

                    test_index = test_index + 1;
                end
            end
        end

        //------------------------------------------------------------------
        // Final health checks
        //------------------------------------------------------------------
        $display("============================================================");
        $display(" Final health checks");

        for (n = 0; n < NUM_NODES; n = n + 1) begin
            if (rx_overflow[n])
                $display("WARNING: Node %0d rx_overflow asserted", n);
            if (app_len_error[n])
                $display("WARNING: Node %0d app_len_error asserted", n);
        end

        // Each node should have received exactly 7 frames (from the other 7)
        for (n = 0; n < NUM_NODES; n = n + 1) begin
            if (received_frame_count[n] < 7) begin
                $display("WARNING: Node %0d received only %0d frames (expected >= 7)",
                         n, received_frame_count[n]);
            end
        end

        //------------------------------------------------------------------
        // Final result
        //------------------------------------------------------------------
        if (pass_count == 56) begin
            $display("============================================================");
            $display(" ALL UNICAST MATRIX TESTS PASSED  (%0d/56)", pass_count);
            $display("============================================================");
        end else begin
            $display("============================================================");
            $display(" UNICAST MATRIX FAILED: %0d passed, %0d failed", pass_count, 56 - pass_count);
            $display("============================================================");
            $fatal;
        end

        $finish;
    end

endmodule
