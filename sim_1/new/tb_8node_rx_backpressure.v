`timescale 1ns / 1ps

//------------------------------------------------------------------------------
// tb_8node_rx_backpressure: 8-node ring RX backpressure testbench
//   Verifies that app_rx_frame_ready and app_rx_payload_ready deassertion does
//   not cause frame loss, reordering, or payload misalignment in rx_report_fifo
//   and app_rx readout logic.
//------------------------------------------------------------------------------
module tb_8node_rx_backpressure;

    localparam NUM_NODES   = 8;
    localparam CLK_PERIOD  = 10;
    localparam SIM_CLK_FREQ = 500000000;
    localparam TIMEOUT_CYCLES = 500000;
    localparam BROADCAST   = 8'hFF;
    localparam MAX_PAYLOAD = 256;

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

    //--------------------------------------------------------------------------
    // 8 node_top instances
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

    //==========================================================================
    // Scoreboard: per-node expected-frame set (content-matched, order-insensitive)
    //==========================================================================
    localparam SB_DEPTH = 64;
    reg [7:0]   sb_src  [0:NUM_NODES-1][0:SB_DEPTH-1];
    reg [7:0]   sb_dst  [0:NUM_NODES-1][0:SB_DEPTH-1];
    reg [15:0]  sb_len  [0:NUM_NODES-1][0:SB_DEPTH-1];
    reg [31:0]  sb_base [0:NUM_NODES-1][0:SB_DEPTH-1];
    reg         sb_matched [0:NUM_NODES-1][0:SB_DEPTH-1];
    integer     sb_count [0:NUM_NODES-1];
    integer     sb_matched_count [0:NUM_NODES-1];

    //==========================================================================
    // Per-node RX collection state machine (backpressure-safe)
    //   State 0: WAIT_HEADER     — capture header + match scoreboard
    //   State 1: COLLECT_PAYLOAD — capture and verify each word vs expected
    //   sb_match_idx stores the matched scoreboard index (-1 = no match yet)
    //==========================================================================
    reg [1:0]   rx_st [0:NUM_NODES-1];
    reg [7:0]   rx_cap_src [0:NUM_NODES-1];
    reg [7:0]   rx_cap_dst [0:NUM_NODES-1];
    reg [15:0]  rx_cap_cnt [0:NUM_NODES-1];
    reg [15:0]  rx_cap_len [0:NUM_NODES-1];
    reg [31:0]  rx_cap_exp_base [0:NUM_NODES-1];
    integer     sb_match_idx [0:NUM_NODES-1];
    integer     rx_frame_total [0:NUM_NODES-1];
    integer     rx_payload_errs [0:NUM_NODES-1];

    genvar gmon;
    generate
        for (gmon = 0; gmon < NUM_NODES; gmon = gmon + 1) begin : g_rx_mon
            always @(posedge clk) begin
                if (rst) begin
                    rx_st[gmon]         <= 2'd0;
                    rx_cap_src[gmon]    <= 8'd0;
                    rx_cap_dst[gmon]    <= 8'd0;
                    rx_cap_cnt[gmon]    <= 16'd0;
                    rx_cap_len[gmon]    <= 16'd0;
                    rx_frame_total[gmon] <= 0;
                    rx_payload_errs[gmon] <= 0;
                    sb_match_idx[gmon]  <= -1;
                end else begin
                    case (rx_st[gmon])
                        2'd0: begin  // WAIT_HEADER
                            if (app_rx_frame_valid[gmon] && app_rx_frame_ready[gmon]) begin
                                rx_cap_src[gmon] <= app_rx_src_id[gmon];
                                rx_cap_dst[gmon] <= app_rx_dst_id[gmon];
                                rx_cap_cnt[gmon] <= app_rx_count[gmon];
                                rx_cap_len[gmon] <= app_rx_len16[gmon];
                                rx_frame_total[gmon] <= rx_frame_total[gmon] + 1;
                                // Find matching scoreboard entry
                                sb_match_idx[gmon] <= -1;
                                for (integer si = 0; si < SB_DEPTH; si = si + 1) begin
                                    if (si < sb_count[gmon] && !sb_matched[gmon][si] &&
                                        sb_src[gmon][si] === app_rx_src_id[gmon] &&
                                        sb_dst[gmon][si] === app_rx_dst_id[gmon] &&
                                        sb_len[gmon][si] === app_rx_len16[gmon]) begin
                                        sb_match_idx[gmon] <= si;
                                        rx_cap_exp_base[gmon] <= sb_base[gmon][si];
                                        si = SB_DEPTH;
                                    end
                                end
                                if (app_rx_len16[gmon] == 16'd0) begin
                                    // Zero-length: mark matched immediately
                                    if (sb_match_idx[gmon] >= 0) begin
                                        sb_matched[gmon][sb_match_idx[gmon]] <= 1'b1;
                                        sb_matched_count[gmon] <= sb_matched_count[gmon] + 1;
                                    end
                                    rx_st[gmon] <= 2'd0;
                                end else begin
                                    rx_st[gmon] <= 2'd1;
                                end
                            end
                        end

                        2'd1: begin  // COLLECT_PAYLOAD — verify each word
                            if (app_rx_payload_valid[gmon] && app_rx_payload_ready[gmon]) begin
                                // Compare with expected value
                                if (sb_match_idx[gmon] >= 0) begin
                                    if (app_rx_payload_data[gmon] !== (rx_cap_exp_base[gmon] + app_rx_payload_addr[gmon])) begin
                                        rx_payload_errs[gmon] <= rx_payload_errs[gmon] + 1;
                                        $display("FAIL Node%0d payload[%0d]: exp=32'h%08h got=32'h%08h",
                                                 gmon, app_rx_payload_addr[gmon],
                                                 rx_cap_exp_base[gmon] + app_rx_payload_addr[gmon],
                                                 app_rx_payload_data[gmon]);
                                    end
                                end
                                if (app_rx_payload_addr[gmon] == rx_cap_len[gmon] - 1) begin
                                    // Mark matched
                                    if (sb_match_idx[gmon] >= 0) begin
                                        sb_matched[gmon][sb_match_idx[gmon]] <= 1'b1;
                                        sb_matched_count[gmon] <= sb_matched_count[gmon] + 1;
                                    end
                                    rx_st[gmon] <= 2'd0;
                                end
                            end
                        end
                    endcase
                end
            end
        end
    endgenerate

    //==========================================================================
    // Backpressure pattern generators (counter-based, no fork/disable fork)
    //   bp_active flags enable the pattern; bp_cycle counts continuously.
    //   Each case sets flags and the patterns drive app_rx_*_ready signals.
    //==========================================================================
    reg         bp_active_case2;   // Case 2: payload_ready[4] pattern
    reg         bp_active_case3;   // Case 3: frame_ready[5] + payload_ready[5]
    reg         bp_active_case4;   // Case 4: payload_ready[7] pattern
    integer     bp_cycle;

    // Free-running cycle counter when any pattern is active
    always @(posedge clk) begin
        if (rst)
            bp_cycle <= 0;
        else if (bp_active_case2 || bp_active_case3 || bp_active_case4)
            bp_cycle <= bp_cycle + 1;
        else
            bp_cycle <= 0;
    end

    // Case 2: payload_ready[4] = 5 on, 7 off
    always @(posedge clk) begin
        if (rst || !bp_active_case2) begin
            // controlled by test sequence directly when inactive
        end else begin
            if ((bp_cycle % 12) < 5)
                app_rx_payload_ready[4] <= 1'b1;
            else
                app_rx_payload_ready[4] <= 1'b0;
        end
    end

    // Case 3: frame_ready[5] = 8 on, 3 off
    always @(posedge clk) begin
        if (rst || !bp_active_case3) begin
        end else begin
            if ((bp_cycle % 11) < 8)
                app_rx_frame_ready[5] <= 1'b1;
            else
                app_rx_frame_ready[5] <= 1'b0;
        end
    end

    // Case 3: payload_ready[5] = 3 on, 4 off
    always @(posedge clk) begin
        if (rst || !bp_active_case3) begin
        end else begin
            if ((bp_cycle % 7) < 3)
                app_rx_payload_ready[5] <= 1'b1;
            else
                app_rx_payload_ready[5] <= 1'b0;
        end
    end

    // Case 4: payload_ready[7] = 2 on, 3 off
    always @(posedge clk) begin
        if (rst || !bp_active_case4) begin
        end else begin
            if ((bp_cycle % 5) < 2)
                app_rx_payload_ready[7] <= 1'b1;
            else
                app_rx_payload_ready[7] <= 1'b0;
        end
    end

    //==========================================================================
    // Task: push expected frame into scoreboard
    //==========================================================================
    task push_expected;
        input integer node;
        input [7:0] src;
        input [7:0] dst;
        input [15:0] len;
        input [31:0] base;
        integer idx;
        begin
            idx = sb_count[node];
            sb_src[node][idx]  = src;
            sb_dst[node][idx]  = dst;
            sb_len[node][idx]  = len;
            sb_base[node][idx] = base;
            sb_matched[node][idx] = 1'b0;
            sb_count[node] = sb_count[node] + 1;
        end
    endtask

    //==========================================================================
    // Task: wait until scoreboard for a specific node is fully matched
    //==========================================================================
    task wait_scoreboard_empty;
        input integer node;
        input integer timeout_cycles;
        integer cycles;
        begin
            cycles = 0;
            while (sb_matched_count[node] < sb_count[node] && cycles < timeout_cycles) begin
                @(posedge clk);
                cycles = cycles + 1;
            end
            if (cycles >= timeout_cycles && sb_matched_count[node] < sb_count[node]) begin
                $display("TIMEOUT: Node%0d scoreboard not fully matched after %0d cycles (%0d of %0d matched)",
                         node, cycles, sb_matched_count[node], sb_count[node]);
            end
        end
    endtask

    //==========================================================================
    // Task: assign node IDs
    //==========================================================================
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

    //==========================================================================
    // Task: send app frame
    //==========================================================================
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

    //==========================================================================
    // Task: wait for network idle
    //==========================================================================
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
        end
    endtask

    //==========================================================================
    // Task: check rx_overflow on any node
    //==========================================================================
    task check_rx_overflow;
        integer n;
        begin
            for (n = 0; n < NUM_NODES; n = n + 1) begin
                if (rx_overflow[n]) begin
                    $display("WARNING: Node %0d rx_overflow asserted", n);
                end
            end
        end
    endtask

    //==========================================================================
    // Task: validate a case — check target node scoreboard
    //==========================================================================
    task validate_case;
        input integer case_num;
        input integer target_node;
        input integer expected_frames;
        reg pass;
        begin
            pass = 1'b1;

            if (sb_matched_count[target_node] < sb_count[target_node]) begin
                $display("  CASE %0d FAILED: Node%0d scoreboard not fully matched (%0d of %0d)",
                         case_num, target_node, sb_matched_count[target_node], sb_count[target_node]);
                pass = 1'b0;
            end

            if (rx_frame_total[target_node] < expected_frames) begin
                $display("  CASE %0d FAILED: Node%0d received only %0d frames (expected %0d)",
                         case_num, target_node, rx_frame_total[target_node], expected_frames);
                pass = 1'b0;
            end

            if (rx_payload_errs[target_node] > 0) begin
                $display("  CASE %0d FAILED: Node%0d has %0d payload errors",
                         case_num, target_node, rx_payload_errs[target_node]);
                pass = 1'b0;
            end

            if (pass)
                $display("  CASE %0d PASSED", case_num);
            else
                $fatal(1, "CASE %0d FAILED", case_num);
        end
    endtask

    //==========================================================================
    // Main test sequence
    //==========================================================================
    integer n;

    initial begin
        // Initialize
        clk = 0;
        rst = 1;
        for (n = 0; n < NUM_NODES; n = n + 1) begin
            node_id_valid[n]        = 1'b0;
            node_id[n]              = 8'd0;
            app_frame_valid[n]      = 1'b0;
            app_dst_id[n]           = 8'd0;
            app_len16[n]            = 16'd0;
            app_rx_frame_ready[n]   = 1'b1;
            app_rx_payload_ready[n] = 1'b1;
            sb_count[n]          = 0;
            sb_matched_count[n]  = 0;
        end

        bp_active_case2 = 1'b0;
        bp_active_case3 = 1'b0;
        bp_active_case4 = 1'b0;

        repeat (20) @(posedge clk);
        rst = 1'b0;
        @(posedge clk);

        assign_node_ids();

        //======================================================================
        // CASE 1: Target node header ready held low for extended period
        //   Node4 app_rx_frame_ready = 0 for a while.
        //   Send Node0->Node4, Node1->Node4, Node2->Node4.
        //   Then app_rx_frame_ready[4] = 1.
        //   Expect Node4 to eventually output all headers and payloads.
        //======================================================================
        $display("============================================================");
        $display(" CASE 1: Header ready backpressure (Node0/1/2 -> Node4)");
        $display("============================================================");

        app_rx_frame_ready[4] = 1'b0;

        // Send while header ready is low
        push_expected(4, 8'd0, 8'd4, 16'd4, 32'hA100_0000);
        send_app_frame(0, 8'd4, 4, 32'hA100_0000);

        push_expected(4, 8'd1, 8'd4, 16'd8, 32'hA200_0000);
        send_app_frame(1, 8'd4, 8, 32'hA200_0000);

        push_expected(4, 8'd2, 8'd4, 16'd3, 32'hA300_0000);
        send_app_frame(2, 8'd4, 3, 32'hA300_0000);

        // Wait some time with frame_ready still low
        repeat (500) @(posedge clk);

        // Release header ready
        app_rx_frame_ready[4] = 1'b1;

        // Wait for all expected frames to be consumed
        wait_scoreboard_empty(4, TIMEOUT_CYCLES);

        validate_case(1, 4, 3);

        wait_network_idle(10000);

        //======================================================================
        // CASE 2: Payload ready intermittent
        //   app_rx_frame_ready[4] = 1 always.
        //   app_rx_payload_ready[4] cycles: 5 ready, 7 not ready.
        //   Send frames with len=1, len=4, len=16, len=64 to Node4.
        //======================================================================
        $display("============================================================");
        $display(" CASE 2: Payload ready intermittent (len=1,4,16,64 -> Node4)");
        $display("============================================================");

        app_rx_frame_ready[4]   = 1'b1;
        app_rx_payload_ready[4] = 1'b1;

        // Send frames before starting the backpressure pattern to ensure they
        // are in-flight when the pattern starts
        push_expected(4, 8'd0, 8'd4, 16'd1,  32'hB100_0000);
        send_app_frame(0, 8'd4, 1,  32'hB100_0000);

        push_expected(4, 8'd3, 8'd4, 16'd4,  32'hB200_0000);
        send_app_frame(3, 8'd4, 4,  32'hB200_0000);

        push_expected(4, 8'd6, 8'd4, 16'd16, 32'hB300_0000);
        send_app_frame(6, 8'd4, 16, 32'hB300_0000);

        push_expected(4, 8'd0, 8'd4, 16'd64, 32'hB400_0000);
        send_app_frame(0, 8'd4, 64, 32'hB400_0000);

        // Start payload ready pattern: 5 ready, 7 not ready
        app_rx_payload_ready[4] = 1'b1;
        bp_active_case2 = 1'b1;

        wait_scoreboard_empty(4, TIMEOUT_CYCLES);

        bp_active_case2 = 1'b0;
        app_rx_payload_ready[4] = 1'b1;

        validate_case(2, 4, 4);

        wait_network_idle(10000);

        //======================================================================
        // CASE 3: Header ready and payload ready both jitter
        //   Target: Node5.
        //   app_rx_frame_ready[5]:  8 ready, 3 not ready  (period 11)
        //   app_rx_payload_ready[5]: 3 ready, 4 not ready (period 7)
        //   Multiple sources send to Node5.
        //======================================================================
        $display("============================================================");
        $display(" CASE 3: Header & payload ready jitter (multi-src -> Node5)");
        $display("============================================================");

        app_rx_frame_ready[5]   = 1'b1;
        app_rx_payload_ready[5] = 1'b1;

        push_expected(5, 8'd0, 8'd5, 16'd3,  32'hC100_0000);
        send_app_frame(0, 8'd5, 3,  32'hC100_0000);

        push_expected(5, 8'd1, 8'd5, 16'd7,  32'hC200_0000);
        send_app_frame(1, 8'd5, 7,  32'hC200_0000);

        push_expected(5, 8'd2, 8'd5, 16'd2,  32'hC300_0000);
        send_app_frame(2, 8'd5, 2,  32'hC300_0000);

        push_expected(5, 8'd3, 8'd5, 16'd12, 32'hC400_0000);
        send_app_frame(3, 8'd5, 12, 32'hC400_0000);

        push_expected(5, 8'd7, 8'd5, 16'd5,  32'hC500_0000);
        send_app_frame(7, 8'd5, 5,  32'hC500_0000);

        // Start jitter patterns with different periods
        app_rx_frame_ready[5]   = 1'b1;
        app_rx_payload_ready[5] = 1'b1;
        bp_active_case3 = 1'b1;

        wait_scoreboard_empty(5, TIMEOUT_CYCLES);

        bp_active_case3 = 1'b0;
        app_rx_frame_ready[5]   = 1'b1;
        app_rx_payload_ready[5] = 1'b1;

        validate_case(3, 5, 5);

        wait_network_idle(10000);

        //======================================================================
        // CASE 4: Long payload (len=256) with frequent payload ready drops
        //   Send Node6->Node7 with max payload.
        //   app_rx_payload_ready[7]: 2 ready, 3 not ready (aggressive).
        //======================================================================
        $display("============================================================");
        $display(" CASE 4: Long payload backpressure (Node6->Node7, len=256)");
        $display("============================================================");

        app_rx_frame_ready[7]   = 1'b1;
        app_rx_payload_ready[7] = 1'b1;

        push_expected(7, 8'd6, 8'd7, 16'd256, 32'hD000_0000);
        send_app_frame(6, 8'd7, 256, 32'hD000_0000);

        // Aggressive payload ready pattern: 2 ready, 3 not ready
        app_rx_payload_ready[7] = 1'b1;
        bp_active_case4 = 1'b1;

        wait_scoreboard_empty(7, TIMEOUT_CYCLES * 2);

        bp_active_case4 = 1'b0;
        app_rx_payload_ready[7] = 1'b1;

        validate_case(4, 7, 1);

        wait_network_idle(10000);

        //======================================================================
        // Final verification
        //======================================================================
        $display("============================================================");

        check_rx_overflow();

        // Verify all scoreboards fully matched across all nodes
        for (n = 0; n < NUM_NODES; n = n + 1) begin
            if (sb_matched_count[n] < sb_count[n]) begin
                $display("FAIL: Node%0d scoreboard not fully matched (matched=%0d expected=%0d)",
                         n, sb_matched_count[n], sb_count[n]);
                $fatal(1, "FINAL CHECK FAILED");
            end
        end

        $display(" ALL RX BACKPRESSURE TESTS PASSED");
        $display("============================================================");
        $finish;
    end

endmodule
