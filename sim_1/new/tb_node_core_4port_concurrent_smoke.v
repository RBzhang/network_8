`timescale 1ns/1ps

module tb_node_core_4port_concurrent_smoke;
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
    integer any_valid_out;
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
            any_valid_out <= 0;
        end else begin
            if (app_rx_frame_valid && app_rx_frame_ready)
                app_rx_count_seen <= app_rx_count_seen + 1;
            if (valid_out != 0)
                any_valid_out <= 1;
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

    task drive_idle_port;
        input integer port;
        input integer cycles;
        integer i;
        begin
            valid_in[port] = 1'b0;
            in_flat[port*32 +: 32] = 32'd0;
            for (i = 0; i < cycles; i = i + 1)
                @(posedge clk);
        end
    endtask

    task drive_all_idle;
        input integer cycles;
        integer i;
        begin
            valid_in = {NUM_PORTS{1'b0}};
            in_flat = {(NUM_PORTS*32){1'b0}};
            for (i = 0; i < cycles; i = i + 1)
                @(posedge clk);
        end
    endtask

    task inject_frame_1w_port;
        input integer port;
        input [7:0] src;
        input [7:0] dst;
        input [15:0] count;
        input [31:0] payload0;
        reg [31:0] crc;
        integer i;
        reg [NUM_PORTS-1:0] saved_valid;
        reg [NUM_PORTS*32-1:0] saved_flat;
        begin
            saved_valid = valid_in;
            saved_flat = in_flat;
            crc = 32'hFFFFFFFF;
            crc = crc32_word(crc, {src, dst, count});
            crc = crc32_word(crc, {16'd1, 16'd0});
            crc = crc32_word(crc, payload0);
            crc = crc ^ 32'hFFFFFFFF;
            valid_in = {NUM_PORTS{1'b0}};
            in_flat[port*32 +: 32] = 32'hCAFE_BABE;
            valid_in[port] = 1'b1;
            @(posedge clk);
            in_flat[port*32 +: 32] = SYNC_WORD;
            @(posedge clk);
            in_flat[port*32 +: 32] = {src, dst, count};
            @(posedge clk);
            in_flat[port*32 +: 32] = {16'd1, 16'd0};
            @(posedge clk);
            in_flat[port*32 +: 32] = payload0;
            @(posedge clk);
            in_flat[port*32 +: 32] = crc;
            @(posedge clk);
            valid_in[port] = 1'b0;
            in_flat[port*32 +: 32] = 32'd0;
            valid_in = saved_valid;
            in_flat = saved_flat;
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

        $display("Injecting 4 frames concurrently (port0..3 at ~2-cycle stagger)");
        $display("  port0: src=10,dst=1 (local)");
        $display("  port1: src=11,dst=2 (forward)");
        $display("  port2: src=12,dst=1 (local)");
        $display("  port3: src=13,dst=2 (forward)");

        @(posedge clk);
        inject_frame_1w_port(0, 8'd10, 8'd1, 16'd10, 32'hCC01_0001);
        @(posedge clk);
        @(posedge clk);
        inject_frame_1w_port(1, 8'd11, 8'd2, 16'd11, 32'hCC01_0002);
        @(posedge clk);
        @(posedge clk);
        inject_frame_1w_port(2, 8'd12, 8'd1, 16'd12, 32'hCC01_0003);
        @(posedge clk);
        @(posedge clk);
        inject_frame_1w_port(3, 8'd13, 8'd2, 16'd13, 32'hCC01_0004);

        repeat (500) @(posedge clk);

        if (app_rx_count_seen < 2)
            $fatal(1, "FAIL: expected at least 2 local app_rx frames, got %0d", app_rx_count_seen);
        if (any_valid_out == 0)
            $fatal(1, "FAIL: expected forward valid_out, none seen");
        $display("  PASS: app_rx received %0d local frames (expect >= 2)", app_rx_count_seen);
        $display("  PASS: valid_out seen for forwarded frames");

        $display("PASS: tb_node_core_4port_concurrent_smoke completed");
        $finish;
    end
endmodule
