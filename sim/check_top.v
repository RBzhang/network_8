`timescale 1ns / 1ps

module check_top;

    reg clk, rst;
    reg node_id_valid;
    reg [7:0] node_id;
    reg rx_clk0, rx_clk1, tx_clk0, tx_clk1;
    reg [31:0] in0, in1;
    reg valid_in0, valid_in1;
    reg app_frame_valid;
    wire app_frame_ready;
    wire app_frame_accepted;
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
    wire [31:0] out0, out1;
    wire valid_out0, valid_out1;
    wire network_congested;

    node #(
        .FIFO_DEPTH(8192)
    ) u_node (
        .clk(clk), .rst(rst),
        .node_id_valid(node_id_valid), .node_id(node_id),
        .rx_clk0(rx_clk0), .rx_clk1(rx_clk1),
        .tx_clk0(tx_clk0), .tx_clk1(tx_clk1),
        .in0(in0), .in1(in1),
        .valid_in0(valid_in0), .valid_in1(valid_in1),
        .app_frame_valid(app_frame_valid),
        .app_frame_ready(app_frame_ready),
        .app_frame_accepted(app_frame_accepted),
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
        .out0(out0), .out1(out1),
        .valid_out0(valid_out0), .valid_out1(valid_out1),
        .network_congested(network_congested)
    );

    initial begin
        clk = 0;
        forever #3.125 clk = ~clk;
    end

    initial begin
        rst = 1;
        #20 rst = 0;
    end

endmodule
