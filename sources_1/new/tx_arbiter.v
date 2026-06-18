`timescale 1ns / 1ps

//------------------------------------------------------------------------------
// tx_arbiter: arbitrates frame descriptors, then starts selected frame_tx blocks.
//------------------------------------------------------------------------------
module tx_arbiter #(
    parameter NUM_PORTS = 2,
    parameter PORT_W    = (NUM_PORTS <= 1) ? 1 : $clog2(NUM_PORTS),
    parameter FIFO_DEPTH = 8192,
    parameter FIFO_COUNT_W = (FIFO_DEPTH <= 1) ? 1 : $clog2(FIFO_DEPTH),
    parameter MAX_PAYLOAD = 256,
    parameter CLK_FREQ_HZ = 160_000_000,
    parameter CONGEST_TIMEOUT_SEC = 5
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
    input  wire [NUM_PORTS-1:0] tx_busy,
    input  wire [NUM_PORTS-1:0] tx_done,
    input  wire [NUM_PORTS-1:0] tx_full,
    input  wire [NUM_PORTS*FIFO_COUNT_W-1:0] tx_wr_data_count_flat,
    input  wire [NUM_PORTS-1:0]  payload_ready_flat,
    output wire [NUM_PORTS*16-1:0] payload_index_flat,
    output wire [NUM_PORTS-1:0]  payload_gate_flat,
    output reg  [NUM_PORTS-1:0] tx_start,
    output reg  [7:0]  tx_src_id,
    output reg  [7:0]  tx_dst_id,
    output reg  [15:0] tx_count,
    output reg  [15:0] tx_len16,
    output reg         tx_payload_is_forward,
    output reg  [PORT_W-1:0] tx_forward_payload_port,
    output wire [15:0] shared_payload_index,
    output wire        network_congested
);
    localparam [2:0] S_IDLE = 3'd0;
    localparam [2:0] S_BUSY = 3'd1;
    localparam [2:0] S_WAIT_FWD_ACK = 3'd2;
    localparam [2:0] S_WAIT_FWD_ROOM = 3'd3;
    localparam [2:0] S_WAIT_LOCAL_ROOM = 3'd4;
    localparam integer CONGEST_TIMEOUT_CYCLES = CLK_FREQ_HZ * CONGEST_TIMEOUT_SEC;
    localparam integer CONGEST_TIMER_W = (CONGEST_TIMEOUT_CYCLES <= 1) ? 1 : $clog2(CONGEST_TIMEOUT_CYCLES + 1);

    reg [2:0] st;
    reg [NUM_PORTS-1:0] active_mask;
    reg active_forward;
    reg active_local_is_app;
    reg [CONGEST_TIMER_W-1:0] congest_count;
    // Single master counter for payload read address, shared by every
    // simultaneously-started frame_tx so all instances stay aligned.
    reg [15:0] master_payload_index;
    integer i;

    reg forward_targets_idle;
    reg forward_targets_room;
    reg local_targets_idle;
    reg local_targets_room;
    reg all_ports_no_max_room;
    wire [15:0] forward_words = forward_len16 + 16'd4;
    wire [15:0] local_words = local_len16 + 16'd4;
    localparam [15:0] MAX_PAYLOAD_WORDS = MAX_PAYLOAD;
    wire [15:0] max_frame_words = MAX_PAYLOAD_WORDS + 16'd4;

    assign network_congested = all_ports_no_max_room ||
                               (st == S_WAIT_FWD_ROOM) ||
                               (st == S_WAIT_LOCAL_ROOM);

    function has_frame_room;
        input [FIFO_COUNT_W-1:0] used_words;
        input [15:0] needed_words;
        reg [31:0] used32;
        reg [31:0] needed32;
        begin
            used32 = used_words;
            needed32 = needed_words;
            // Strict "<" (not "<="): the FIFO IP's wr_data_count saturates at
            // DEPTH-1 when DEPTH is a power of two (13-bit can't represent 8192),
            // so reserving one extra word absorbs the off-by-one and prevents a
            // mid-frame TX FIFO full from desynchronising the payload stream.
            has_frame_room = (needed32 <= FIFO_DEPTH) && ((used32 + needed32) < FIFO_DEPTH);
        end
    endfunction

    // payload_advance: the master counter increments only when EVERY active
    // target port's frame_tx is ready to consume a payload word this cycle.
    // All instances therefore observe the same index and step together; none
    // can skip or duplicate a payload word even if one port's FIFO briefly
    // fills (the preflight check makes this rare, this is the backstop).
    reg payload_advance;
    integer ai;
    always @(*) begin
        payload_advance = 1'b1;
        for (ai = 0; ai < NUM_PORTS; ai = ai + 1) begin
            if (active_mask[ai] && !payload_ready_flat[ai])
                payload_advance = 1'b0;
        end
    end

    // Master counter value is broadcast to every frame_tx (payload_index) and
    // fed back to the source frame_rx (shared_payload_index). gate is asserted
    // to active ports only while we are actively streaming a frame (S_BUSY).
    assign shared_payload_index = master_payload_index;
    assign payload_gate_flat    = (st == S_BUSY) ? (active_mask & {NUM_PORTS{payload_advance}}) : {NUM_PORTS{1'b0}};
    genvar gi;
    generate
        for (gi = 0; gi < NUM_PORTS; gi = gi + 1) begin : g_idx
            assign payload_index_flat[gi*16 +: 16] = master_payload_index;
        end
    endgenerate

    always @(*) begin
        forward_targets_idle = 1'b1;
        forward_targets_room = 1'b1;
        local_targets_idle = 1'b1;
        local_targets_room = 1'b1;
        all_ports_no_max_room = 1'b1;

        for (i = 0; i < NUM_PORTS; i = i + 1) begin
            if (!tx_full[i] && has_frame_room(tx_wr_data_count_flat[i*FIFO_COUNT_W +: FIFO_COUNT_W], max_frame_words))
                all_ports_no_max_room = 1'b0;

            if (forward_port_mask[i]) begin
                if (tx_busy[i])
                    forward_targets_idle = 1'b0;
                if (tx_full[i] || !has_frame_room(tx_wr_data_count_flat[i*FIFO_COUNT_W +: FIFO_COUNT_W], forward_words))
                    forward_targets_room = 1'b0;
            end

            if (tx_busy[i])
                local_targets_idle = 1'b0;
            if (tx_full[i] || !has_frame_room(tx_wr_data_count_flat[i*FIFO_COUNT_W +: FIFO_COUNT_W], local_words))
                local_targets_room = 1'b0;
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            st <= S_IDLE;
            active_mask <= {NUM_PORTS{1'b0}};
            active_forward <= 1'b0;
            active_local_is_app <= 1'b0;
            congest_count <= {CONGEST_TIMER_W{1'b0}};
            tx_start <= {NUM_PORTS{1'b0}};
            tx_src_id <= 8'd0;
            tx_dst_id <= 8'd0;
            tx_count <= 16'd0;
            tx_len16 <= 16'd0;
            tx_payload_is_forward <= 1'b0;
            tx_forward_payload_port <= {PORT_W{1'b0}};
            master_payload_index <= 16'd0;
            local_accept <= 1'b0;
            local_app_done <= 1'b0;
            forward_accept <= 1'b0;
            forward_dropped <= 1'b0;
        end else begin
            tx_start <= {NUM_PORTS{1'b0}};
            local_accept <= 1'b0;
            local_app_done <= 1'b0;
            forward_accept <= 1'b0;
            forward_dropped <= 1'b0;

            case (st)
                S_IDLE: begin
                    congest_count <= {CONGEST_TIMER_W{1'b0}};
                    if (forward_req && forward_targets_idle) begin
                        active_mask <= forward_port_mask;
                        tx_src_id <= forward_src_id;
                        tx_dst_id <= forward_dst_id;
                        tx_count <= forward_count;
                        tx_len16 <= forward_len16;
                        tx_payload_is_forward <= 1'b1;
                        tx_forward_payload_port <= forward_payload_port;
                        active_forward <= 1'b1;
                        active_local_is_app <= 1'b0;
                        if (forward_port_mask == {NUM_PORTS{1'b0}}) begin
                            forward_accept <= 1'b1;
                            active_mask <= {NUM_PORTS{1'b0}};
                            st <= S_WAIT_FWD_ACK;
                        end else if (forward_targets_room) begin
                            tx_start <= forward_port_mask;
                            master_payload_index <= 16'd0;
                            st <= S_BUSY;
                        end else begin
                            congest_count <= {CONGEST_TIMER_W{1'b0}};
                            st <= S_WAIT_FWD_ROOM;
                        end
                    end else if (local_req && local_targets_idle) begin
                        active_mask <= {NUM_PORTS{1'b1}};
                        tx_src_id <= my_id;
                        tx_dst_id <= local_dst_id;
                        tx_count <= local_count;
                        tx_len16 <= local_len16;
                        tx_payload_is_forward <= 1'b0;
                        tx_forward_payload_port <= {PORT_W{1'b0}};
                        active_forward <= 1'b0;
                        active_local_is_app <= local_is_app;
                        if (!local_targets_room) begin
                            congest_count <= {CONGEST_TIMER_W{1'b0}};
                            st <= S_WAIT_LOCAL_ROOM;
                        end else begin
                            local_accept <= 1'b1;
                            tx_start <= {NUM_PORTS{1'b1}};
                            master_payload_index <= 16'd0;
                            st <= S_BUSY;
                        end
                    end
                end

                S_BUSY: begin
                    // Advance the shared payload counter only when every active
                    // frame_tx is consuming a word this cycle (payload_advance).
                    if (payload_advance)
                        master_payload_index <= master_payload_index + 16'd1;
                    if ((tx_done & active_mask) == active_mask) begin
                        active_mask <= {NUM_PORTS{1'b0}};
                        master_payload_index <= 16'd0;
                        if (active_forward) begin
                            forward_accept <= 1'b1;
                            st <= S_WAIT_FWD_ACK;
                        end else begin
                            if (active_local_is_app)
                                local_app_done <= 1'b1;
                            active_local_is_app <= 1'b0;
                            st <= S_IDLE;
                        end
                    end
                end

                S_WAIT_FWD_ACK: begin
                    forward_accept <= 1'b1;
                    if (!forward_req) begin
                        forward_accept <= 1'b0;
                        active_forward <= 1'b0;
                        congest_count <= {CONGEST_TIMER_W{1'b0}};
                        st <= S_IDLE;
                    end
                end

                S_WAIT_FWD_ROOM: begin
                    if (!forward_req) begin
                        active_mask <= {NUM_PORTS{1'b0}};
                        active_forward <= 1'b0;
                        congest_count <= {CONGEST_TIMER_W{1'b0}};
                        st <= S_IDLE;
                    end else if (forward_targets_idle && forward_targets_room) begin
                        tx_start <= active_mask;
                        master_payload_index <= 16'd0;
                        congest_count <= {CONGEST_TIMER_W{1'b0}};
                        st <= S_BUSY;
                    end else if (congest_count >= CONGEST_TIMEOUT_CYCLES - 1) begin
                        forward_accept <= 1'b1;
                        forward_dropped <= 1'b1;
                        active_mask <= {NUM_PORTS{1'b0}};
                        congest_count <= {CONGEST_TIMER_W{1'b0}};
                        st <= S_WAIT_FWD_ACK;
                    end else begin
                        congest_count <= congest_count + 1'b1;
                    end
                end

                S_WAIT_LOCAL_ROOM: begin
                    if (!local_req) begin
                        active_mask <= {NUM_PORTS{1'b0}};
                        congest_count <= {CONGEST_TIMER_W{1'b0}};
                        st <= S_IDLE;
                    end else if (local_targets_idle && local_targets_room) begin
                        local_accept <= 1'b1;
                        tx_start <= active_mask;
                        master_payload_index <= 16'd0;
                        congest_count <= {CONGEST_TIMER_W{1'b0}};
                        st <= S_BUSY;
                    end else begin
                        congest_count <= {CONGEST_TIMER_W{1'b0}};
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
