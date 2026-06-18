`timescale 1ns / 1ps

//------------------------------------------------------------------------------
// tx_enqueue_engine: builds complete protocol frames into per-port frame queues.
//------------------------------------------------------------------------------
module tx_enqueue_engine #(
    parameter SYNC_WORD = 32'hA31E57BD,
    parameter NUM_PORTS = 2,
    parameter PORT_W    = (NUM_PORTS <= 1) ? 1 : $clog2(NUM_PORTS),
    parameter MAX_PAYLOAD = 256,
    parameter QUEUE_DEPTH = 8192,
    parameter QUEUE_COUNT_W = $clog2(QUEUE_DEPTH + 1),
    parameter TIME_W = 32
) (
    input  wire clk,
    input  wire rst,
    input  wire [7:0] my_id,

    input  wire       local_req,
    output reg        local_accept,
    input  wire       local_is_app,
    output reg        local_app_done,
    input  wire [7:0] local_dst_id,
    input  wire [15:0] local_count,
    input  wire [15:0] local_len16,

    input  wire       forward_req,
    output reg        forward_accept,
    output reg        forward_dropped,
    input  wire [NUM_PORTS-1:0] forward_port_mask,
    input  wire [7:0]  forward_src_id,
    input  wire [7:0]  forward_dst_id,
    input  wire [15:0] forward_count,
    input  wire [15:0] forward_len16,
    input  wire [PORT_W-1:0] forward_payload_port,

    input  wire [NUM_PORTS-1:0] queue_full,
    input  wire [NUM_PORTS*QUEUE_COUNT_W-1:0] queue_data_count_flat,
    output reg  [NUM_PORTS-1:0] queue_wr_en,
    output reg  [NUM_PORTS*34-1:0] queue_din_flat,
    input  wire [NUM_PORTS-1:0] meta_full,
    output reg  [NUM_PORTS-1:0] meta_wr_en,
    output reg  [NUM_PORTS*(TIME_W+16)-1:0] meta_din_flat,
    input  wire [TIME_W-1:0] current_time,

    output wire [15:0] payload_index,
    output wire        payload_is_forward,
    output wire [PORT_W-1:0] payload_forward_port,
    input  wire [31:0] payload_data,

    output wire network_congested
);
    localparam [2:0] S_IDLE     = 3'd0;
    localparam [2:0] S_SYNC     = 3'd1;
    localparam [2:0] S_HEADER1  = 3'd2;
    localparam [2:0] S_HEADER2  = 3'd3;
    localparam [2:0] S_PAYLOAD  = 3'd4;
    localparam [2:0] S_CRC      = 3'd5;
    localparam [2:0] S_CRC_WAIT = 3'd6;
    localparam [2:0] S_CRC_WORD = 3'd7;
    localparam [15:0] MAX_PAYLOAD_WORDS = MAX_PAYLOAD;

    reg [2:0] st;
    reg [NUM_PORTS-1:0] active_mask;
    reg active_forward;
    reg active_local_is_app;
    reg [7:0]  active_src;
    reg [7:0]  active_dst;
    reg [15:0] active_count;
    reg [15:0] active_len;
    reg [15:0] payload_idx;
    reg [PORT_W-1:0] payload_port_r;

    reg crc_init;
    reg crc_en;
    reg crc_finalize;
    reg [31:0] crc_data;
    wire [31:0] crc_out;

    integer i;
    integer j;
    integer k;
    reg [NUM_PORTS-1:0] local_room_mask;
    reg [NUM_PORTS-1:0] forward_room_mask;
    reg [NUM_PORTS-1:0] max_room_mask;
    wire [15:0] local_words = local_len16 + 16'd4;
    wire [15:0] forward_words = forward_len16 + 16'd4;
    wire [15:0] max_frame_words = MAX_PAYLOAD_WORDS + 16'd4;
    wire [15:0] active_words = active_len + 16'd4;

    assign payload_index = payload_idx;
    assign payload_is_forward = active_forward;
    assign payload_forward_port = payload_port_r;
    assign network_congested = (st == S_IDLE) &&
                               ((local_req && !(|local_room_mask)) || !(|max_room_mask));

    crc32_calc u_crc (
        .clk(clk),
        .rst(rst),
        .init(crc_init),
        .en(crc_en),
        .data(crc_data),
        .finalize(crc_finalize),
        .crc_out(crc_out)
    );

    function has_frame_room;
        input [QUEUE_COUNT_W-1:0] used_words;
        input [15:0] needed_words;
        reg [31:0] used32;
        reg [31:0] needed32;
        begin
            used32 = used_words;
            needed32 = needed_words;
            has_frame_room = (needed32 <= QUEUE_DEPTH) &&
                             ((QUEUE_DEPTH - used32) >= needed32);
        end
    endfunction

    task set_all_queue_words;
        input        sof;
        input        eof;
        input [31:0] data_word;
        begin
            for (j = 0; j < NUM_PORTS; j = j + 1)
                queue_din_flat[j*34 +: 34] = {sof, eof, data_word};
        end
    endtask

    task set_all_meta_words;
        input [15:0] frame_words;
        input [TIME_W-1:0] enqueue_time;
        begin
            for (k = 0; k < NUM_PORTS; k = k + 1)
                meta_din_flat[k*(TIME_W+16) +: (TIME_W+16)] = {enqueue_time, frame_words};
        end
    endtask

    always @(*) begin
        local_room_mask = {NUM_PORTS{1'b0}};
        forward_room_mask = {NUM_PORTS{1'b0}};
        max_room_mask = {NUM_PORTS{1'b0}};

        for (i = 0; i < NUM_PORTS; i = i + 1) begin
            if (!queue_full[i] && !meta_full[i] &&
                has_frame_room(queue_data_count_flat[i*QUEUE_COUNT_W +: QUEUE_COUNT_W], max_frame_words))
                max_room_mask[i] = 1'b1;

            if (!queue_full[i] && !meta_full[i] &&
                has_frame_room(queue_data_count_flat[i*QUEUE_COUNT_W +: QUEUE_COUNT_W], local_words))
                local_room_mask[i] = 1'b1;

            if (forward_port_mask[i] && !queue_full[i] && !meta_full[i] &&
                has_frame_room(queue_data_count_flat[i*QUEUE_COUNT_W +: QUEUE_COUNT_W], forward_words))
                forward_room_mask[i] = 1'b1;
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            st <= S_IDLE;
            active_mask <= {NUM_PORTS{1'b0}};
            active_forward <= 1'b0;
            active_local_is_app <= 1'b0;
            active_src <= 8'd0;
            active_dst <= 8'd0;
            active_count <= 16'd0;
            active_len <= 16'd0;
            payload_idx <= 16'd0;
            payload_port_r <= {PORT_W{1'b0}};
            local_accept <= 1'b0;
            local_app_done <= 1'b0;
            forward_accept <= 1'b0;
            forward_dropped <= 1'b0;
            queue_wr_en <= {NUM_PORTS{1'b0}};
            queue_din_flat <= {(NUM_PORTS*34){1'b0}};
            meta_wr_en <= {NUM_PORTS{1'b0}};
            meta_din_flat <= {(NUM_PORTS*(TIME_W+16)){1'b0}};
            crc_init <= 1'b0;
            crc_en <= 1'b0;
            crc_finalize <= 1'b0;
            crc_data <= 32'd0;
        end else begin
            local_accept <= 1'b0;
            local_app_done <= 1'b0;
            forward_accept <= 1'b0;
            forward_dropped <= 1'b0;
            queue_wr_en <= {NUM_PORTS{1'b0}};
            meta_wr_en <= {NUM_PORTS{1'b0}};
            crc_init <= 1'b0;
            crc_en <= 1'b0;
            crc_finalize <= 1'b0;

            case (st)
                S_IDLE: begin
                    active_mask <= {NUM_PORTS{1'b0}};
                    payload_idx <= 16'd0;
                    if (forward_req) begin
                        if (|forward_room_mask) begin
                            active_mask <= forward_room_mask;
                            active_forward <= 1'b1;
                            active_local_is_app <= 1'b0;
                            active_src <= forward_src_id;
                            active_dst <= forward_dst_id;
                            active_count <= forward_count;
                            active_len <= forward_len16;
                            payload_port_r <= forward_payload_port;
                            st <= S_SYNC;
                        end else begin
                            forward_accept <= 1'b1;
                            forward_dropped <= 1'b1;
                        end
                    end else if (local_req && (|local_room_mask)) begin
                        active_mask <= local_room_mask;
                        active_forward <= 1'b0;
                        active_local_is_app <= local_is_app;
                        active_src <= my_id;
                        active_dst <= local_dst_id;
                        active_count <= local_count;
                        active_len <= local_len16;
                        payload_port_r <= {PORT_W{1'b0}};
                        local_accept <= 1'b1;
                        st <= S_SYNC;
                    end
                end

                S_SYNC: begin
                    set_all_queue_words(1'b1, 1'b0, SYNC_WORD);
                    queue_wr_en <= active_mask;
                    crc_init <= 1'b1;
                    st <= S_HEADER1;
                end

                S_HEADER1: begin
                    set_all_queue_words(1'b0, 1'b0, {active_src, active_dst, active_count});
                    queue_wr_en <= active_mask;
                    crc_en <= 1'b1;
                    crc_data <= {active_src, active_dst, active_count};
                    st <= S_HEADER2;
                end

                S_HEADER2: begin
                    set_all_queue_words(1'b0, 1'b0, {active_len, 16'd0});
                    queue_wr_en <= active_mask;
                    crc_en <= 1'b1;
                    crc_data <= {active_len, 16'd0};
                    payload_idx <= 16'd0;
                    if (active_len == 16'd0)
                        st <= S_CRC;
                    else
                        st <= S_PAYLOAD;
                end

                S_PAYLOAD: begin
                    set_all_queue_words(1'b0, 1'b0, payload_data);
                    queue_wr_en <= active_mask;
                    crc_en <= 1'b1;
                    crc_data <= payload_data;
                    if (payload_idx == active_len - 1'b1)
                        st <= S_CRC;
                    else
                        payload_idx <= payload_idx + 1'b1;
                end

                S_CRC: begin
                    crc_finalize <= 1'b1;
                    st <= S_CRC_WAIT;
                end

                S_CRC_WAIT: begin
                    st <= S_CRC_WORD;
                end

                S_CRC_WORD: begin
                    set_all_queue_words(1'b0, 1'b1, crc_out);
                    set_all_meta_words(active_words, current_time);
                    queue_wr_en <= active_mask;
                    meta_wr_en <= active_mask;
                    if (active_forward) begin
                        forward_accept <= 1'b1;
                    end else if (active_local_is_app) begin
                        local_app_done <= 1'b1;
                    end
                    st <= S_IDLE;
                end

                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
