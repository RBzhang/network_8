`timescale 1ns / 1ps

//------------------------------------------------------------------------------
// frame_tx: only frames one descriptor into a TX FIFO stream.
//------------------------------------------------------------------------------
module frame_tx #(
    parameter SYNC_WORD = 32'hA31E57BD
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [7:0]  src_id,
    input  wire [7:0]  dst_id,
    input  wire [15:0] count,
    input  wire [15:0] len16,
    output reg  [15:0] payload_index,
    input  wire [31:0] payload_data,
    input  wire        tx_full,
    output reg         tx_wr_en,
    output reg  [31:0] tx_din,
    output reg         busy,
    output reg         done
);
    localparam [2:0] S_IDLE      = 3'd0;
    localparam [2:0] S_SYNC      = 3'd1;
    localparam [2:0] S_HEADER1   = 3'd2;
    localparam [2:0] S_HEADER2   = 3'd3;
    localparam [2:0] S_PAYLOAD   = 3'd4;
    localparam [2:0] S_CRC       = 3'd5;
    localparam [2:0] S_CRC_WAIT  = 3'd6;
    localparam [2:0] S_DONE      = 3'd7;

    reg [2:0] st;
    reg [7:0]  src_r;
    reg [7:0]  dst_r;
    reg [15:0] count_r;
    reg [15:0] len_r;
    reg        crc_init;
    reg        crc_en;
    reg        crc_finalize;
    reg [31:0] crc_data;
    wire [31:0] crc_out;

    crc32_calc u_crc (
        .clk(clk),
        .rst(rst),
        .init(crc_init),
        .en(crc_en),
        .data(crc_data),
        .finalize(crc_finalize),
        .crc_out(crc_out)
    );

    always @(posedge clk) begin
        if (rst) begin
            st <= S_IDLE;
            src_r <= 8'd0;
            dst_r <= 8'd0;
            count_r <= 16'd0;
            len_r <= 16'd0;
            payload_index <= 16'd0;
            tx_wr_en <= 1'b0;
            tx_din <= 32'd0;
            busy <= 1'b0;
            done <= 1'b0;
            crc_init <= 1'b0;
            crc_en <= 1'b0;
            crc_finalize <= 1'b0;
            crc_data <= 32'd0;
        end else begin
            tx_wr_en <= 1'b0;
            done <= 1'b0;
            crc_init <= 1'b0;
            crc_en <= 1'b0;
            crc_finalize <= 1'b0;

            case (st)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        src_r <= src_id;
                        dst_r <= dst_id;
                        count_r <= count;
                        len_r <= len16;
                        payload_index <= 16'd0;
                        crc_init <= 1'b1;
                        busy <= 1'b1;
                        st <= S_SYNC;
                    end
                end

                S_SYNC: begin
                    if (!tx_full) begin
                        tx_din <= SYNC_WORD;
                        tx_wr_en <= 1'b1;
                        st <= S_HEADER1;
                    end
                end

                S_HEADER1: begin
                    if (!tx_full) begin
                        tx_din <= {src_r, dst_r, count_r};
                        tx_wr_en <= 1'b1;
                        crc_en <= 1'b1;
                        crc_data <= {src_r, dst_r, count_r};
                        st <= S_HEADER2;
                    end
                end

                S_HEADER2: begin
                    if (!tx_full) begin
                        tx_din <= {len_r, 16'd0};
                        tx_wr_en <= 1'b1;
                        crc_en <= 1'b1;
                        crc_data <= {len_r, 16'd0};
                        if (len_r == 0)
                            st <= S_CRC;
                        else
                            st <= S_PAYLOAD;
                    end
                end

                S_PAYLOAD: begin
                    if (!tx_full) begin
                        tx_din <= payload_data;
                        tx_wr_en <= 1'b1;
                        crc_en <= 1'b1;
                        crc_data <= payload_data;
                        if (payload_index == len_r - 1) begin
                            st <= S_CRC;
                        end else begin
                            payload_index <= payload_index + 1'b1;
                        end
                    end
                end

                S_CRC: begin
                    crc_finalize <= 1'b1;
                    st <= S_CRC_WAIT;
                end

                S_CRC_WAIT: begin
                    st <= S_DONE;
                end

                S_DONE: begin
                    if (!tx_full) begin
                        tx_din <= crc_out;
                        tx_wr_en <= 1'b1;
                        busy <= 1'b0;
                        done <= 1'b1;
                        st <= S_IDLE;
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
