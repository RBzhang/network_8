`timescale 1ns / 1ps
//------------------------------------------------------------------------------
// NODE: Top-level network node module
//   Instantiates: async_fifo, frame_rx, dedup_table, liveness_table, crc32_calc
//------------------------------------------------------------------------------
module node #(
    parameter SYNC_WORD    = 32'hA31E57BD,
    parameter BROADCAST    = 8'hFF,
    parameter MAX_PAYLOAD  = 256,
    parameter LIVENESS_WIN = 5,
    parameter NODE_COUNT   = 255,
    parameter DEDUP_DEPTH  = 64,
    parameter FIFO_DEPTH   = 512,
    parameter CLK_FREQ_HZ  = 160_000_000,
    parameter NUM_PORTS    = 2
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [7:0]  node_id,
    input  wire        rx_clk0,
    input  wire        rx_clk1,
    input  wire        tx_clk0,
    input  wire        tx_clk1,
    input  wire [31:0] in0,
    input  wire [31:0] in1,
    input  wire        valid_in0,
    input  wire        valid_in1,
    output wire [31:0] out0,
    output wire [31:0] out1,
    output wire        valid_out0,
    output wire        valid_out1,
    output wire        liveness_valid,
    output wire [7:0]  liveness_node,
    output wire        liveness_alive
);
    localparam PORT_W = (NUM_PORTS <= 1) ? 1 : $clog2(NUM_PORTS);
    localparam SCAN_W = $clog2(NUM_PORTS + 1);
    localparam [NUM_PORTS-1:0] PORT_MASK = {NUM_PORTS{1'b1}};

    reg [7:0] my_id;
    always @(posedge clk) begin
        if (rst) my_id <= node_id;
        else     my_id <= my_id;
    end

    //----------------------------------------------------------------------
    // Async RX/TX FIFOs bridge per-port clocks to the internal clk domain.
    //----------------------------------------------------------------------
    wire [NUM_PORTS-1:0] rx_e, rx_f, tx_e, tx_f;
    wire [31:0] rx_d [0:NUM_PORTS-1], tx_d [0:NUM_PORTS-1];
    reg  [31:0] tx_din [0:NUM_PORTS-1];
    wire [NUM_PORTS-1:0] rx_rd;
    reg  [NUM_PORTS-1:0] tx_wr;

    genvar g;
    generate
        for (g = 0; g < NUM_PORTS; g = g + 1) begin : g_fifo
            if (g == 0) begin : g_port0
                async_fifo #(.DEPTH(FIFO_DEPTH)) u_rx (
                    .wr_clk(rx_clk0), .rst(rst),
                    .wr_en(valid_in0), .din(in0),
                    .full(rx_f[g]),
                    .rd_clk(clk), .rd_en(rx_rd[g]), .dout(rx_d[g]),
                    .empty(rx_e[g])
                );
                async_fifo #(.DEPTH(FIFO_DEPTH)) u_tx (
                    .wr_clk(clk), .rst(rst),
                    .wr_en(tx_wr[g]), .din(tx_din[g]),
                    .full(tx_f[g]),
                    .rd_clk(tx_clk0), .rd_en(!tx_e[g]), .dout(tx_d[g]),
                    .empty(tx_e[g])
                );
            end else begin : g_port1
                async_fifo #(.DEPTH(FIFO_DEPTH)) u_rx (
                    .wr_clk(rx_clk1), .rst(rst),
                    .wr_en(valid_in1), .din(in1),
                    .full(rx_f[g]),
                    .rd_clk(clk), .rd_en(rx_rd[g]), .dout(rx_d[g]),
                    .empty(rx_e[g])
                );
                async_fifo #(.DEPTH(FIFO_DEPTH)) u_tx (
                    .wr_clk(clk), .rst(rst),
                    .wr_en(tx_wr[g]), .din(tx_din[g]),
                    .full(tx_f[g]),
                    .rd_clk(tx_clk1), .rd_en(!tx_e[g]), .dout(tx_d[g]),
                    .empty(tx_e[g])
                );
            end
        end
    endgenerate

    // TX output: continuous read from TX FIFO when not empty
    reg [31:0] o0, o1;
    reg        v0, v1;
    always @(posedge tx_clk0) begin
        if (rst) begin o0 <= 0; v0 <= 0; end
        else begin v0 <= !tx_e[0]; if (!tx_e[0]) o0 <= tx_d[0]; end
    end
    always @(posedge tx_clk1) begin
        if (rst) begin o1 <= 0; v1 <= 0; end
        else begin v1 <= !tx_e[1]; if (!tx_e[1]) o1 <= tx_d[1]; end
    end
    assign out0 = o0;   assign out1 = o1;
    assign valid_out0 = v0;   assign valid_out1 = v1;

    //----------------------------------------------------------------------
    // Frame Receivers × 2
    //----------------------------------------------------------------------
    wire [NUM_PORTS-1:0] fr_rdy;
    wire [7:0]  fr_src [0:NUM_PORTS-1], fr_dst [0:NUM_PORTS-1];
    wire [15:0] fr_cnt [0:NUM_PORTS-1], fr_len [0:NUM_PORTS-1];
    wire [31:0] fr_pld [0:NUM_PORTS-1];
    wire [NUM_PORTS-1:0] fr_bc;
    reg  [NUM_PORTS-1:0] fr_done;
    reg  [15:0] fr_paddr [0:NUM_PORTS-1];

    generate
        for (g = 0; g < NUM_PORTS; g = g + 1) begin : g_fr
            frame_rx #(
                .SYNC_WORD(SYNC_WORD),
                .MAX_PAYLOAD(MAX_PAYLOAD)
            ) u_fr (
                .clk(clk), .rst(rst),
                .fifo_dout(rx_d[g]), .fifo_empty(rx_e[g]),
                .fifo_rd_en(rx_rd[g]),
                .frame_ready(fr_rdy[g]),
                .rx_src_id(fr_src[g]), .rx_dst_id(fr_dst[g]),
                .rx_count(fr_cnt[g]), .rx_len16(fr_len[g]),
                .payload_addr(fr_paddr[g]),
                .rx_payload(fr_pld[g]),
                .rx_is_broadcast(fr_bc[g]),
                .frame_consumed(fr_done[g])
            );
        end
    endgenerate

    //----------------------------------------------------------------------
    // Deduplication Table
    //----------------------------------------------------------------------
    reg         d_lkup, d_ins;
    reg  [7:0]  d_src;
    reg  [15:0] d_cnt;
    wire        d_found;

    dedup_table #(.DEPTH(DEDUP_DEPTH)) u_dedup (
        .clk(clk), .rst(rst),
        .lookup(d_lkup), .insert(d_ins),
        .lkup_src(d_src), .lkup_cnt(d_cnt),
        .ins_src(d_src), .ins_cnt(d_cnt),
        .found(d_found)
    );

    //----------------------------------------------------------------------
    // Liveness Table
    //----------------------------------------------------------------------
    wire       t1s;
    reg        lv_upd;
    reg [7:0]  lv_s;

    liveness_table #(.MAX_NODES(NODE_COUNT), .WINDOW(LIVENESS_WIN)) u_lv (
        .clk(clk), .rst(rst),
        .tick_1s(t1s), .update(lv_upd), .update_src(lv_s),
        .upload_valid(liveness_valid), .upload_node(liveness_node),
        .upload_alive(liveness_alive)
    );

    // 1-second timer (counter from 0 to CLK_FREQ_HZ-1)
    reg [31:0] tmr;
    always @(posedge clk) begin
        if (rst) tmr <= 0;
        else     tmr <= (tmr == CLK_FREQ_HZ - 1) ? 0 : tmr + 1;
    end
    assign t1s = (tmr == CLK_FREQ_HZ - 1);

    // Self-packet trigger: fires every 1 second
    reg [15:0] self_c;
    reg        self_tr;
    always @(posedge clk) begin
        if (rst) begin self_c <= 0; self_tr <= 0; end
        else begin
            self_tr <= 0;
            if (t1s) begin self_c <= self_c + 1; self_tr <= 1; end
        end
    end

    //----------------------------------------------------------------------
    // Scheduler: unified frame processor
    //----------------------------------------------------------------------
    localparam [4:0] IDLE         = 5'd0;
    localparam [4:0] POLL         = 5'd1;
    localparam [4:0] HDR          = 5'd2;
    localparam [4:0] SELFCHK      = 5'd3;
    localparam [4:0] DSTCHK       = 5'd4;
    localparam [4:0] DEDUP        = 5'd5;
    localparam [4:0] LOCAL        = 5'd6;
    localparam [4:0] FWDSET       = 5'd7;
    localparam [4:0] FWDSYNC      = 5'd8;
    localparam [4:0] FWDDATA      = 5'd9;
    localparam [4:0] FWDCRC       = 5'd10;
    localparam [4:0] DISCARD      = 5'd11;
    localparam [4:0] SELFSET      = 5'd12;
    localparam [4:0] SELFDATA     = 5'd13;
    localparam [4:0] SELFCRC      = 5'd14;
    localparam [4:0] SELFDONE     = 5'd15;
    localparam [4:0] DEDUP_WAIT   = 5'd16;
    localparam [4:0] FWDCRC_WAIT  = 5'd17;
    localparam [4:0] SELFCRC_WAIT = 5'd18;

    reg [4:0]  s;           // current state
    reg [PORT_W-1:0] sp;    // round-robin poll index
    reg [PORT_W-1:0] rp;    // active RX port
    reg [PORT_W-1:0] poll_idx;
    reg [SCAN_W-1:0] poll_scan;
    reg [15:0] si;          // word index within frame
    reg [15:0] sl;          // len16 of current frame
    reg [NUM_PORTS-1:0] fm; // forward port bitmask
    reg        selfp;       // 1 = self-packet (suppress fr_done in DISCARD)
    integer    p;

    function [PORT_W-1:0] next_port;
        input [PORT_W-1:0] port;
        begin
            next_port = (port == NUM_PORTS - 1) ? {PORT_W{1'b0}} : port + 1'b1;
        end
    endfunction

    function [NUM_PORTS-1:0] ports_except;
        input [PORT_W-1:0] port;
        begin
            ports_except = PORT_MASK;
            ports_except[port] = 1'b0;
        end
    endfunction

    // Scheduler CRC engine (for TX CRC calculation)
    reg        crc_i, crc_e, crc_f;
    reg [31:0] crc_d;
    wire [31:0] crc_r;
    crc32_calc u_sc (
        .clk(clk), .rst(rst),
        .init(crc_i), .en(crc_e), .data(crc_d),
        .finalize(crc_f), .crc_out(crc_r)
    );

    always @(posedge clk) begin
        if (rst) begin
            s <= IDLE; sp <= 0; rp <= 0; poll_idx <= 0; poll_scan <= 0; si <= 0; sl <= 0; fm <= 0;
            selfp <= 0;
            fr_done <= {NUM_PORTS{1'b0}}; tx_wr <= {NUM_PORTS{1'b0}};
            for (p = 0; p < NUM_PORTS; p = p + 1)
                tx_din[p] <= 32'd0;
            d_lkup <= 0; d_ins <= 0; d_src <= 0; d_cnt <= 0;
            lv_upd <= 0; lv_s <= 0;
            crc_i <= 0; crc_e <= 0; crc_f <= 0; crc_d <= 0;
        end else begin
            fr_done <= {NUM_PORTS{1'b0}}; tx_wr <= {NUM_PORTS{1'b0}};
            d_lkup <= 0; d_ins <= 0; lv_upd <= 0;
            crc_i <= 0; crc_e <= 0; crc_f <= 0;

            case (s)

                IDLE: begin s <= POLL; end

                POLL: begin
                    if (self_tr) begin
                        s <= SELFSET;
                    end else if (poll_scan == 0) begin
                        poll_idx <= sp;
                        poll_scan <= 1;
                    end else if (fr_rdy[poll_idx]) begin
                        rp <= poll_idx;
                        sp <= next_port(poll_idx);
                        poll_scan <= 0;
                        s <= HDR;
                    end else if (poll_scan == NUM_PORTS) begin
                        sp <= next_port(sp);
                        poll_scan <= 0;
                    end else begin
                        poll_idx <= next_port(poll_idx);
                        poll_scan <= poll_scan + 1'b1;
                    end
                end

                HDR: begin sl <= fr_len[rp]; si <= 0; s <= SELFCHK; end

                SELFCHK: begin
                    if (fr_src[rp] == my_id) begin
                        fr_done[rp] <= 1; s <= IDLE;
                    end else begin
                        lv_upd <= 1; lv_s <= fr_src[rp];
                        s <= DSTCHK;
                    end
                end

                DSTCHK: begin
                    fm <= 0;
                    if (fr_dst[rp] == my_id) begin
                        s <= LOCAL;
                    end else if (fr_bc[rp]) begin
                        fm <= ports_except(rp);
                        s <= LOCAL;
                    end else begin
                        fm <= ports_except(rp);
                        s <= DEDUP;
                    end
                end

                LOCAL: begin
                    if (!fr_bc[rp]) begin fr_done[rp] <= 1; s <= IDLE; end
                    else            s <= DEDUP;
                end

                DEDUP: begin
                    d_src <= fr_src[rp]; d_cnt <= fr_cnt[rp];
                    d_lkup <= 1; s <= DEDUP_WAIT;
                end

                DEDUP_WAIT: begin
                    s <= FWDSET;
                end

                FWDSET: begin
                    if (d_found) begin fr_done[rp] <= 1; s <= IDLE; end
                    else begin
                        d_ins <= 1; crc_i <= 1; si <= 0; s <= FWDSYNC;
                    end
                end

                // Write sync word to all forward ports
                FWDSYNC: begin
                    if ((fm & tx_f) == {NUM_PORTS{1'b0}}) begin
                        for (p = 0; p < NUM_PORTS; p = p + 1)
                            if (fm[p]) begin
                                tx_din[p] <= SYNC_WORD; tx_wr[p] <= 1;
                            end
                        si <= 1; s <= FWDDATA;
                    end
                end

                // Write header + payload words, compute CRC
                FWDDATA: begin
                    if ((fm & tx_f) == {NUM_PORTS{1'b0}}) begin
                        if (si == 1) begin
                            for (p = 0; p < NUM_PORTS; p = p + 1)
                                if (fm[p]) begin
                                    tx_din[p] <= {fr_src[rp], fr_dst[rp], fr_cnt[rp]};
                                    tx_wr[p]  <= 1;
                                end
                            crc_e <= 1; crc_d <= {fr_src[rp], fr_dst[rp], fr_cnt[rp]};
                            si <= 2; s <= FWDDATA;
                        end else if (si == 2) begin
                            for (p = 0; p < NUM_PORTS; p = p + 1)
                                if (fm[p]) begin
                                    tx_din[p] <= {sl, 16'd0}; tx_wr[p] <= 1;
                                end
                            crc_e <= 1; crc_d <= {sl, 16'd0};
                            if (sl > 0) begin fr_paddr[rp] <= 0; si <= 3; end
                            else        begin s <= FWDCRC; end
                        end else if (si >= 3 && si < (3 + sl)) begin
                            for (p = 0; p < NUM_PORTS; p = p + 1)
                                if (fm[p]) begin
                                    tx_din[p] <= fr_pld[rp]; tx_wr[p] <= 1;
                                end
                            crc_e <= 1; crc_d <= fr_pld[rp];
                            if (si == 3 + sl - 1) begin s <= FWDCRC; end
                            else begin
                                fr_paddr[rp] <= si - 3 + 1; si <= si + 1;
                            end
                        end
                    end
                end

                // Finalize CRC
                FWDCRC: begin crc_f <= 1; s <= FWDCRC_WAIT; end

                FWDCRC_WAIT: begin s <= DISCARD; end

                // Write CRC word, release frame receiver
                DISCARD: begin
                    if ((fm & tx_f) == {NUM_PORTS{1'b0}}) begin
                        for (p = 0; p < NUM_PORTS; p = p + 1)
                            if (fm[p]) begin
                                tx_din[p] <= crc_r; tx_wr[p] <= 1;
                            end
                        if (!selfp) fr_done[rp] <= 1;
                        selfp <= 0; s <= IDLE;
                    end
                end

                // ---- Self-packet transmission ----
                SELFSET: begin
                    crc_i <= 1; si <= 0; selfp <= 1;
                    fm <= PORT_MASK; s <= SELFDATA;
                end

                SELFDATA: begin
                    if ((fm & tx_f) == {NUM_PORTS{1'b0}}) begin
                        if (si == 0) begin
                            for (p = 0; p < NUM_PORTS; p = p + 1)
                                if (fm[p]) begin
                                    tx_din[p] <= SYNC_WORD; tx_wr[p] <= 1;
                                end
                            si <= 1; s <= SELFDATA;
                        end else if (si == 1) begin
                            for (p = 0; p < NUM_PORTS; p = p + 1)
                                if (fm[p]) begin
                                    tx_din[p] <= {my_id, BROADCAST, self_c}; tx_wr[p] <= 1;
                                end
                            crc_e <= 1; crc_d <= {my_id, BROADCAST, self_c};
                            si <= 2; s <= SELFDATA;
                        end else if (si == 2) begin
                            for (p = 0; p < NUM_PORTS; p = p + 1)
                                if (fm[p]) begin
                                    tx_din[p] <= 0; tx_wr[p] <= 1;
                                end
                            crc_e <= 1; crc_d <= 0;
                            s <= SELFCRC;
                        end
                    end
                end

                SELFCRC: begin crc_f <= 1; s <= SELFCRC_WAIT; end

                SELFCRC_WAIT: begin s <= SELFDONE; end

                SELFDONE: begin
                    if ((fm & tx_f) == {NUM_PORTS{1'b0}}) begin
                        for (p = 0; p < NUM_PORTS; p = p + 1)
                            if (fm[p]) begin
                                tx_din[p] <= crc_r; tx_wr[p] <= 1;
                            end
                        selfp <= 0; s <= IDLE;
                    end
                end

                default: s <= IDLE;
            endcase
        end
    end

endmodule
