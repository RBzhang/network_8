`timescale 1ns / 1ps

//------------------------------------------------------------------------------
// node_top_4port: 4-port board-level compatibility wrapper around node_core.
//------------------------------------------------------------------------------
module node_top_4port #(
    parameter SYNC_WORD    = 32'hA31E57BD,
    parameter BROADCAST    = 8'hFF,
    parameter MAX_PAYLOAD  = 256,
    parameter LIVENESS_WIN = 5,
    parameter NODE_COUNT   = 255,
    parameter DEDUP_DEPTH  = 64,
    parameter FIFO_DEPTH   = 8192,
    parameter RX_REPORT_FIFO_DEPTH = 2048,
    parameter CLK_FREQ_HZ  = 160_000_000,
    parameter CONGEST_TIMEOUT_SEC = 5,
    parameter TX_QUEUE_TIMEOUT_SEC = CONGEST_TIMEOUT_SEC,
    parameter TX_QUEUE_TIMEOUT_CYCLES = CLK_FREQ_HZ * TX_QUEUE_TIMEOUT_SEC
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        node_id_valid,
    input  wire [7:0]  node_id,
    input  wire        rx_clk0,
    input  wire        rx_clk1,
    input  wire        rx_clk2,
    input  wire        rx_clk3,
    input  wire        tx_clk0,
    input  wire        tx_clk1,
    input  wire        tx_clk2,
    input  wire        tx_clk3,
    input  wire [31:0] in0,
    input  wire [31:0] in1,
    input  wire [31:0] in2,
    input  wire [31:0] in3,
    input  wire        valid_in0,
    input  wire        valid_in1,
    input  wire        valid_in2,
    input  wire        valid_in3,
    input  wire        app_frame_valid,
    output wire        app_frame_ready,
    output wire        app_frame_accepted,
    output wire        app_frame_done,
    input  wire [7:0]  app_dst_id,
    input  wire [15:0] app_len16,
    output wire [15:0] app_payload_addr,
    input  wire [31:0] app_payload_data,
    output wire        app_rx_frame_valid,
    input  wire        app_rx_frame_ready,
    output wire [7:0]  app_rx_src_id,
    output wire [7:0]  app_rx_dst_id,
    output wire [15:0] app_rx_count,
    output wire [15:0] app_rx_len16,
    output wire        app_rx_payload_valid,
    input  wire        app_rx_payload_ready,
    output wire [15:0] app_rx_payload_addr,
    output wire [31:0] app_rx_payload_data,
    output wire [31:0] out0,
    output wire [31:0] out1,
    output wire [31:0] out2,
    output wire [31:0] out3,
    output wire        valid_out0,
    output wire        valid_out1,
    output wire        valid_out2,
    output wire        valid_out3,
    output wire        liveness_valid,
    output wire [7:0]  liveness_node,
    output wire        liveness_alive,
    output wire        network_congested,
    output wire        app_len_error,
    output wire        rx_overflow
);
    localparam CORE_PORTS = 4;

    wire [CORE_PORTS-1:0] rx_clk_bus;
    wire [CORE_PORTS-1:0] tx_clk_bus;
    wire [CORE_PORTS*32-1:0] in_bus;
    wire [CORE_PORTS-1:0] valid_in_bus;
    wire [CORE_PORTS*32-1:0] out_bus;
    wire [CORE_PORTS-1:0] valid_out_bus;

    assign rx_clk_bus = {rx_clk3, rx_clk2, rx_clk1, rx_clk0};
    assign tx_clk_bus = {tx_clk3, tx_clk2, tx_clk1, tx_clk0};
    assign in_bus = {in3, in2, in1, in0};
    assign valid_in_bus = {valid_in3, valid_in2, valid_in1, valid_in0};

    assign out0 = out_bus[0*32 +: 32];
    assign out1 = out_bus[1*32 +: 32];
    assign out2 = out_bus[2*32 +: 32];
    assign out3 = out_bus[3*32 +: 32];
    assign valid_out0 = valid_out_bus[0];
    assign valid_out1 = valid_out_bus[1];
    assign valid_out2 = valid_out_bus[2];
    assign valid_out3 = valid_out_bus[3];

    node_core #(
        .SYNC_WORD(SYNC_WORD),
        .BROADCAST(BROADCAST),
        .MAX_PAYLOAD(MAX_PAYLOAD),
        .LIVENESS_WIN(LIVENESS_WIN),
        .NODE_COUNT(NODE_COUNT),
        .DEDUP_DEPTH(DEDUP_DEPTH),
        .FIFO_DEPTH(FIFO_DEPTH),
        .RX_REPORT_FIFO_DEPTH(RX_REPORT_FIFO_DEPTH),
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .CONGEST_TIMEOUT_SEC(CONGEST_TIMEOUT_SEC),
        .TX_QUEUE_TIMEOUT_SEC(TX_QUEUE_TIMEOUT_SEC),
        .TX_QUEUE_TIMEOUT_CYCLES(TX_QUEUE_TIMEOUT_CYCLES),
        .NUM_PORTS(CORE_PORTS)
    ) u_node_core (
        .clk(clk),
        .rst(rst),
        .node_id_valid(node_id_valid),
        .node_id(node_id),
        .rx_clk(rx_clk_bus),
        .tx_clk(tx_clk_bus),
        .in_flat(in_bus),
        .valid_in(valid_in_bus),
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
        .out_flat(out_bus),
        .valid_out(valid_out_bus),
        .liveness_valid(liveness_valid),
        .liveness_node(liveness_node),
        .liveness_alive(liveness_alive),
        .network_congested(network_congested),
        .app_len_error(app_len_error),
        .rx_overflow(rx_overflow)
    );
endmodule
