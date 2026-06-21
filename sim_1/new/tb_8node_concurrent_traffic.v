`timescale 1ns / 1ps

//------------------------------------------------------------------------------
// tb_8node_concurrent_traffic: concurrent-traffic stress test for 8-node ring.
//   Covers:
//     Case 1: 4 simultaneous unicasts to distinct destinations
//     Case 2: 4 simultaneous unicasts, reverse cross pattern
//     Case 3: 4 sources concurrently sending to the same destination
//     Case 4: mixed broadcast + unicast simultaneously
//   Uses a scoreboard to match received frames against expected frames,
//   avoiding false failures caused by non-deterministic arrival order.
//------------------------------------------------------------------------------
module tb_8node_concurrent_traffic;

    localparam NUM_NODES    = 8;
    localparam CLK_PERIOD   = 10;
    localparam SIM_CLK_FREQ = 500000000;
    localparam TIMEOUT_CYCLES = 500000;
    localparam BROADCAST    = 8'hFF;
    localparam MAX_PAYLOAD  = 256;
    localparam MAX_EXP      = 8;

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

    integer i_pipe;
    always @(posedge clk) begin
        
        if (rst) begin
            for (i_pipe = 0; i_pipe < NUM_NODES; i_pipe = i_pipe + 1) begin
                link_data_cw[i_pipe]  <= 32'd0;
                link_valid_cw[i_pipe] <= 1'b0;
                link_data_ccw[i_pipe] <= 32'd0;
                link_valid_ccw[i_pipe] <= 1'b0;
            end
        end else begin
            for (i_pipe = 0; i_pipe < NUM_NODES; i_pipe = i_pipe + 1) begin
                link_data_cw[i_pipe]  <= out0[i_pipe];
                link_valid_cw[i_pipe] <= valid_out0[i_pipe];
                link_data_ccw[i_pipe] <= out1[i_pipe];
                link_valid_ccw[i_pipe] <= valid_out1[i_pipe];
            end
        end
    end

    //--------------------------------------------------------------------------
    // Standard received frame tracking (per-node counters + last-frame latches)
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
    // Scoreboard: per-case capture of every received frame
    //   case_rx_* captures header at frame_valid time.
    //   case_rx_payload stores up to MAX_CAP_PAYLOAD words per received frame
    //   so per-word checking does not depend on the shared rx_payload_mem
    //   (which is overwritten by subsequent frames).
    //
    //   FIX: case_active only gates new capture, NOT clearing of already-
    //   captured results.  clear_scoreboard() is the sole clearing mechanism.
    //
    //   FIX: case_rx_cap_sel tracks the frame index to which the current
    //   payload word belongs, avoiding reliance on case_rx_count-1.
    //--------------------------------------------------------------------------
    localparam MAX_CAP_PAYLOAD = 256;

    reg case_active;
    integer case_rx_count [0:NUM_NODES-1];
    integer case_rx_src   [0:NUM_NODES-1][0:MAX_EXP-1];
    integer case_rx_dst   [0:NUM_NODES-1][0:MAX_EXP-1];
    integer case_rx_len   [0:NUM_NODES-1][0:MAX_EXP-1];
    integer case_rx_payload [0:NUM_NODES-1][0:MAX_EXP-1][0:MAX_CAP_PAYLOAD-1];
    integer case_rx_cap_sel [0:NUM_NODES-1];

    genvar sbn;
    generate
        for (sbn = 0; sbn < NUM_NODES; sbn = sbn + 1) begin : g_sb_cap
            always @(posedge clk) begin
                if (rst) begin
                    case_rx_count[sbn] <= 0;
                    case_rx_cap_sel[sbn] <= 0;
                end else if (case_active) begin
                    if (app_rx_frame_valid[sbn] && app_rx_frame_ready[sbn]) begin
                        if (case_rx_count[sbn] < MAX_EXP) begin
                            case_rx_src[sbn][case_rx_count[sbn]] <= app_rx_src_id[sbn];
                            case_rx_dst[sbn][case_rx_count[sbn]] <= app_rx_dst_id[sbn];
                            case_rx_len[sbn][case_rx_count[sbn]] <= app_rx_len16[sbn];
                        end
                        case_rx_cap_sel[sbn] <= case_rx_count[sbn];
                        case_rx_count[sbn] <= case_rx_count[sbn] + 1;
                    end
                    if (app_rx_payload_valid[sbn] && app_rx_payload_ready[sbn]) begin
                        if (app_rx_payload_addr[sbn] < MAX_CAP_PAYLOAD) begin
                            case_rx_payload[sbn][case_rx_cap_sel[sbn]][app_rx_payload_addr[sbn]]
                                <= app_rx_payload_data[sbn];
                        end
                    end
                end
            end
        end
    endgenerate

    //--------------------------------------------------------------------------
    // Expected-frame scoreboard (filled by testbench before each case)
    //   exp_fdst is the frame-level destination field:
    //     unicast  -> same as dst_node
    //     broadcast -> BROADCAST (8'hFF)
    //--------------------------------------------------------------------------
    integer exp_count [0:NUM_NODES-1];
    integer exp_src   [0:NUM_NODES-1][0:MAX_EXP-1];
    integer exp_fdst  [0:NUM_NODES-1][0:MAX_EXP-1];
    integer exp_len   [0:NUM_NODES-1][0:MAX_EXP-1];
    integer exp_base  [0:NUM_NODES-1][0:MAX_EXP-1];
    integer exp_matched [0:NUM_NODES-1][0:MAX_EXP-1];

    integer n, i;
    integer conc_senders [0:7];
    integer conc_dsts    [0:7];
    integer conc_lens    [0:7];
    integer conc_bases   [0:7];

    //--------------------------------------------------------------------------
    // Tasks
    //--------------------------------------------------------------------------

    task clear_scoreboard;
        integer nd, i, w;
        begin
            for (nd = 0; nd < NUM_NODES; nd = nd + 1) begin
                exp_count[nd] = 0;
                case_rx_count[nd] = 0;
                case_rx_cap_sel[nd] = 0;
                for (i = 0; i < MAX_EXP; i = i + 1) begin
                    exp_src[nd][i] = 0;
                    exp_fdst[nd][i] = 0;
                    exp_len[nd][i] = 0;
                    exp_base[nd][i] = 0;
                    exp_matched[nd][i] = 0;
                    case_rx_src[nd][i] = 0;
                    case_rx_dst[nd][i] = 0;
                    case_rx_len[nd][i] = 0;
                    for (w = 0; w < MAX_CAP_PAYLOAD; w = w + 1)
                        case_rx_payload[nd][i][w] = 0;
                end
            end
        end
    endtask

    task add_expected;
        input integer dst_node;
        input integer src_node;
        input integer frame_dst;
        input integer len;
        input integer base;
        begin
            exp_src[dst_node][exp_count[dst_node]]  = src_node;
            exp_fdst[dst_node][exp_count[dst_node]] = frame_dst;
            exp_len[dst_node][exp_count[dst_node]]  = len;
            exp_base[dst_node][exp_count[dst_node]] = base;
            exp_count[dst_node] = exp_count[dst_node] + 1;
        end
    endtask

    // ---- send_concurrent: assert N app_frame_valid in the same time step ----
    //   FIX: per-sender accepted_latched tracking prevents double-clearing.
    //   Each sender independently clears its own valid/dst/len after accepted.
    //   Wait for ALL senders to see app_frame_done before returning.
    //   Final cleanup deasserts all sender signals regardless.
    task send_concurrent;
        input integer num_senders;
        integer i, k;
        reg [7:0] accepted_latched;
        reg [7:0] done_latched;
        reg [7:0] sender_mask;
        begin
            sender_mask = 0;
            accepted_latched = 0;
            done_latched = 0;

            for (i = 0; i < num_senders; i = i + 1) begin
                for (k = 0; k < conc_lens[i]; k = k + 1)
                    payload_mem[conc_senders[i]][k] = conc_bases[i] + k;

                app_dst_id[conc_senders[i]] = conc_dsts[i][7:0];
                app_len16[conc_senders[i]] = conc_lens[i][15:0];
                sender_mask[conc_senders[i]] = 1'b1;
            end

            for (i = 0; i < num_senders; i = i + 1)
                app_frame_valid[conc_senders[i]] = 1'b1;

            while (done_latched != sender_mask) begin
                @(posedge clk);

                for (i = 0; i < num_senders; i = i + 1) begin
                    if (!accepted_latched[conc_senders[i]] &&
                        app_frame_accepted[conc_senders[i]]) begin
                        accepted_latched[conc_senders[i]] = 1'b1;
                        app_frame_valid[conc_senders[i]] = 1'b0;
                        app_dst_id[conc_senders[i]] = 8'd0;
                        app_len16[conc_senders[i]] = 16'd0;
                    end
                end

                for (i = 0; i < num_senders; i = i + 1) begin
                    if (!done_latched[conc_senders[i]] &&
                        app_frame_done[conc_senders[i]]) begin
                        done_latched[conc_senders[i]] = 1'b1;
                    end
                end
            end

            for (i = 0; i < num_senders; i = i + 1) begin
                app_frame_valid[conc_senders[i]] = 1'b0;
                app_dst_id[conc_senders[i]] = 8'd0;
                app_len16[conc_senders[i]] = 16'd0;
            end

            @(posedge clk);
        end
    endtask

    task wait_network_idle;
        input integer timeout_cycles;
        integer cycles;
        integer nd;
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
                for (nd = 0; nd < NUM_NODES; nd = nd + 1) begin
                    if (network_congested[nd] || valid_out0[nd] || valid_out1[nd] ||
                        valid_in0[nd] || valid_in1[nd] ||
                        link_valid_cw[nd] || link_valid_ccw[nd])
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

    // ---- check_scoreboard: match received frames against expected set ----
    //   FIX: rx_matched is now a 2D array [node][ri] so each node has
    //   independent matched flags.  The previous 1D rx_matched was shared
    //   across nodes, causing false "UNEXPECTED" reports on earlier nodes
    //   after later nodes overwrote it.
    task check_scoreboard;
        input integer case_num;
        integer node, ei, ri, k;
        integer total_exp, total_rx;
        integer match_cnt;
        integer rx_matched [0:NUM_NODES-1][0:MAX_EXP-1];
        reg payload_ok;
        begin
            for (node = 0; node < NUM_NODES; node = node + 1)
                for (ri = 0; ri < MAX_EXP; ri = ri + 1)
                    rx_matched[node][ri] = 0;

            total_exp = 0;
            total_rx = 0;
            for (node = 0; node < NUM_NODES; node = node + 1) begin
                total_exp = total_exp + exp_count[node];
                total_rx  = total_rx  + case_rx_count[node];
            end

            for (node = 0; node < NUM_NODES; node = node + 1)
                for (ei = 0; ei < exp_count[node]; ei = ei + 1)
                    exp_matched[node][ei] = 0;

            match_cnt = 0;
            for (node = 0; node < NUM_NODES; node = node + 1) begin
                for (ri = 0; ri < case_rx_count[node]; ri = ri + 1)
                    rx_matched[node][ri] = 0;

                for (ei = 0; ei < exp_count[node]; ei = ei + 1) begin
                    for (ri = 0; ri < case_rx_count[node]; ri = ri + 1) begin
                        if (!rx_matched[node][ri] &&
                            case_rx_src[node][ri] == exp_src[node][ei] &&
                            case_rx_dst[node][ri] == exp_fdst[node][ei] &&
                            case_rx_len[node][ri] == exp_len[node][ei] &&
                            case_rx_payload[node][ri][0] == exp_base[node][ei]) begin

                            payload_ok = 1'b1;
                            for (k = 0; k < exp_len[node][ei]; k = k + 1) begin
                                if (case_rx_payload[node][ri][k] !== (exp_base[node][ei] + k)) begin
                                    $display("FAIL Case %0d: Node %0d exp[%0d] src=%0d payload[%0d] mismatch exp=%08h got=%08h",
                                             case_num, node, ei, case_rx_src[node][ri], k,
                                             exp_base[node][ei] + k,
                                             case_rx_payload[node][ri][k]);
                                    payload_ok = 1'b0;
                                end
                            end

                            if (payload_ok) begin
                                rx_matched[node][ri] = 1;
                                exp_matched[node][ei] = 1;
                                match_cnt = match_cnt + 1;
                            end
                        end
                    end
                end
            end

            for (node = 0; node < NUM_NODES; node = node + 1) begin
                for (ei = 0; ei < exp_count[node]; ei = ei + 1) begin
                    if (!exp_matched[node][ei]) begin
                        $display("FAIL Case %0d: Node %0d expected src=%0d fdst=%0d len=%0d base=%08h NOT received",
                                 case_num, node, exp_src[node][ei], exp_fdst[node][ei],
                                 exp_len[node][ei], exp_base[node][ei]);
                    end
                end
                for (ri = 0; ri < case_rx_count[node]; ri = ri + 1) begin
                    if (!rx_matched[node][ri]) begin
                        $display("FAIL Case %0d: Node %0d UNEXPECTED rx frame src=%0d fdst=%0d len=%0d base=%08h",
                                 case_num, node, case_rx_src[node][ri], case_rx_dst[node][ri],
                                 case_rx_len[node][ri], case_rx_payload[node][ri][0]);
                    end
                end
            end

            if (match_cnt == total_exp && total_rx == total_exp) begin
                $display("  Scoreboard Case %0d: %0d/%0d frames matched OK", case_num, match_cnt, total_exp);
            end else begin
                $display("FAIL Case %0d: matched %0d/%0d expected, received %0d total frames",
                         case_num, match_cnt, total_exp, total_rx);
                $fatal;
            end
        end
    endtask

    //--------------------------------------------------------------------------
    // Main test sequence
    //--------------------------------------------------------------------------

    initial begin
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

        // Initialize all 8 nodes with sequential IDs
        for (n = 0; n < NUM_NODES; n = n + 1) begin
            node_id[n] = n[7:0];
            node_id_valid[n] = 1'b1;
        end
        @(posedge clk);
        for (n = 0; n < NUM_NODES; n = n + 1)
            node_id_valid[n] <= 1'b0;
        @(posedge clk);

        repeat (20) @(posedge clk);
        $display("============================================================");
        $display(" 8-NODE CONCURRENT TRAFFIC TEST");
        $display("============================================================");

        //----------------------------------------------------------------------
        // CASE 1: Four sources to four distinct destinations
        //----------------------------------------------------------------------
        $display("============================================================");
        $display(" CASE 1: 4 concurrent unicasts to distinct destinations");
        $display("============================================================");

        clear_scoreboard();
        case_active = 1;

        conc_senders[0] = 0; conc_dsts[0] = 4; conc_lens[0] = 4; conc_bases[0] = 32'hA100_0000;
        conc_senders[1] = 1; conc_dsts[1] = 5; conc_lens[1] = 3; conc_bases[1] = 32'hA200_0000;
        conc_senders[2] = 2; conc_dsts[2] = 6; conc_lens[2] = 7; conc_bases[2] = 32'hA300_0000;
        conc_senders[3] = 3; conc_dsts[3] = 7; conc_lens[3] = 2; conc_bases[3] = 32'hA400_0000;

        add_expected(4, 0, 4, 4, 32'hA100_0000);
        add_expected(5, 1, 5, 3, 32'hA200_0000);
        add_expected(6, 2, 6, 7, 32'hA300_0000);
        add_expected(7, 3, 7, 2, 32'hA400_0000);

        send_concurrent(4);
        wait_network_idle(TIMEOUT_CYCLES);
        repeat (2000) @(posedge clk);
        case_active = 0;
        repeat (10) @(posedge clk);

        check_scoreboard(1);
        $display("CASE 1 PASSED");

        //----------------------------------------------------------------------
        // CASE 2: Reverse cross
        //----------------------------------------------------------------------
        $display("============================================================");
        $display(" CASE 2: 4 concurrent unicasts, reverse cross pattern");
        $display("============================================================");

        clear_scoreboard();
        case_active = 1;

        conc_senders[0] = 7; conc_dsts[0] = 3; conc_lens[0] = 5; conc_bases[0] = 32'hB100_0000;
        conc_senders[1] = 6; conc_dsts[1] = 2; conc_lens[1] = 4; conc_bases[1] = 32'hB200_0000;
        conc_senders[2] = 5; conc_dsts[2] = 1; conc_lens[2] = 6; conc_bases[2] = 32'hB300_0000;
        conc_senders[3] = 4; conc_dsts[3] = 0; conc_lens[3] = 3; conc_bases[3] = 32'hB400_0000;

        add_expected(3, 7, 3, 5, 32'hB100_0000);
        add_expected(2, 6, 2, 4, 32'hB200_0000);
        add_expected(1, 5, 1, 6, 32'hB300_0000);
        add_expected(0, 4, 0, 3, 32'hB400_0000);

        send_concurrent(4);
        wait_network_idle(TIMEOUT_CYCLES);
        repeat (2000) @(posedge clk);
        case_active = 0;
        repeat (10) @(posedge clk);

        check_scoreboard(2);
        $display("CASE 2 PASSED");

        //----------------------------------------------------------------------
        // CASE 3: Four sources to the SAME destination (Node4)
        //----------------------------------------------------------------------
        $display("============================================================");
        $display(" CASE 3: 4 sources -> single destination (Node4)");
        $display("============================================================");

        clear_scoreboard();
        case_active = 1;

        conc_senders[0] = 0; conc_dsts[0] = 4; conc_lens[0] = 3; conc_bases[0] = 32'hC100_0000;
        conc_senders[1] = 1; conc_dsts[1] = 4; conc_lens[1] = 5; conc_bases[1] = 32'hC200_0000;
        conc_senders[2] = 2; conc_dsts[2] = 4; conc_lens[2] = 2; conc_bases[2] = 32'hC300_0000;
        conc_senders[3] = 7; conc_dsts[3] = 4; conc_lens[3] = 4; conc_bases[3] = 32'hC400_0000;

        add_expected(4, 0, 4, 3, 32'hC100_0000);
        add_expected(4, 1, 4, 5, 32'hC200_0000);
        add_expected(4, 2, 4, 2, 32'hC300_0000);
        add_expected(4, 7, 4, 4, 32'hC400_0000);

        send_concurrent(4);
        wait_network_idle(TIMEOUT_CYCLES);
        repeat (4000) @(posedge clk);
        case_active = 0;
        repeat (10) @(posedge clk);

        check_scoreboard(3);
        $display("CASE 3 PASSED");

        //----------------------------------------------------------------------
        // CASE 4: Mixed broadcast + unicast
        //----------------------------------------------------------------------
        $display("============================================================");
        $display(" CASE 4: Mixed broadcast + 2 unicasts concurrently");
        $display("============================================================");

        clear_scoreboard();
        case_active = 1;

        conc_senders[0] = 2; conc_dsts[0] = BROADCAST; conc_lens[0] = 2; conc_bases[0] = 32'hD100_0000;
        conc_senders[1] = 0; conc_dsts[1] = 3; conc_lens[1] = 4; conc_bases[1] = 32'hD200_0000;
        conc_senders[2] = 5; conc_dsts[2] = 1; conc_lens[2] = 3; conc_bases[2] = 32'hD300_0000;

        for (n = 0; n < NUM_NODES; n = n + 1) begin
            if (n != 2)
                add_expected(n, 2, BROADCAST, 2, 32'hD100_0000);
        end
        add_expected(3, 0, 3, 4, 32'hD200_0000);
        add_expected(1, 5, 1, 3, 32'hD300_0000);

        send_concurrent(3);
        wait_network_idle(TIMEOUT_CYCLES);
        repeat (4000) @(posedge clk);
        case_active = 0;
        repeat (10) @(posedge clk);

        check_scoreboard(4);
        $display("CASE 4 PASSED");

        //----------------------------------------------------------------------
        // Final health check
        //----------------------------------------------------------------------
        $display("============================================================");
        $display(" Final health checks");

        for (n = 0; n < NUM_NODES; n = n + 1) begin
            if (rx_overflow[n])
                $display("WARNING: Node %0d rx_overflow asserted", n);
            if (app_len_error[n])
                $display("WARNING: Node %0d app_len_error asserted", n);
        end

        $display("============================================================");
        $display(" ALL CONCURRENT TRAFFIC TESTS PASSED");
        $display("============================================================");
        $finish;
    end

endmodule
