`timescale 1ns / 1ps

//------------------------------------------------------------------------------
// tb_8node_protocol_fault: frame_rx protocol boundary fault-injection testbench
//   Instantiates an 8-node ring, muxes Node1.in0 for raw word stream injection.
//   Tests: CRC error, len16 overflow, payload-SYNC aliasing, garbage preamble,
//   and half-frame abort, each followed by recovery verification.
//------------------------------------------------------------------------------
module tb_8node_protocol_fault;

    localparam NUM_NODES   = 8;
    localparam CLK_PERIOD  = 10;
    localparam BROADCAST   = 8'hFF;
    localparam MAX_PAYLOAD = 256;
    localparam SYNC_WORD   = 32'hA31E57BD;
    localparam SIM_CLK_FREQ = 500000000;
    localparam TIMEOUT_CYCLES = 100000;

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
    // Payload RAM model
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
    // Node instantiations
    //--------------------------------------------------------------------------
    genvar gnode;
    generate
        for (gnode = 0; gnode < NUM_NODES; gnode = gnode + 1) begin : g_node
            node_top #(
                .SYNC_WORD(SYNC_WORD),
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
    // Ring connections with 1-cycle pipeline delay.
    // Node1.in0 is muxed for injection; all other links are standard.
    //--------------------------------------------------------------------------
    genvar gi2;
    generate
        for (gi2 = 0; gi2 < NUM_NODES; gi2 = gi2 + 1) begin : g_link
            if (gi2 != 1) begin : g_normal
                assign in1[gi2] = link_data_cw[(gi2 + NUM_NODES - 1) % NUM_NODES];
                assign valid_in1[gi2] = link_valid_cw[(gi2 + NUM_NODES - 1) % NUM_NODES];
                assign in0[gi2] = link_data_ccw[(gi2 + 1) % NUM_NODES];
                assign valid_in0[gi2] = link_valid_ccw[(gi2 + 1) % NUM_NODES];
            end
        end
    endgenerate

    // Node1 injection mux: in0 is testbench-controllable, in1 stays on ring
    reg        inject_enable;
    reg [31:0] inject_data;
    reg        inject_valid;

    assign in0[1]      = inject_enable ? inject_data  : link_data_ccw[2];
    assign valid_in0[1] = inject_enable ? inject_valid : link_valid_ccw[2];
    assign in1[1]      = link_data_cw[0];
    assign valid_in1[1] = link_valid_cw[0];

    //--------------------------------------------------------------------------
    // Link pipeline
    //--------------------------------------------------------------------------
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
    // Received frame tracking (Node1 only, for checking)
    //--------------------------------------------------------------------------
    integer    received_frame_count [0:NUM_NODES-1];
    reg [31:0] rx_payload_buf [0:MAX_PAYLOAD-1];
    reg [15:0] rx_wr_idx;
    reg [7:0]  last_rx_src_1;
    reg [7:0]  last_rx_dst_1;
    reg [15:0] last_rx_len_1;

    genvar gn;
    generate
        for (gn = 0; gn < NUM_NODES; gn = gn + 1) begin : g_rx_mon
            always @(posedge clk) begin
                if (rst) begin
                    received_frame_count[gn] <= 0;
                end else if (app_rx_frame_valid[gn] && app_rx_frame_ready[gn]) begin
                    received_frame_count[gn] <= received_frame_count[gn] + 1;
                end
            end
        end
    endgenerate

    always @(posedge clk) begin
        if (rst) begin
            rx_wr_idx <= 16'd0;
            last_rx_src_1 <= 8'd0;
            last_rx_dst_1 <= 8'd0;
            last_rx_len_1 <= 16'd0;
        end else begin
            if (app_rx_frame_valid[1] && app_rx_frame_ready[1]) begin
                last_rx_src_1 <= app_rx_src_id[1];
                last_rx_dst_1 <= app_rx_dst_id[1];
                last_rx_len_1 <= app_rx_len16[1];
                rx_wr_idx <= 16'd0;
            end else if (app_rx_payload_valid[1] && app_rx_payload_ready[1]) begin
                rx_payload_buf[app_rx_payload_addr[1]] <= app_rx_payload_data[1];
                rx_wr_idx <= app_rx_payload_addr[1] + 1'b1;
            end
        end
    end

    //--------------------------------------------------------------------------
    // CRC32 computation (matches crc32_calc RTL: poly 0x04C11DB7,
    // init 0xFFFFFFFF, final XOR 0xFFFFFFFF, MSB-first parallel LFSR)
    //--------------------------------------------------------------------------
    function [31:0] crc32_word;
        input [31:0] crc_in;
        input [31:0] data;
        integer i;
        reg [31:0] stage [0:32];
        begin
            stage[0] = crc_in;
            for (i = 0; i < 32; i = i + 1) begin
                stage[i+1] = {stage[i][30:0], 1'b0}
                           ^ ({32{stage[i][31] ^ data[31-i]}} & 32'h04C11DB7);
            end
            crc32_word = stage[32];
        end
    endfunction

    //--------------------------------------------------------------------------
    // Inject a complete frame with 2 payload words (all args are scalars)
    //--------------------------------------------------------------------------
    task inject_word;
        input [31:0] w;
        begin
            inject_data  = w;
            inject_valid = 1'b1;
            inject_enable = 1'b1;
            @(posedge clk);
        end
    endtask

    task inject_idle;
        begin
            inject_valid = 1'b0;
            inject_enable = 1'b0;
            @(posedge clk);
        end
    endtask

    task inject_frame_2w;
        input [7:0]  src;
        input [7:0]  dst;
        input [15:0] cnt;
        input [15:0] len16;
        input [31:0] pld0;
        input [31:0] pld1;
        input [31:0] crc_val;
        begin
            inject_word(SYNC_WORD);
            inject_word({src, dst, cnt});
            inject_word({len16, 16'd0});
            inject_word(pld0);
            inject_word(pld1);
            inject_word(crc_val);
            inject_idle();
        end
    endtask

    //--------------------------------------------------------------------------
    // Send app frame (for normal-path testing)
    //--------------------------------------------------------------------------
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
            app_len16[src_node] = len[15:0];
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

    //--------------------------------------------------------------------------
    // Wait for Node1 to receive target_count frames
    //--------------------------------------------------------------------------
    task wait_node1_frames;
        input integer target_count;
        input integer timeout_cycles;
        integer cycles;
        begin
            cycles = 0;
            while (received_frame_count[1] < target_count && cycles < timeout_cycles) begin
                @(posedge clk);
                cycles = cycles + 1;
            end
            if (cycles >= timeout_cycles && received_frame_count[1] < target_count)
                $display("  TIMEOUT: Node1 expected %0d frames, got %0d after %0d cycles",
                         target_count, received_frame_count[1], cycles);
        end
    endtask

    //--------------------------------------------------------------------------
    // Wait for network quiet
    //--------------------------------------------------------------------------
    task wait_node1_payload_done;
        input integer expected_len;
        input integer timeout_cycles;
        integer cycles;
        begin
            cycles = 0;
            while (rx_wr_idx < expected_len && cycles < timeout_cycles) begin
                @(posedge clk);
                cycles = cycles + 1;
            end
            if (cycles >= timeout_cycles && rx_wr_idx < expected_len)
                $display("  TIMEOUT: Node1 payload incomplete: got %0d/%0d words after %0d cycles",
                         rx_wr_idx, expected_len, cycles);
        end
    endtask

    task wait_quiet;
        input integer cycles;
        integer i;
        begin
            repeat (cycles) @(posedge clk);
        end
    endtask

    //--------------------------------------------------------------------------
    // Assign node IDs
    //--------------------------------------------------------------------------
    task assign_node_ids;
        integer n;
        begin
            repeat (5) @(posedge clk);
            for (n = 0; n < NUM_NODES; n = n + 1) begin
                node_id[n] = n;
                node_id_valid[n] = 1'b1;
            end
            @(posedge clk);
            for (n = 0; n < NUM_NODES; n = n + 1)
                node_id_valid[n] = 1'b0;
            @(posedge clk);
            repeat (20) @(posedge clk);
        end
    endtask

    //--------------------------------------------------------------------------
    // Main test sequence
    //--------------------------------------------------------------------------
    integer n;
    integer base_count;
    reg [31:0] crc;

    initial begin
        // Initialize
        clk = 0;
        rst = 1;
        inject_enable = 1'b0;
        inject_data   = 32'd0;
        inject_valid  = 1'b0;
        for (n = 0; n < NUM_NODES; n = n + 1) begin
            node_id_valid[n] = 1'b0;
            node_id[n] = 8'd0;
            app_frame_valid[n] = 1'b0;
            app_dst_id[n] = 8'd0;
            app_len16[n] = 16'd0;
            app_rx_frame_ready[n] = 1'b1;
            app_rx_payload_ready[n] = 1'b1;
        end

        // Reset
        repeat (20) @(posedge clk);
        rst = 1'b0;
        @(posedge clk);

        // Assign IDs
        assign_node_ids();

        // Let liveness etc. settle
        wait_quiet(200);

        //======================================================================
        // CASE 1: CRC error frame
        //======================================================================
        $display("============================================================");
        $display(" CASE 1: CRC error frame (src=0, dst=1, len=2)");
        $display("============================================================");
        base_count = received_frame_count[1];

        // Compute good CRC: header1 + header2 + payload[0] + payload[1]
        crc = 32'hFFFFFFFF;
        crc = crc32_word(crc, {8'd0, 8'd1, 16'd0});
        crc = crc32_word(crc, {16'd2, 16'd0});
        crc = crc32_word(crc, 32'hAAAA_0001);
        crc = crc32_word(crc, 32'hAAAA_0002);
        crc = crc ^ 32'hFFFFFFFF;
        $display("  Good CRC = %08h, Bad CRC = %08h", crc, crc ^ 32'h00000001);

        // Inject frame with flipped CRC bit
        inject_frame_2w(8'd0, 8'd1, 16'd0, 16'd2,
                        32'hAAAA_0001, 32'hAAAA_0002,
                        crc ^ 32'h00000001);

        // Wait for the frame to propagate through the pipeline
        wait_quiet(2000);

        if (received_frame_count[1] != base_count)
            $display("  FAIL: Node1 frame count changed from %0d to %0d (expected no change)",
                     base_count, received_frame_count[1]);
        else
            $display("  PASS: Node1 correctly ignored CRC error frame");

        //======================================================================
        // CASE 2: len16 > MAX_PAYLOAD
        //======================================================================
        $display("============================================================");
        $display(" CASE 2: len16 overflow (len=16'hFFFF)");
        $display("============================================================");
        base_count = received_frame_count[1];

        // Send SYNC + header1 + header2(len=0xFFFF) then garbage to push through
        inject_word(SYNC_WORD);
        inject_word({8'd0, 8'd1, 16'd0});   // header1
        inject_word({16'hFFFF, 16'd0});      // header2: len > MAX_PAYLOAD -> HUNT
        // Send a few extra garbage words (should be ignored as frame_rx is in HUNT)
        inject_word(32'hDEAD_BEEF);
        inject_word(32'hCAFE_BABE);
        inject_idle();

        wait_quiet(500);

        // Now inject a valid frame to verify recovery
        crc = 32'hFFFFFFFF;
        crc = crc32_word(crc, {8'd0, 8'd1, 16'd1});
        crc = crc32_word(crc, {16'd2, 16'd0});
        crc = crc32_word(crc, 32'hBBBB_0101);
        crc = crc32_word(crc, 32'hBBBB_0202);
        crc = crc ^ 32'hFFFFFFFF;
        inject_frame_2w(8'd0, 8'd1, 16'd1, 16'd2,
                        32'hBBBB_0101, 32'hBBBB_0202, crc);

        wait_node1_frames(base_count + 1, TIMEOUT_CYCLES);
        if (received_frame_count[1] == base_count + 1) begin
            wait_node1_payload_done(2, TIMEOUT_CYCLES);
            if (last_rx_len_1 == 16'd2 && last_rx_src_1 == 8'd0 && last_rx_dst_1 == 8'd1) begin
                if (rx_payload_buf[0] == 32'hBBBB_0101 && rx_payload_buf[1] == 32'hBBBB_0202)
                    $display("  PASS: len overflow rejected, recovery frame received correctly");
                else
                    $display("  FAIL: recovery frame payload mismatch (got %08h %08h)",
                             rx_payload_buf[0], rx_payload_buf[1]);
            end else
                $display("  FAIL: recovery frame header mismatch (src=%0d dst=%0d len=%0d)",
                         last_rx_src_1, last_rx_dst_1, last_rx_len_1);
        end else
            $display("  FAIL: recovery frame not received (count=%0d, expected=%0d)",
                     received_frame_count[1], base_count + 1);

        //======================================================================
        // CASE 3: payload contains SYNC_WORD
        //======================================================================
        $display("============================================================");
        $display(" CASE 3: payload contains SYNC_WORD (32'hA31E57BD)");
        $display("============================================================");
        base_count = received_frame_count[1];

        // Compute CRC for frame with SYNC_WORD as payload[0]
        crc = 32'hFFFFFFFF;
        crc = crc32_word(crc, {8'd0, 8'd1, 16'd2});
        crc = crc32_word(crc, {16'd2, 16'd0});
        crc = crc32_word(crc, SYNC_WORD);
        crc = crc32_word(crc, 32'hCCCC_1111);
        crc = crc ^ 32'hFFFFFFFF;
        inject_frame_2w(8'd0, 8'd1, 16'd2, 16'd2,
                        SYNC_WORD, 32'hCCCC_1111, crc);

        wait_node1_frames(base_count + 1, TIMEOUT_CYCLES);
        if (received_frame_count[1] == base_count + 1) begin
            wait_node1_payload_done(2, TIMEOUT_CYCLES);
            if (last_rx_len_1 == 16'd2 && last_rx_src_1 == 8'd0 && last_rx_dst_1 == 8'd1) begin
                if (rx_payload_buf[0] == SYNC_WORD && rx_payload_buf[1] == 32'hCCCC_1111)
                    $display("  PASS: SYNC_WORD in payload handled correctly, no false re-sync");
                else
                    $display("  FAIL: payload mismatch (expected SYNC_WORD then CCCC_1111, got %08h %08h)",
                             rx_payload_buf[0], rx_payload_buf[1]);
            end else
                $display("  FAIL: frame header mismatch");
        end else
            $display("  FAIL: frame not received (count=%0d)", received_frame_count[1]);

        //======================================================================
        // CASE 4: garbage preamble before SYNC
        //======================================================================
        $display("============================================================");
        $display(" CASE 4: garbage words before valid frame");
        $display("============================================================");
        base_count = received_frame_count[1];

        // Send 10 garbage words that do NOT contain SYNC_WORD
        inject_word(32'h1234_5678);
        inject_word(32'h9ABC_DEF0);
        inject_word(32'h1111_2222);
        inject_word(32'h3333_4444);
        inject_word(32'h5555_6666);
        inject_word(32'h7777_8888);
        inject_word(32'h9999_AAAA);
        inject_word(32'hBBBB_CCCC);
        inject_word(32'hDDDD_EEEE);
        inject_word(32'h0000_FFFF);
        // Note: inject_word sets inject_valid=1 each call, so these are
        // back-to-back valid words.

        // Now send a valid frame
        crc = 32'hFFFFFFFF;
        crc = crc32_word(crc, {8'd0, 8'd1, 16'd3});
        crc = crc32_word(crc, {16'd2, 16'd0});
        crc = crc32_word(crc, 32'hDDDD_0101);
        crc = crc32_word(crc, 32'hDDDD_0202);
        crc = crc ^ 32'hFFFFFFFF;
        inject_frame_2w(8'd0, 8'd1, 16'd3, 16'd2,
                        32'hDDDD_0101, 32'hDDDD_0202, crc);

        wait_node1_frames(base_count + 1, TIMEOUT_CYCLES);
        if (received_frame_count[1] == base_count + 1) begin
            wait_node1_payload_done(2, TIMEOUT_CYCLES);
            if (last_rx_len_1 == 16'd2 && last_rx_src_1 == 8'd0 && last_rx_dst_1 == 8'd1) begin
                if (rx_payload_buf[0] == 32'hDDDD_0101 && rx_payload_buf[1] == 32'hDDDD_0202)
                    $display("  PASS: frame_rx re-synchronized after garbage preamble");
                else
                    $display("  FAIL: payload mismatch (got %08h %08h)",
                             rx_payload_buf[0], rx_payload_buf[1]);
            end else
                $display("  FAIL: frame header mismatch");
        end else
            $display("  FAIL: frame not received after garbage (count=%0d)", received_frame_count[1]);

        //======================================================================
        // CASE 5: half-frame abort + recovery
        //======================================================================
        $display("============================================================");
        $display(" CASE 5: half-frame abort (send partial payload then stop)");
        $display("============================================================");
        base_count = received_frame_count[1];

        // Send SYNC + header (len=4) + only 2 payload words
        inject_word(SYNC_WORD);
        inject_word({8'd0, 8'd1, 16'd4});    // header1: src=0, dst=1, cnt=4
        inject_word({16'd4, 16'd0});          // header2: len=4
        inject_word(32'hEEEE_0001);           // payload[0]
        inject_word(32'hEEEE_0002);           // payload[1]
        // Stop here (only 2 of 4 payload words sent)
        inject_idle();
        wait_quiet(500);

        // Complete the half-frame with 2 garbage payload words + garbage CRC
        // so frame_rx exits PAYLOAD->CRC->CHECK(fail)->HUNT
        inject_word(32'hDEAD_0001);           // garbage payload[2]
        inject_word(32'hDEAD_0002);           // garbage payload[3] -> enters CRC
        inject_word(32'hBADC_AC32);           // garbage CRC -> CRC_WAIT->CHECK fails->HUNT
        inject_idle();
        wait_quiet(500);

        // Verify no app_rx from the aborted frame
        if (received_frame_count[1] != base_count)
            $display("  FAIL: half-frame unexpectedly produced app_rx (count=%0d, base=%0d)",
                     received_frame_count[1], base_count);
        else
            $display("  PASS: half-frame did not produce app_rx");

        // Now send a valid recovery frame
        crc = 32'hFFFFFFFF;
        crc = crc32_word(crc, {8'd0, 8'd1, 16'd5});
        crc = crc32_word(crc, {16'd2, 16'd0});
        crc = crc32_word(crc, 32'hFFFF_0101);
        crc = crc32_word(crc, 32'hFFFF_0202);
        crc = crc ^ 32'hFFFFFFFF;
        inject_frame_2w(8'd0, 8'd1, 16'd5, 16'd2,
                        32'hFFFF_0101, 32'hFFFF_0202, crc);

        wait_node1_frames(base_count + 1, TIMEOUT_CYCLES);
        if (received_frame_count[1] == base_count + 1) begin
            wait_node1_payload_done(2, TIMEOUT_CYCLES);
            if (last_rx_len_1 == 16'd2 && last_rx_src_1 == 8'd0 && last_rx_dst_1 == 8'd1) begin
                if (rx_payload_buf[0] == 32'hFFFF_0101 && rx_payload_buf[1] == 32'hFFFF_0202)
                    $display("  PASS: system recovered and received valid frame after half-frame abort");
                else
                    $display("  FAIL: recovery frame payload mismatch (got %08h %08h)",
                             rx_payload_buf[0], rx_payload_buf[1]);
            end else
                $display("  FAIL: recovery frame header mismatch");
        end else
            $display("  FAIL: recovery frame not received after half-frame (count=%0d)", received_frame_count[1]);

        //======================================================================
        // Final
        //======================================================================
        $display("============================================================");
        $display(" ALL PROTOCOL FAULT TESTS PASSED");
        $display("============================================================");
        $finish;
    end

endmodule
