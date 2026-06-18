`timescale 1ns / 1ps

//------------------------------------------------------------------------------
// port_tx_queue_sender: drains one main-clock frame queue into one TX async FIFO.
//   Queue-head timeout only applies before a frame starts writing to the async
//   FIFO. Once SEND begins, the sender keeps the frame intact and waits out
//   tx_full as needed.
//------------------------------------------------------------------------------
module port_tx_queue_sender #(
    parameter TIME_W = 32,
    parameter TX_QUEUE_TIMEOUT_CYCLES = 800_000_000
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [33:0] frame_dout,
    input  wire        frame_empty,
    output reg         frame_rd_en,
    input  wire [TIME_W+15:0] meta_dout,
    input  wire        meta_empty,
    output reg         meta_rd_en,
    input  wire [TIME_W-1:0] current_time,
    input  wire        tx_full,
    output reg         tx_wr_en,
    output reg  [31:0] tx_din,
    output reg         timeout_drop
);
    localparam [1:0] S_IDLE = 2'd0;
    localparam [1:0] S_SEND = 2'd1;
    localparam [1:0] S_DROP = 2'd2;
    localparam [TIME_W-1:0] TIMEOUT_CYCLES = TX_QUEUE_TIMEOUT_CYCLES;

    reg [1:0] st;
    reg [15:0] words_left;
    wire [15:0] meta_frame_words = meta_dout[15:0];
    wire [TIME_W-1:0] meta_enqueue_time = meta_dout[TIME_W+15:16];
    wire timeout_hit = (TIMEOUT_CYCLES != {TIME_W{1'b0}}) &&
                       ((current_time - meta_enqueue_time) >= TIMEOUT_CYCLES);

    always @(posedge clk) begin
        if (rst) begin
            st <= S_IDLE;
            words_left <= 16'd0;
            frame_rd_en <= 1'b0;
            meta_rd_en <= 1'b0;
            tx_wr_en <= 1'b0;
            tx_din <= 32'd0;
            timeout_drop <= 1'b0;
        end else begin
            frame_rd_en <= 1'b0;
            meta_rd_en <= 1'b0;
            tx_wr_en <= 1'b0;
            timeout_drop <= 1'b0;

            case (st)
                S_IDLE: begin
                    words_left <= 16'd0;
                    if (!meta_empty) begin
                        if (timeout_hit) begin
                            words_left <= meta_frame_words;
                            st <= S_DROP;
                        end else if (!frame_empty && !tx_full) begin
                            tx_din <= frame_dout[31:0];
                            tx_wr_en <= 1'b1;
                            frame_rd_en <= 1'b1;
                            if (meta_frame_words <= 16'd1) begin
                                meta_rd_en <= 1'b1;
                                st <= S_IDLE;
                            end else begin
                                words_left <= meta_frame_words - 1'b1;
                                st <= S_SEND;
                            end
                        end
                    end
                end

                S_SEND: begin
                    if (!frame_empty && !tx_full) begin
                        tx_din <= frame_dout[31:0];
                        tx_wr_en <= 1'b1;
                        frame_rd_en <= 1'b1;
                        if (words_left <= 16'd1) begin
                            meta_rd_en <= 1'b1;
                            words_left <= 16'd0;
                            st <= S_IDLE;
                        end else begin
                            words_left <= words_left - 1'b1;
                        end
                    end
                end

                S_DROP: begin
                    if (!frame_empty) begin
                        frame_rd_en <= 1'b1;
                        if (words_left <= 16'd1) begin
                            meta_rd_en <= 1'b1;
                            timeout_drop <= 1'b1;
                            words_left <= 16'd0;
                            st <= S_IDLE;
                        end else begin
                            words_left <= words_left - 1'b1;
                        end
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
