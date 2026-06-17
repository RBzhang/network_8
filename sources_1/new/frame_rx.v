`timescale 1ns / 1ps
//------------------------------------------------------------------------------
// Frame Receiver (per port)
//   Reads from async RX FIFO, detects sync word, assembles frame, checks CRC32.
//   On CRC pass: asserts frame_ready, exposes header fields and payload buffer.
//   Scheduler asserts frame_consumed to release this receiver.
//------------------------------------------------------------------------------
module frame_rx #(
    parameter SYNC_WORD  = 32'hA31E57BD,
    parameter MAX_PAYLOAD = 256,
    parameter CLK_FREQ_HZ = 160_000_000,
    parameter CONGEST_TIMEOUT_SEC = 5
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        rx_pause,
    input  wire [31:0] fifo_dout,
    input  wire        fifo_empty,
    output wire        fifo_rd_en,

    output reg         frame_ready,
    output reg  [7:0]  rx_src_id,
    output reg  [7:0]  rx_dst_id,
    output reg  [15:0] rx_count,
    output reg  [15:0] rx_len16,
    input  wire [15:0] payload_index,
    output wire [31:0] rx_payload,
    output reg         rx_is_broadcast,
    input  wire        frame_consumed
);
    localparam [2:0] HUNT = 0, HEADER1 = 1, HEADER2 = 2, PAYLOAD = 3,
                     CRC = 4, CRC_WAIT = 5, CHECK = 6, DONE = 7;

    reg [2:0]  st;
    reg [15:0] wi, tlen;
    reg [31:0] buff [0:MAX_PAYLOAD-1];
    reg [7:0]  sid, did;
    reg [15:0] cnt;
    reg [15:0] plen;
    reg        crc_init, crc_en, crc_final;
    reg [31:0] crc_din;
    wire [31:0] crc_res;
    reg [31:0] crc_rcv;
    localparam integer CONGEST_TIMEOUT_CYCLES = CLK_FREQ_HZ * CONGEST_TIMEOUT_SEC;
    localparam integer CONGEST_TIMER_W = (CONGEST_TIMEOUT_CYCLES <= 1) ? 1 : $clog2(CONGEST_TIMEOUT_CYCLES + 1);
    reg [CONGEST_TIMER_W-1:0] pause_count;
    wire in_partial_frame = (st != HUNT) && (st != CRC_WAIT) && (st != CHECK) && (st != DONE);

    crc32_calc u_crc (
        .clk(clk), .rst(rst),
        .init(crc_init), .en(crc_en), .data(crc_din),
        .finalize(crc_final), .crc_out(crc_res)
    );

    assign fifo_rd_en = !rx_pause && (st != CRC_WAIT) && (st != CHECK) && (st != DONE);
    assign rx_payload = (st == DONE && frame_ready) ? buff[payload_index] : 32'd0;

    always @(posedge clk) begin
        if (rst) begin
            st <= HUNT; wi <= 0; tlen <= 0; frame_ready <= 0;
            crc_init <= 0; crc_en <= 0; crc_final <= 0; crc_din <= 0; crc_rcv <= 0;
            pause_count <= {CONGEST_TIMER_W{1'b0}};
        end else begin
            crc_init <= 0; crc_en <= 0; crc_final <= 0;
            if (frame_ready && frame_consumed) begin
                frame_ready <= 0; st <= HUNT; wi <= 0;
                pause_count <= {CONGEST_TIMER_W{1'b0}};
            end else if (rx_pause && in_partial_frame) begin
                if (pause_count >= CONGEST_TIMEOUT_CYCLES - 1) begin
                    st <= HUNT;
                    wi <= 0;
                    tlen <= 0;
                    frame_ready <= 1'b0;
                    pause_count <= {CONGEST_TIMER_W{1'b0}};
                end else begin
                    pause_count <= pause_count + 1'b1;
                end
            end else begin
                pause_count <= {CONGEST_TIMER_W{1'b0}};
                case (st)
                HUNT: begin
                    pause_count <= {CONGEST_TIMER_W{1'b0}};
                    if (!fifo_empty && fifo_dout == SYNC_WORD) begin
                        st <= HEADER1; crc_init <= 1;
                    end
                end

                HEADER1: begin
                    if (!fifo_empty) begin
                        sid  <= fifo_dout[31:24];
                        did  <= fifo_dout[23:16];
                        cnt  <= fifo_dout[15:0];
                        crc_en <= 1; crc_din <= fifo_dout;
                        st <= HEADER2;
                    end
                end

                HEADER2: begin
                    if (!fifo_empty) begin
                        plen   <= fifo_dout[31:16];
                        crc_en <= 1; crc_din <= fifo_dout;
                        if (fifo_dout[31:16] > MAX_PAYLOAD) begin
                            st <= HUNT;
                        end else if (fifo_dout[31:16] == 0) begin
                            tlen <= 0; st <= CRC;
                        end else begin
                            tlen <= fifo_dout[31:16]; wi <= 0; st <= PAYLOAD;
                        end
                    end
                end

                PAYLOAD: begin
                    if (!fifo_empty) begin
                        buff[wi] <= fifo_dout;
                        crc_en <= 1; crc_din <= fifo_dout;
                        if (wi == tlen - 1) st <= CRC;
                        else                wi <= wi + 1;
                    end
                end

                CRC: begin
                    if (!fifo_empty) begin
                        crc_rcv <= fifo_dout;
                        crc_final <= 1;
                        st <= CRC_WAIT;
                    end
                end

                CRC_WAIT: begin
                        st <= CHECK;
                end

                CHECK: begin
                    if (crc_res == crc_rcv) begin
                        rx_src_id <= sid; rx_dst_id <= did;
                        rx_count <= cnt; rx_len16 <= plen;
                        rx_is_broadcast <= (did == 8'hFF);
                        frame_ready <= 1;
                        st <= DONE;
                    end else begin
                        st <= HUNT;
                    end
                end

                DONE: begin
                    st <= DONE;
                end

                default: st <= HUNT;
                endcase
            end
        end
    end

endmodule
