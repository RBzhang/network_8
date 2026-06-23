`timescale 1ns/1ps

module tb_node_top_3port_functional;
    localparam NUM_PORTS = 3;
    localparam CLK_PERIOD = 10;
    localparam SYNC_WORD = 32'hA31E57BD;
    localparam TIMEOUT_CYCLES = 3000;

    reg clk;
    reg rst;
    reg node_id_valid;
    reg [7:0] node_id;

    reg [31:0] in0, in1, in2;
    reg valid_in0, valid_in1, valid_in2;
    wire [31:0] out0, out1, out2;
    wire valid_out0, valid_out1, valid_out2;

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
    always #(CLK_PERIOD/2) clk = ~clk;

    node_top_3port #(
        .FIFO_DEPTH(8192),
        .RX_REPORT_FIFO_DEPTH(2048),
        .CLK_FREQ_HZ(100_000_000),
        .CONGEST_TIMEOUT_SEC(5),
        .TX_QUEUE_TIMEOUT_SEC(5),
        .TX_QUEUE_TIMEOUT_CYCLES(500_000_000)
    ) dut (
        .clk(clk), .rst(rst), .node_id_valid(node_id_valid), .node_id(node_id),
        .rx_clk0(clk), .rx_clk1(clk), .rx_clk2(clk),
        .tx_clk0(clk), .tx_clk1(clk), .tx_clk2(clk),
        .in0(in0), .in1(in1), .in2(in2),
        .valid_in0(valid_in0), .valid_in1(valid_in1), .valid_in2(valid_in2),
        .app_frame_valid(app_frame_valid), .app_frame_ready(app_frame_ready),
        .app_frame_accepted(app_frame_accepted), .app_frame_done(app_frame_done),
        .app_dst_id(app_dst_id), .app_len16(app_len16),
        .app_payload_addr(app_payload_addr), .app_payload_data(app_payload_data),
        .app_rx_frame_valid(app_rx_frame_valid), .app_rx_frame_ready(app_rx_frame_ready),
        .app_rx_src_id(app_rx_src_id), .app_rx_dst_id(app_rx_dst_id),
        .app_rx_count(app_rx_count), .app_rx_len16(app_rx_len16),
        .app_rx_payload_valid(app_rx_payload_valid), .app_rx_payload_ready(app_rx_payload_ready),
        .app_rx_payload_addr(app_rx_payload_addr), .app_rx_payload_data(app_rx_payload_data),
        .out0(out0), .out1(out1), .out2(out2),
        .valid_out0(valid_out0), .valid_out1(valid_out1), .valid_out2(valid_out2),
        .liveness_valid(liveness_valid), .liveness_node(liveness_node),
        .liveness_alive(liveness_alive), .network_congested(network_congested),
        .app_len_error(app_len_error), .rx_overflow(rx_overflow)
    );

    always @(posedge clk) begin
        if (rst) begin
            app_rx_count_seen <= 0;
        end else begin
            if (app_rx_frame_valid && app_rx_frame_ready) begin
                app_rx_count_seen <= app_rx_count_seen + 1;
            end
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
            case (port)
                0: begin in0 = word; valid_in0 = 1'b1; valid_in1 = 1'b0; valid_in2 = 1'b0; end
                1: begin in1 = word; valid_in0 = 1'b0; valid_in1 = 1'b1; valid_in2 = 1'b0; end
                2: begin in2 = word; valid_in0 = 1'b0; valid_in1 = 1'b0; valid_in2 = 1'b1; end
            endcase
            @(posedge clk);
        end
    endtask

    task drive_idle;
        input integer cycles;
        integer i;
        begin
            valid_in0 = 1'b0; valid_in1 = 1'b0; valid_in2 = 1'b0;
            in0 = 32'd0; in1 = 32'd0; in2 = 32'd0;
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

    task wait_for_app_rx_timeout;
        input integer expected_count;
        integer cycles;
        begin
            cycles = 0;
            while (app_rx_count_seen < expected_count && cycles < TIMEOUT_CYCLES) begin
                @(posedge clk);
                cycles = cycles + 1;
            end
            if (app_rx_count_seen < expected_count)
                $fatal(1, "TIMEOUT: expected app_rx count %0d got %0d", expected_count, app_rx_count_seen);
        end
    endtask

    task wait_for_output_ports;
        input [NUM_PORTS-1:0] required_mask;
        input [NUM_PORTS-1:0] forbidden_mask;
        input integer baseline_app_count;
        integer cycles;
        reg [NUM_PORTS-1:0] observed;
        reg [NUM_PORTS-1:0] cur_v;
        begin
            observed = {NUM_PORTS{1'b0}};
            cycles = 0;
            while (((observed & required_mask) != required_mask) && cycles < TIMEOUT_CYCLES) begin
                @(posedge clk);
                cycles = cycles + 1;
                cur_v = {valid_out2, valid_out1, valid_out0};
                observed = observed | cur_v;
                if ((cur_v & forbidden_mask) != {NUM_PORTS{1'b0}})
                    $fatal(1, "FAIL: forbidden valid_out mask %b appeared in {%b,%b,%b}", forbidden_mask, valid_out2, valid_out1, valid_out0);
            end
            if ((observed & required_mask) != required_mask)
                $fatal(1, "TIMEOUT: required valid_out mask %b, seen %b", required_mask, observed);
            if (app_rx_count_seen != baseline_app_count)
                $fatal(1, "FAIL: forwarded frame leaked to app_rx, app count %0d baseline %0d", app_rx_count_seen, baseline_app_count);
        end
    endtask

    task wait_outputs_quiet;
        input integer quiet_cycles;
        integer cycles;
        integer quiet_seen;
        reg [NUM_PORTS-1:0] cur_v;
        begin
            cycles = 0;
            quiet_seen = 0;
            while (quiet_seen < quiet_cycles && cycles < TIMEOUT_CYCLES) begin
                @(posedge clk);
                cycles = cycles + 1;
                cur_v = {valid_out2, valid_out1, valid_out0};
                if (cur_v == {NUM_PORTS{1'b0}})
                    quiet_seen = quiet_seen + 1;
                else
                    quiet_seen = 0;
            end
            if (quiet_seen < quiet_cycles)
                $fatal(1, "TIMEOUT: valid_out did not go quiet");
        end
    endtask

    initial begin
        clk = 1'b0;
        rst = 1'b1;
        node_id_valid = 1'b0;
        node_id = 8'd0;
        in0 = 32'd0; in1 = 32'd0; in2 = 32'd0;
        valid_in0 = 1'b0; valid_in1 = 1'b0; valid_in2 = 1'b0;
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

        $display("CASE 1: in0 inject dst=1 local frame via wrapper");
        inject_frame_1w(0, 8'd9, 8'd1, 16'd1, 32'hAAAA_0001);
        wait_for_app_rx_timeout(1);
        if (app_rx_src_id !== 8'd9 || app_rx_dst_id !== 8'd1 || app_rx_len16 !== 16'd1)
            $fatal(1, "FAIL: app_rx header mismatch src=%0d dst=%0d len=%0d", app_rx_src_id, app_rx_dst_id, app_rx_len16);
        $display("  PASS: app_rx received local frame via wrapper");

        $display("CASE 2: in0 inject dst=2 forward frame via wrapper");
        inject_frame_1w(0, 8'd9, 8'd2, 16'd2, 32'hAAAA_0002);
        wait_for_output_ports(3'b110, 3'b001, app_rx_count_seen);
        wait_outputs_quiet(20);
        $display("  PASS: valid_out on out1/out2, not out0, no app_rx leak");

        $display("CASE 3: in1 inject dst=2 forward frame via wrapper");
        inject_frame_1w(1, 8'd9, 8'd2, 16'd3, 32'hAAAA_0003);
        wait_for_output_ports(3'b101, 3'b010, app_rx_count_seen);
        wait_outputs_quiet(20);
        $display("  PASS: valid_out on out0/out2, not out1, no app_rx leak");

        $display("CASE 4: in2 inject dst=2 forward frame via wrapper");
        inject_frame_1w(2, 8'd9, 8'd2, 16'd4, 32'hAAAA_0004);
        wait_for_output_ports(3'b011, 3'b100, app_rx_count_seen);
        $display("  PASS: valid_out on out0/out1, not out2, no app_rx leak");

        $display("PASS: tb_node_top_3port_functional completed");
        $finish;
    end
endmodule
