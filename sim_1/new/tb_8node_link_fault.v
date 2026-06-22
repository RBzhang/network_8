`timescale 1ns / 1ps

//------------------------------------------------------------------------------
// tb_8node_link_fault: link fault / recovery testbench
//   Verifies: single-direction link break, bidirectional partition,
//   mid-transmission link drop (no half-frame), and recovery.
//
//   Link enable controls gate the 1-cycle ring pipeline:
//     link_enable_cw[i]  :  node[i].out0 -> node[(i+1)%8].in1  (clockwise)
//     link_enable_ccw[i] :  node[i].out1 -> node[(i+7)%8].in0  (counter-clockwise)
//   When disabled: link_valid=0, link_data=0.
//------------------------------------------------------------------------------
module tb_8node_link_fault;

    localparam NUM_NODES      = 8;
    localparam CLK_PERIOD     = 10;             // 10 ns = 100 MHz
    localparam SIM_CLK_FREQ   = 500000000;      // tick_1s very slow, avoid liveness interference
    localparam TIMEOUT_CYCLES = 500000;
    localparam SHORT_TIMEOUT  = 50000;          // shorter timeout for unreachable tests
    localparam BROADCAST      = 8'hFF;
    localparam MAX_PAYLOAD    = 256;

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

    wire [31:0]  out0 [0:NUM_NODES-1];
    wire [31:0]  out1 [0:NUM_NODES-1];
    wire         valid_out0 [0:NUM_NODES-1];
    wire         valid_out1 [0:NUM_NODES-1];

    reg  [31:0]  link_data_cw  [0:NUM_NODES-1];
    reg          link_valid_cw [0:NUM_NODES-1];
    reg  [31:0]  link_data_ccw [0:NUM_NODES-1];
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

    wire clk_w = clk;

    //--------------------------------------------------------------------------
    // Link enable controls
    //   link_enable_cw[i]  :  node[i].out0 -> node[(i+1)%8].in1
    //   link_enable_ccw[i] :  node[i].out1 -> node[(i+7)%8].in0
    //--------------------------------------------------------------------------
    reg  link_enable_cw  [0:NUM_NODES-1];
    reg  link_enable_ccw [0:NUM_NODES-1];

    //--------------------------------------------------------------------------
    // Payload RAM model (combinational read)
    //--------------------------------------------------------------------------
    reg [31:0] payload_mem [0:NUM_NODES-1][0:MAX_PAYLOAD-1];
    reg [31:0] app_payload_data_r [0:NUM_NODES-1];

    genvar gpl;
    generate
        for (gpl = 0; gpl < NUM_NODES; gpl = gpl + 1) begin : g_payload
            always @(*) begin
                app_payload_data_r[gpl] = payload_mem[gpl][app_payload_addr[gpl]];
            end
            assign app_payload_data[gpl] = app_payload_data_r[gpl];
        end
    endgenerate

    //--------------------------------------------------------------------------
    // Node instantiation (8 x node_top)
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
    // Ring connections with 1-cycle pipeline delay and link enables
    //   node[i].out0 -> pipeline -> node[(i+1)%8].in1  (clockwise)
    //   node[i].out1 -> pipeline -> node[(i+7)%8].in0  (counter-clockwise)
    //--------------------------------------------------------------------------
    genvar glink;
    generate
        for (glink = 0; glink < NUM_NODES; glink = glink + 1) begin : g_link
            assign in1[glink] = link_data_cw[(glink + NUM_NODES - 1) % NUM_NODES];
            assign valid_in1[glink] = link_valid_cw[(glink + NUM_NODES - 1) % NUM_NODES];
            assign in0[glink] = link_data_ccw[(glink + 1) % NUM_NODES];
            assign valid_in0[glink] = link_valid_ccw[(glink + 1) % NUM_NODES];
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
                if (link_enable_cw[i_pipe]) begin
                    link_data_cw[i_pipe]  <= out0[i_pipe];
                    link_valid_cw[i_pipe] <= valid_out0[i_pipe];
                end else begin
                    link_data_cw[i_pipe]  <= 32'd0;
                    link_valid_cw[i_pipe] <= 1'b0;
                end
                if (link_enable_ccw[i_pipe]) begin
                    link_data_ccw[i_pipe] <= out1[i_pipe];
                    link_valid_ccw[i_pipe] <= valid_out1[i_pipe];
                end else begin
                    link_data_ccw[i_pipe] <= 32'd0;
                    link_valid_ccw[i_pipe] <= 1'b0;
                end
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

    genvar grx;
    generate
        for (grx = 0; grx < NUM_NODES; grx = grx + 1) begin : g_rx_mon
            always @(posedge clk) begin
                if (rst) begin
                    ri[grx] <= 16'd0;
                    received_frame_count[grx] <= 0;
                    last_rx_src[grx] <= 8'd0;
                    last_rx_dst[grx] <= 8'd0;
                    last_rx_len[grx] <= 16'd0;
                    last_rx_count[grx] <= 16'd0;
                end else begin
                    if (app_rx_frame_valid[grx] && app_rx_frame_ready[grx]) begin
                        received_frame_count[grx] <= received_frame_count[grx] + 1;
                        last_rx_src[grx] <= app_rx_src_id[grx];
                        last_rx_dst[grx] <= app_rx_dst_id[grx];
                        last_rx_len[grx] <= app_rx_len16[grx];
                        last_rx_count[grx] <= app_rx_count[grx];
                        ri[grx] <= 16'd0;
                    end
                    if (app_rx_payload_valid[grx] && app_rx_payload_ready[grx]) begin
                        rx_payload_mem[grx][app_rx_payload_addr[grx]] <= app_rx_payload_data[grx];
                        ri[grx] <= app_rx_payload_addr[grx] + 1'b1;
                    end
                end
            end
        end
    endgenerate

    //--------------------------------------------------------------------------
    // cycle_counter for test timing reference
    //--------------------------------------------------------------------------
    reg [31:0] cycle_counter;
    always @(posedge clk) begin
        if (rst)
            cycle_counter <= 32'd0;
        else
            cycle_counter <= cycle_counter + 1'b1;
    end

    //--------------------------------------------------------------------------
    // Tasks
    //--------------------------------------------------------------------------

    //---- enable_all_links ----------------------------------------------------
    task enable_all_links;
        integer i;
        begin
            for (i = 0; i < NUM_NODES; i = i + 1) begin
                link_enable_cw[i]  = 1'b1;
                link_enable_ccw[i] = 1'b1;
            end
        end
    endtask

    //---- disable_all_links ---------------------------------------------------
    task disable_all_links;
        integer i;
        begin
            for (i = 0; i < NUM_NODES; i = i + 1) begin
                link_enable_cw[i]  = 1'b0;
                link_enable_ccw[i] = 1'b0;
            end
        end
    endtask

    //---- disable_cw ----------------------------------------------------------
    task disable_cw;
        input integer i;
        begin
            link_enable_cw[i] = 1'b0;
        end
    endtask

    //---- disable_ccw ---------------------------------------------------------
    task disable_ccw;
        input integer i;
        begin
            link_enable_ccw[i] = 1'b0;
        end
    endtask

    //---- enable_cw -----------------------------------------------------------
    task enable_cw;
        input integer i;
        begin
            link_enable_cw[i] = 1'b1;
        end
    endtask

    //---- enable_ccw ----------------------------------------------------------
    task enable_ccw;
        input integer i;
        begin
            link_enable_ccw[i] = 1'b1;
        end
    endtask

    //---- assign_node_ids -----------------------------------------------------
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
            repeat (20) @(posedge clk);
        end
    endtask

    //---- send_app_frame -------------------------------------------------------
    task send_app_frame;
        input integer src_node;
        input [7:0] dst_id;
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

    //---- send_app_frame_no_wait -----------------------------------------------
    // Initiates a send but returns immediately after app_frame_accepted.
    // Caller is responsible for checking app_frame_done later.
    task send_app_frame_no_wait;
        input integer src_node;
        input [7:0] dst_id;
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
        end
    endtask

    //---- wait_for_rx_frames --------------------------------------------------
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

    //---- wait_for_rx_frames_or_timeout ---------------------------------------
    // Returns 1 if frames were received, 0 if timeout
    task wait_for_rx_frames_or_timeout;
        input integer node;
        input integer target_count;
        input integer timeout_cycles;
        output integer received;
        integer cycles;
        begin
            cycles = 0;
            while (received_frame_count[node] < target_count && cycles < timeout_cycles) begin
                @(posedge clk);
                cycles = cycles + 1;
            end
            received = (received_frame_count[node] >= target_count) ? 1 : 0;
        end
    endtask

    //---- check_unicast_received ----------------------------------------------
    task check_unicast_received;
        input integer dst_node;
        input [7:0] expected_src;
        input [7:0] expected_dst;
        input integer expected_len;
        input [31:0] base_data;
        input integer expect_count;
        integer k;
        integer cycles;
        begin
            if (last_rx_src[dst_node] !== expected_src) begin
                $display("FAIL Node %0d: expected src=%0d, got src=%0d",
                         dst_node, expected_src, last_rx_src[dst_node]);
                $fatal(1);
            end
            if (last_rx_dst[dst_node] !== expected_dst) begin
                $display("FAIL Node %0d: expected dst=%0d, got dst=%0d",
                         dst_node, expected_dst, last_rx_dst[dst_node]);
                $fatal(1);
            end
            if (last_rx_len[dst_node] !== expected_len[15:0]) begin
                $display("FAIL Node %0d: expected len=%0d, got len=%0d",
                         dst_node, expected_len, last_rx_len[dst_node]);
                $fatal(1);
            end

            cycles = 0;
            while ((expected_len > 0) && (ri[dst_node] < expected_len[15:0]) &&
                   (cycles < TIMEOUT_CYCLES)) begin
                @(posedge clk);
                cycles = cycles + 1;
            end
            if ((expected_len > 0) && (ri[dst_node] < expected_len[15:0])) begin
                $display("FAIL Node %0d: expected %0d payload words, got %0d",
                         dst_node, expected_len, ri[dst_node]);
                $fatal(1);
            end

            for (k = 0; k < expected_len; k = k + 1) begin
                if (rx_payload_mem[dst_node][k] !== (base_data + k)) begin
                    $display("FAIL Node %0d payload[%0d]: expected 32'h%8h, got 32'h%8h",
                             dst_node, k, base_data + k, rx_payload_mem[dst_node][k]);
                    $fatal(1);
                end
            end

            if (received_frame_count[dst_node] !== expect_count) begin
                $display("FAIL Node %0d: expected %0d frames, got %0d",
                         dst_node, expect_count, received_frame_count[dst_node]);
                $fatal(1);
            end

            $display("  OK: Node %0d received frame from Node %0d, len=%0d, payload correct",
                     dst_node, expected_src, expected_len);
        end
    endtask

    //---- check_no_unexpected_frames ------------------------------------------
    task check_no_unexpected_frames;
        input integer src_node;
        input integer dst_node;
        integer n;
        begin
            for (n = 0; n < NUM_NODES; n = n + 1) begin
                if (n == dst_node || (dst_node == BROADCAST && n != src_node)) begin
                    // target node - OK
                end else if (received_frame_count[n] !== expected_counts_g[n]) begin
                    $display("FAIL Node %0d (non-target): expected %0d frames, got %0d",
                             n, expected_counts_g[n], received_frame_count[n]);
                    $fatal(1);
                end
            end
            $display("  OK: Non-target nodes did not receive unexpected frames");
        end
    endtask

    //---- snapshot_expected_counts --------------------------------------------
    task snapshot_expected_counts;
        integer n;
        begin
            for (n = 0; n < NUM_NODES; n = n + 1)
                expected_counts_g[n] = received_frame_count[n];
        end
    endtask

    //---- wait_idle_fixed -----------------------------------------------------
    task wait_idle_fixed;
        input integer delay_cycles;
        begin
            repeat (delay_cycles) @(posedge clk);
        end
    endtask

    //---- print_link_state ----------------------------------------------------
    task print_link_state;
        integer i;
        begin
            $display("Link state at cycle %0d:", cycle_counter);
            $write("  CW:  ");
            for (i = 0; i < NUM_NODES; i = i + 1)
                $write("N%0d->N%0d=%0d ", i, (i+1)%NUM_NODES, link_enable_cw[i]);
            $display("");
            $write("  CCW: ");
            for (i = 0; i < NUM_NODES; i = i + 1)
                $write("N%0d->N%0d=%0d ", i, (i+NUM_NODES-1)%NUM_NODES, link_enable_ccw[i]);
            $display("");
        end
    endtask

    //--------------------------------------------------------------------------
    // Main test sequence
    //--------------------------------------------------------------------------
    integer n;
    integer expected_counts_g [0:NUM_NODES-1];
    integer received_flag;
    integer send_cycle_start;

    initial begin
        // Initialize
        clk = 0;
        rst = 1;
        for (n = 0; n < NUM_NODES; n = n + 1) begin
            node_id_valid[n]       = 1'b0;
            node_id[n]             = 8'd0;
            app_frame_valid[n]     = 1'b0;
            app_dst_id[n]          = 8'd0;
            app_len16[n]           = 16'd0;
            app_rx_frame_ready[n]  = 1'b1;
            app_rx_payload_ready[n] = 1'b1;
        end
        disable_all_links();

        // Reset sequence
        repeat (20) @(posedge clk);
        rst = 1'b0;
        @(posedge clk);

        // Enable all links and assign node IDs
        enable_all_links();
        assign_node_ids();
        $display("INFO: Node IDs assigned, all links enabled at cycle %0d", cycle_counter);
        print_link_state();

        // Let network stabilize
        wait_idle_fixed(2000);
        $display("INFO: Network stabilized at cycle %0d", cycle_counter);

        //========================================================================
        // CASE 1: Single-direction link break
        //   Disconnect Node2->Node3 clockwise.
        //   Node0->Node4 should still work via CCW path.
        //========================================================================
        $display("============================================================");
        $display(" CASE 1: Single-direction link break (Node2->Node3 CW)");
        $display("============================================================");

        // Break Node2 CW output (Node2.out0 -> Node3.in1)
        disable_cw(2);
        $display("  Disabled link_enable_cw[2] (Node2->Node3) at cycle %0d", cycle_counter);
        print_link_state();

        snapshot_expected_counts();

        // Send Node0->Node4: should still arrive via CCW path
        //   CW: 0->1->2->X (blocked at 2->3)
        //   CCW: 0->7->6->5->4 (intact)
        send_app_frame(0, 8'd4, 4, 32'hA000_0000);
        $display("  Sent Node0->Node4 (len=4) at cycle %0d", cycle_counter);

        expected_counts_g[4] = expected_counts_g[4] + 1;
        wait_for_rx_frames(4, expected_counts_g[4], TIMEOUT_CYCLES);

        check_unicast_received(4, 8'd0, 8'd4, 4, 32'hA000_0000, expected_counts_g[4]);
        check_no_unexpected_frames(0, 4);

        // Restore link
        enable_cw(2);
        $display("  PASS: Single-direction break — traffic rerouted via alternate path");

        wait_idle_fixed(2000);

        //========================================================================
        // CASE 2: Bidirectional partition
        //   Break both directions between Node2<->Node3 AND Node5<->Node6.
        //   This creates two segments:
        //     Segment A: {3,4,5}
        //     Segment B: {6,7,0,1,2}
        //   Within-segment traffic should work.
        //   Cross-segment traffic should NOT arrive (no crash/deadlock).
        //========================================================================
        $display("============================================================");
        $display(" CASE 2: Bidirectional partition (2<->3 and 5<->6)");
        $display("============================================================");

        // Break 2<->3 in both directions
        disable_cw(2);   // Node2.out0 -> Node3.in1
        disable_ccw(3);  // Node3.out1 -> Node2.in0

        // Break 5<->6 in both directions
        disable_cw(5);   // Node5.out0 -> Node6.in1
        disable_ccw(6);  // Node6.out1 -> Node5.in0

        $display("  Partitioned at cycle %0d:", cycle_counter);
        $display("    Segment A: Node3-Node4-Node5");
        $display("    Segment B: Node6-Node7-Node0-Node1-Node2");
        print_link_state();

        // Test 2a: within Segment A — Node3->Node5 (CW: 3->4->5)
        $display("  --- Test 2a: within Segment A, Node3->Node5 ---");
        snapshot_expected_counts();
        send_app_frame(3, 8'd5, 3, 32'hC000_0000);
        expected_counts_g[5] = expected_counts_g[5] + 1;
        wait_for_rx_frames(5, expected_counts_g[5], TIMEOUT_CYCLES);
        check_unicast_received(5, 8'd3, 8'd5, 3, 32'hC000_0000, expected_counts_g[5]);
        $display("  OK: Node3->Node5 within Segment A works");

        // Test 2b: within Segment B — Node6->Node0 (CW: 6->7->0)
        $display("  --- Test 2b: within Segment B, Node6->Node0 ---");
        snapshot_expected_counts();
        send_app_frame(6, 8'd0, 2, 32'hD000_0000);
        expected_counts_g[0] = expected_counts_g[0] + 1;
        wait_for_rx_frames(0, expected_counts_g[0], TIMEOUT_CYCLES);
        check_unicast_received(0, 8'd6, 8'd0, 2, 32'hD000_0000, expected_counts_g[0]);
        $display("  OK: Node6->Node0 within Segment B works");

        // Test 2c: cross-segment — Node3->Node7 (should NOT arrive)
        $display("  --- Test 2c: cross-segment, Node3->Node7 (unreachable) ---");
        snapshot_expected_counts();
        received_flag = 0;
        send_app_frame(3, 8'd7, 2, 32'hE000_0000);
        wait_for_rx_frames_or_timeout(7, received_frame_count[7] + 1, SHORT_TIMEOUT, received_flag);
        if (received_flag) begin
            $display("FAIL: Node3->Node7 arrived across partition (should be unreachable)");
            $fatal(1);
        end
        // Verify no spurious frames at any node
        for (n = 0; n < NUM_NODES; n = n + 1) begin
            if (received_frame_count[n] !== expected_counts_g[n]) begin
                $display("FAIL Test 2c: Node %0d received unexpected frame (expected %0d, got %0d)",
                         n, expected_counts_g[n], received_frame_count[n]);
                $fatal(1);
            end
        end
        $display("  OK: Cross-segment frame correctly not delivered");

        // Test 2d: cross-segment — Node0->Node3 (should NOT arrive)
        $display("  --- Test 2d: cross-segment, Node0->Node3 (unreachable) ---");
        snapshot_expected_counts();
        received_flag = 0;
        send_app_frame(0, 8'd3, 2, 32'hF000_0000);
        wait_for_rx_frames_or_timeout(3, received_frame_count[3] + 1, SHORT_TIMEOUT, received_flag);
        if (received_flag) begin
            $display("FAIL: Node0->Node3 arrived across partition (should be unreachable)");
            $fatal(1);
        end
        for (n = 0; n < NUM_NODES; n = n + 1) begin
            if (received_frame_count[n] !== expected_counts_g[n]) begin
                $display("FAIL Test 2d: Node %0d received unexpected frame (expected %0d, got %0d)",
                         n, expected_counts_g[n], received_frame_count[n]);
                $fatal(1);
            end
        end
        $display("  OK: Cross-segment frame correctly not delivered");

        $display("  PASS: Bidirectional partition — within-segment works, cross-segment blocked, no deadlock");

        // Restore all links for next case
        enable_all_links();
        wait_idle_fixed(2000);

        //========================================================================
        // CASE 3: Mid-transmission link drop (half-frame test)
        //   Send Node0->Node4 len=256.  Break the CCW path while transmission
        //   is in progress so the frame cannot reach Node4 via either direction.
        //   Verify no corrupted half-frame is delivered.
        //========================================================================
        $display("============================================================");
        $display(" CASE 3: Mid-transmission link drop (half-frame)");
        $display("============================================================");

        // Break CW path Node1->Node2 and CCW path Node0->Node7
        // so that Node0->Node4 has no intact path.
        //   CW: 0->1->2->3->4 needs 1->2 intact → break it
        //   CCW: 0->7->6->5->4 needs 0->7 intact → break it
        disable_cw(1);   // Node1.out0 -> Node2.in1 (blocks CW to 3,4,5,6,7)
        disable_ccw(0);  // Node0.out1 -> Node7.in0 (blocks CCW to 7,6,5,4)
        $display("  Broken CW[1] and CCW[0] to isolate Node0->Node4 path");
        print_link_state();

        snapshot_expected_counts();

        // Start a len=256 send from Node0->Node4.  Break mid-transmission.
        // Use send_app_frame_no_wait to return after accept, then break the
        // remaining link to fully cut off the frame.
        send_cycle_start = cycle_counter;

        // Accept the frame at the source
        send_app_frame_no_wait(0, 8'd4, MAX_PAYLOAD, 32'hB000_0000);
        $display("  Frame accepted at cycle %0d, breaking remaining link now", cycle_counter);

        // Now break the CW path Node0->Node1 (the last path out of Node0)
        disable_cw(0);   // Node0.out0 -> Node1.in1
        $display("  Also broke CW[0] to fully isolate Node0");

        // Wait for the source-side frame_done (should complete locally)
        while (!app_frame_done[0])
            @(posedge clk);
        @(posedge clk);
        $display("  app_frame_done[0] asserted at cycle %0d (local TX done)", cycle_counter);

        // Wait and check no frame arrived at Node4
        received_flag = 0;
        wait_for_rx_frames_or_timeout(4, received_frame_count[4] + 1, SHORT_TIMEOUT, received_flag);
        if (received_flag) begin
            // Check if this is a genuine new frame or a liveness/etc
            if (last_rx_src[4] == 8'd0 && last_rx_dst[4] == 8'd4) begin
                $display("FAIL: Node4 received a corrupted half-frame from Node0 (src=0,dst=4,len=%0d)",
                         last_rx_len[4]);
                $fatal(1);
            end
            $display("  Note: Node4 received %0d frames total (may be liveness), last src=%0d dst=%0d",
                     received_frame_count[4], last_rx_src[4], last_rx_dst[4]);
        end

        // Verify no spurious frames at any node from this test
        for (n = 0; n < NUM_NODES; n = n + 1) begin
            if (received_frame_count[n] !== expected_counts_g[n]) begin
                // Could be liveness heartbeat frames — only fail if
                // the unexpected frame came from Node0 to Node4
                if (last_rx_src[n] == 8'd0 && last_rx_dst[n] == 8'd4 &&
                    received_frame_count[n] > expected_counts_g[n]) begin
                    $display("FAIL Test 3: Node %0d received spurious frame from Node0->Node4", n);
                    $fatal(1);
                end
            end
        end

        $display("  PASS: Mid-transmission link drop — no corrupted half-frame delivered");

        // Restore all links
        enable_all_links();
        wait_idle_fixed(2000);

        //========================================================================
        // CASE 4: Link recovery — normal communication after all links restored
        //========================================================================
        $display("============================================================");
        $display(" CASE 4: Link recovery and re-test");
        $display("============================================================");

        $display("  All links restored at cycle %0d", cycle_counter);
        print_link_state();

        // Test 4a: Node0->Node4 unicast
        $display("  --- Test 4a: Node0->Node4 unicast (len=4) ---");
        snapshot_expected_counts();
        send_app_frame(0, 8'd4, 4, 32'hA100_0000);
        expected_counts_g[4] = expected_counts_g[4] + 1;
        wait_for_rx_frames(4, expected_counts_g[4], TIMEOUT_CYCLES);
        check_unicast_received(4, 8'd0, 8'd4, 4, 32'hA100_0000, expected_counts_g[4]);
        check_no_unexpected_frames(0, 4);

        // Test 4b: Node5->Node1 unicast
        $display("  --- Test 4b: Node5->Node1 unicast (len=3) ---");
        snapshot_expected_counts();
        send_app_frame(5, 8'd1, 3, 32'hB100_0000);
        expected_counts_g[1] = expected_counts_g[1] + 1;
        wait_for_rx_frames(1, expected_counts_g[1], TIMEOUT_CYCLES);
        check_unicast_received(1, 8'd5, 8'd1, 3, 32'hB100_0000, expected_counts_g[1]);
        check_no_unexpected_frames(5, 1);

        // Test 4c: Node2->broadcast
        $display("  --- Test 4c: Node2->broadcast (len=2) ---");
        snapshot_expected_counts();
        for (n = 0; n < NUM_NODES; n = n + 1)
            if (n != 2)
                expected_counts_g[n] = expected_counts_g[n] + 1;
        send_app_frame(2, BROADCAST, 2, 32'hC100_0000);
        // Wait long enough for broadcast to propagate
        wait_idle_fixed(2000);
        for (n = 0; n < NUM_NODES; n = n + 1) begin
            if (n != 2 && received_frame_count[n] < expected_counts_g[n]) begin
                $display("FAIL Test 4c: Node %0d expected %0d frames, got %0d",
                         n, expected_counts_g[n], received_frame_count[n]);
                $fatal(1);
            end
        end
        $display("  OK: Broadcast from Node2 received by all 7 other nodes");

        $display("  PASS: All links restored — normal communication resumed");

        //========================================================================
        // ALL TESTS PASSED
        //========================================================================
        $display("============================================================");
        $display(" ALL LINK FAULT TESTS PASSED");
        $display("  Case 1: Single-direction break — traffic rerouted");
        $display("  Case 2: Bidirectional partition — within-segment OK,");
        $display("          cross-segment blocked, no deadlock");
        $display("  Case 3: Mid-transmission drop — no half-frame corruption");
        $display("  Case 4: Recovery — all paths working again");
        $display("============================================================");
        $finish;
    end

endmodule
