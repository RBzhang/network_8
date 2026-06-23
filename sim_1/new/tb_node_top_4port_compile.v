`timescale 1ns/1ps

module tb_node_top_4port_compile;
    reg clk;
    reg rst;
    reg node_id_valid;
    reg [7:0] node_id;
    wire app_frame_ready;
    wire app_frame_accepted;
    wire app_frame_done;
    wire [15:0] app_payload_addr;
    wire app_rx_frame_valid;
    wire [7:0] app_rx_src_id;
    wire [7:0] app_rx_dst_id;
    wire [15:0] app_rx_count;
    wire [15:0] app_rx_len16;
    wire app_rx_payload_valid;
    wire [15:0] app_rx_payload_addr;
    wire [31:0] app_rx_payload_data;
    wire [31:0] out0, out1, out2, out3;
    wire valid_out0, valid_out1, valid_out2, valid_out3;
    wire liveness_valid;
    wire [7:0] liveness_node;
    wire liveness_alive;
    wire network_congested;
    wire app_len_error;
    wire rx_overflow;

    always #5 clk = ~clk;

    node_top_4port #(
        .FIFO_DEPTH(128),
        .RX_REPORT_FIFO_DEPTH(64),
        .CLK_FREQ_HZ(100_000_000),
        .CONGEST_TIMEOUT_SEC(5)
    ) dut (
        .clk(clk), .rst(rst), .node_id_valid(node_id_valid), .node_id(node_id),
        .rx_clk0(clk), .rx_clk1(clk), .rx_clk2(clk), .rx_clk3(clk),
        .tx_clk0(clk), .tx_clk1(clk), .tx_clk2(clk), .tx_clk3(clk),
        .in0(32'd0), .in1(32'd0), .in2(32'd0), .in3(32'd0),
        .valid_in0(1'b0), .valid_in1(1'b0), .valid_in2(1'b0), .valid_in3(1'b0),
        .app_frame_valid(1'b0), .app_frame_ready(app_frame_ready),
        .app_frame_accepted(app_frame_accepted), .app_frame_done(app_frame_done),
        .app_dst_id(8'd0), .app_len16(16'd0),
        .app_payload_addr(app_payload_addr), .app_payload_data(32'd0),
        .app_rx_frame_valid(app_rx_frame_valid), .app_rx_frame_ready(1'b1),
        .app_rx_src_id(app_rx_src_id), .app_rx_dst_id(app_rx_dst_id),
        .app_rx_count(app_rx_count), .app_rx_len16(app_rx_len16),
        .app_rx_payload_valid(app_rx_payload_valid), .app_rx_payload_ready(1'b1),
        .app_rx_payload_addr(app_rx_payload_addr), .app_rx_payload_data(app_rx_payload_data),
        .out0(out0), .out1(out1), .out2(out2), .out3(out3),
        .valid_out0(valid_out0), .valid_out1(valid_out1), .valid_out2(valid_out2), .valid_out3(valid_out3),
        .liveness_valid(liveness_valid), .liveness_node(liveness_node),
        .liveness_alive(liveness_alive), .network_congested(network_congested),
        .app_len_error(app_len_error), .rx_overflow(rx_overflow)
    );

    initial begin
        clk = 1'b0;
        rst = 1'b1;
        node_id_valid = 1'b0;
        node_id = 8'd0;
        repeat (10) @(posedge clk);
        rst = 1'b0;
        repeat (3) @(posedge clk);
        node_id = 8'd1;
        node_id_valid = 1'b1;
        @(posedge clk);
        node_id_valid = 1'b0;
        repeat (50) @(posedge clk);
        $display("PASS: tb_node_top_4port_compile completed");
        $finish;
    end
endmodule
