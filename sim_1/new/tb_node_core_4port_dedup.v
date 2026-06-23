`timescale 1ns/1ps

module tb_node_core_4port_dedup;
    localparam NUM_PORTS = 4;
    localparam CLK_PERIOD = 10;
    localparam SYNC_WORD = 32'hA31E57BD;
    localparam TIMEOUT_CYCLES = 5000;

    reg clk;
    reg rst;
    reg node_id_valid;
    reg [7:0] node_id;
    reg [NUM_PORTS*32-1:0] in_flat;
    reg [NUM_PORTS-1:0] valid_in;
    wire [NUM_PORTS*32-1:0] out_flat;
    wire [NUM_PORTS-1:0] valid_out;

    reg app_frame_valid;
    wire app_frame_ready;
    wire app_frame_accepted;
    wire app_frame_done;
    reg [7:0] app_dst_id;
    reg [15:0] app_len16;
    wire [15:0] app_payload_addr;
    reg [31:0] app_payload_data;
    wire app_rx_frame_valid;
    reg app_rx_frame_ready;
    wire [7:0] app_rx_src_id;
    wire [7:0] app_rx_dst_id;
    wire [15:0] app_rx_count;
    wire [15:0] app_rx_len16;
    wire app_rx_payload_valid;
    reg app_rx_payload_ready;
    wire [15:0] app_rx_payload_addr;
    wire [31:0] app_rx_payload_data;
    wire liveness_valid;
    wire [7:0] liveness_node;
    wire liveness_alive;
    wire network_congested;
    wire app_len_error;
    wire rx_overflow;

    integer app_rx_count_seen;
    integer valid_out_port0, valid_out_port1, valid_out_port2, valid_out_port3;
    integer out_word_count;
    integer port0_base, port1_base, port2_base, port3_base;
    always #(CLK_PERIOD/2) clk = ~clk;

    node_core #(
        .NUM_PORTS(NUM_PORTS),
        .FIFO_DEPTH(8192),
        .RX_REPORT_FIFO_DEPTH(2048),
        .CLK_FREQ_HZ(100_000_000),
        .CONGEST_TIMEOUT_SEC(5),
        .TX_QUEUE_TIMEOUT_SEC(5),
        .TX_QUEUE_TIMEOUT_CYCLES(500_000_000)
    ) dut (
        .clk(clk),
        .rst(rst),
        .node_id_valid(node_id_valid),
        .node_id(node_id),
        .rx_clk({NUM_PORTS{clk}}),
        .tx_clk({NUM_PORTS{clk}}),
        .in_flat(in_flat),
        .valid_in(valid_in),
        .app_frame_valid(app_frame_valid),
        .app_frame_ready(app_frame_ready),
        .app_frame_accepted(app_frame_accepted),
        .app_frame_done(app_frame_done),
        .app_dst_id(app_dst_id),
        .app_len16(app_len16),
        .app_payload_addr(app_payload_addr),
        .app_payload_data(app_payload_data),
        .app_rx_frame_valid(app_rx_frame_valid),
        .app_rx_frame_ready(app_rx_frame_ready),
        .app_rx_src_id(app_rx_src_id),
        .app_rx_dst_id(app_rx_dst_id),
        .app_rx_count(app_rx_count),
        .app_rx_len16(app_rx_len16),
        .app_rx_payload_valid(app_rx_payload_valid),
        .app_rx_payload_ready(app_rx_payload_ready),
        .app_rx_payload_addr(app_rx_payload_addr),
        .app_rx_payload_data(app_rx_payload_data),
        .out_flat(out_flat),
        .valid_out(valid_out),
        .liveness_valid(liveness_valid),
        .liveness_node(liveness_node),
        .liveness_alive(liveness_alive),
        .network_congested(network_congested),
        .app_len_error(app_len_error),
        .rx_overflow(rx_overflow)
    );

    always @(posedge clk) begin
        if (rst) begin
            app_rx_count_seen <= 0;
            valid_out_port0 <= 0;
            valid_out_port1 <= 0;
            valid_out_port2 <= 0;
            valid_out_port3 <= 0;
            out_word_count <= 0;
        end else begin
            if (app_rx_frame_valid && app_rx_frame_ready) begin
                app_rx_count_seen <= app_rx_count_seen + 1;
            end
            if (valid_out[0]) valid_out_port0 <= valid_out_port0 + 1;
            if (valid_out[1]) valid_out_port1 <= valid_out_port1 + 1;
            if (valid_out[2]) valid_out_port2 <= valid_out_port2 + 1;
            if (valid_out[3]) valid_out_port3 <= valid_out_port3 + 1;
            if (valid_out != 0)
                out_word_count <= out_word_count + 1;
        end
    end

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

    task drive_word;
        input integer port;
        input [31:0] word;
        begin
            in_flat[port*32 +: 32] = word;
            valid_in[port] = 1'b1;
            @(posedge clk);
        end
    endtask

    task drive_idle;
        input integer cycles;
        integer i;
        begin
            valid_in = {NUM_PORTS{1'b0}};
            in_flat = {(NUM_PORTS*32){1'b0}};
            for (i = 0; i < cycles; i = i + 1)
                @(posedge clk);
        end
    endtask

    task inject_frame_1w;
        input integer port;
        input [7:0] src;
        input [7:0] dst;
        input [15:0] count;
        input [31:0] payload0;
        reg [31:0] crc;
        begin
            crc = 32'hFFFFFFFF;
            crc = crc32_word(crc, {src, dst, count});
            crc = crc32_word(crc, {16'd1, 16'd0});
            crc = crc32_word(crc, payload0);
            crc = crc ^ 32'hFFFFFFFF;
            drive_word(port, 32'hCAFE_BABE);
            drive_word(port, SYNC_WORD);
            drive_word(port, {src, dst, count});
            drive_word(port, {16'd1, 16'd0});
            drive_word(port, payload0);
            drive_word(port, crc);
            drive_idle(4);
        end
    endtask

    task wait_for_app_rx;
        input integer expected_count;
        input [7:0] expected_src;
        input [7:0] expected_dst;
        integer cycles;
        begin
            cycles = 0;
            while (app_rx_count_seen < expected_count && cycles < TIMEOUT_CYCLES) begin
                @(posedge clk);
                cycles = cycles + 1;
            end
            if (app_rx_count_seen < expected_count)
                $fatal(1, "TIMEOUT: expected app_rx count %0d got %0d", expected_count, app_rx_count_seen);
            if (app_rx_src_id !== expected_src || app_rx_dst_id !== expected_dst || app_rx_len16 !== 16'd1)
                $fatal(1, "FAIL: app_rx header src=%0d dst=%0d len=%0d", app_rx_src_id, app_rx_dst_id, app_rx_len16);
        end
    endtask

    task wait_quiet;
        input integer quiet_cycles;
        integer cycles;
        integer quiet_seen;
        begin
            cycles = 0;
            quiet_seen = 0;
            while (quiet_seen < quiet_cycles && cycles < TIMEOUT_CYCLES) begin
                @(posedge clk);
                cycles = cycles + 1;
                if (valid_out == {NUM_PORTS{1'b0}})
                    quiet_seen = quiet_seen + 1;
                else
                    quiet_seen = 0;
            end
            if (quiet_seen < quiet_cycles)
                $fatal(1, "TIMEOUT: valid_out did not go quiet");
        end
    endtask

    task count_valid_out_words;
        input integer port;
        input integer expected_min;
        integer seen;
        begin
            case (port)
                0: seen = valid_out_port0;
                1: seen = valid_out_port1;
                2: seen = valid_out_port2;
                3: seen = valid_out_port3;
                default: seen = 0;
            endcase
            if (seen < expected_min)
                $fatal(1, "FAIL: port %0d valid_out words %0d < %0d", port, seen, expected_min);
        end
    endtask

    initial begin
        clk = 1'b0;
        rst = 1'b1;
        node_id_valid = 1'b0;
        node_id = 8'd0;
        in_flat = {(NUM_PORTS*32){1'b0}};
        valid_in = {NUM_PORTS{1'b0}};
        app_frame_valid = 1'b0;
        app_dst_id = 8'd0;
        app_len16 = 16'd0;
        app_payload_data = 32'd0;
        app_rx_frame_ready = 1'b1;
        app_rx_payload_ready = 1'b1;

        repeat (20) @(posedge clk);
        rst = 1'b0;
        repeat (5) @(posedge clk);
        node_id = 8'd1;
        node_id_valid = 1'b1;
        @(posedge clk);
        node_id_valid = 1'b0;
        repeat (20) @(posedge clk);

        $display("CASE 1: Local delivery dedup");
        $display("  Inject local frame src=9,dst=1,count=100 from port0");
        inject_frame_1w(0, 8'd9, 8'd1, 16'd100, 32'hDEDD_0001);
        wait_for_app_rx(1, 8'd9, 8'd1);
        $display("  app_rx received frame (1/1)");

        $display("  Inject same frame src=9,dst=1,count=100 from port2");
        inject_frame_1w(2, 8'd9, 8'd1, 16'd100, 32'hDEDD_0001);

        wait_quiet(30);
        if (app_rx_count_seen > 1)
            $fatal(1, "FAIL: duplicate local frame reported, app_rx count=%0d expected 1", app_rx_count_seen);
        $display("  PASS: duplicate local frame NOT reported to app_rx, count=%0d", app_rx_count_seen);

        $display("CASE 2: Forward dedup");
        $display("  Inject forward frame src=9,dst=2,count=101 from port0");
        inject_frame_1w(0, 8'd9, 8'd2, 16'd101, 32'hDEDD_0002);
        wait_quiet(50);
        $display("  First forward: valid_out words total=%0d", out_word_count);

        count_valid_out_words(1, 5);
        count_valid_out_words(2, 5);
        count_valid_out_words(3, 5);
        $display("  First forward produced valid_out on ports 1,2,3");

        port0_base = valid_out_port0;
        port1_base = valid_out_port1;
        port2_base = valid_out_port2;
        port3_base = valid_out_port3;

        $display("  Inject duplicate frame src=9,dst=2,count=101 from port2");
        inject_frame_1w(2, 8'd9, 8'd2, 16'd101, 32'hDEDD_0002);
        wait_quiet(30);

        if (valid_out_port0 > port0_base + 1)
            $fatal(1, "FAIL: duplicate caused extra valid_out on port0, was %0d now %0d", port0_base, valid_out_port0);
        if (valid_out_port1 > port1_base + 1)
            $fatal(1, "FAIL: duplicate caused extra valid_out on port1, was %0d now %0d", port1_base, valid_out_port1);
        if (valid_out_port2 > port2_base + 1)
            $fatal(1, "FAIL: duplicate caused extra valid_out on port2, was %0d now %0d", port2_base, valid_out_port2);
        if (valid_out_port3 > port3_base + 1)
            $fatal(1, "FAIL: duplicate caused extra valid_out on port3, was %0d now %0d", port3_base, valid_out_port3);
        $display("  PASS: duplicate forward frame did NOT produce additional forward output");

        $display("PASS: tb_node_core_4port_dedup completed");
        $finish;
    end
endmodule
