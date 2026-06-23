`timescale 1ns / 1ps

module tb_frame_rx_idle_timeout;
    localparam SYNC_WORD = 32'hA31E57BD;
    localparam MAX_PAYLOAD = 256;

    reg clk = 1'b0;
    reg rst = 1'b1;
    reg rx_pause = 1'b0;
    wire [31:0] fifo_dout;
    wire fifo_empty;
    wire fifo_rd_en;
    wire frame_ready;
    wire [7:0] rx_src_id;
    wire [7:0] rx_dst_id;
    wire [15:0] rx_count;
    wire [15:0] rx_len16;
    reg [15:0] payload_index = 16'd0;
    wire [31:0] rx_payload;
    wire rx_is_broadcast;
    reg frame_consumed = 1'b0;

    reg [31:0] fifo_mem [0:1023];
    integer rd_ptr = 0;
    integer wr_ptr = 0;
    integer fifo_count = 0;

    assign fifo_empty = (fifo_count == 0);
    assign fifo_dout = fifo_empty ? 32'd0 : fifo_mem[rd_ptr[9:0]];

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (rst) begin
            rd_ptr <= 0;
            wr_ptr <= 0;
            fifo_count <= 0;
        end else if (fifo_rd_en && fifo_count > 0) begin
            rd_ptr <= rd_ptr + 1;
            fifo_count <= fifo_count - 1;
        end
    end

    frame_rx #(
        .SYNC_WORD(SYNC_WORD),
        .MAX_PAYLOAD(MAX_PAYLOAD),
        .CLK_FREQ_HZ(1000),
        .CONGEST_TIMEOUT_SEC(1)
    ) dut (
        .clk(clk),
        .rst(rst),
        .rx_pause(rx_pause),
        .fifo_dout(fifo_dout),
        .fifo_empty(fifo_empty),
        .fifo_rd_en(fifo_rd_en),
        .frame_ready(frame_ready),
        .rx_src_id(rx_src_id),
        .rx_dst_id(rx_dst_id),
        .rx_count(rx_count),
        .rx_len16(rx_len16),
        .payload_index(payload_index),
        .rx_payload(rx_payload),
        .rx_is_broadcast(rx_is_broadcast),
        .frame_consumed(frame_consumed)
    );

    function automatic [31:0] crc32_word(input [31:0] crc_in, input [31:0] data);
        integer i;
        reg [31:0] crc;
        begin
            crc = crc_in;
            for (i = 0; i < 32; i = i + 1) begin
                crc = {crc[30:0], 1'b0} ^ ({32{crc[31] ^ data[31-i]}} & 32'h04C11DB7);
            end
            crc32_word = crc;
        end
    endfunction

    function automatic [31:0] frame_crc(
        input [31:0] header1,
        input [31:0] header2,
        input [31:0] payload0,
        input [31:0] payload1,
        input integer len
    );
        reg [31:0] crc;
        begin
            crc = 32'hFFFFFFFF;
            crc = crc32_word(crc, header1);
            crc = crc32_word(crc, header2);
            if (len > 0) crc = crc32_word(crc, payload0);
            if (len > 1) crc = crc32_word(crc, payload1);
            frame_crc = crc ^ 32'hFFFFFFFF;
        end
    endfunction

    task automatic fail(input [1023:0] msg);
        begin
            $display("FAIL: %0s", msg);
            $finish;
        end
    endtask

    task automatic push_word(input [31:0] word);
        begin
            @(negedge clk);
            if (fifo_count >= 1024) fail("test FIFO overflow");
            fifo_mem[wr_ptr[9:0]] = word;
            wr_ptr = wr_ptr + 1;
            fifo_count = fifo_count + 1;
        end
    endtask

    task automatic push_word_gap(input [31:0] word, input integer gap_cycles);
        integer i;
        begin
            push_word(word);
            for (i = 0; i < gap_cycles; i = i + 1) @(posedge clk);
        end
    endtask

    task automatic send_frame_gap(
        input [7:0] src,
        input [7:0] dst,
        input [15:0] count,
        input integer len,
        input [31:0] payload0,
        input [31:0] payload1,
        input integer gap_cycles
    );
        reg [31:0] header1;
        reg [31:0] header2;
        reg [31:0] crc;
        begin
            header1 = {src, dst, count};
            header2 = {len[15:0], 16'd0};
            crc = frame_crc(header1, header2, payload0, payload1, len);
            push_word_gap(SYNC_WORD, gap_cycles);
            push_word_gap(header1, gap_cycles);
            push_word_gap(header2, gap_cycles);
            if (len > 0) push_word_gap(payload0, gap_cycles);
            if (len > 1) push_word_gap(payload1, gap_cycles);
            push_word_gap(crc, gap_cycles);
        end
    endtask

    task automatic expect_frame(
        input [7:0] exp_src,
        input [7:0] exp_dst,
        input [15:0] exp_count,
        input [15:0] exp_len,
        input [31:0] exp_payload0,
        input [31:0] exp_payload1
    );
        integer cycles;
        begin
            cycles = 0;
            while (!frame_ready && cycles < 200) begin
                @(posedge clk);
                cycles = cycles + 1;
            end
            if (!frame_ready) fail("expected frame_ready");
            if (rx_src_id !== exp_src) fail("rx_src_id mismatch");
            if (rx_dst_id !== exp_dst) fail("rx_dst_id mismatch");
            if (rx_count !== exp_count) fail("rx_count mismatch");
            if (rx_len16 !== exp_len) fail("rx_len16 mismatch");
            if (exp_len > 0) begin
                payload_index = 16'd0;
                #1;
                if (rx_payload !== exp_payload0) fail("payload[0] mismatch");
            end
            if (exp_len > 1) begin
                payload_index = 16'd1;
                #1;
                if (rx_payload !== exp_payload1) fail("payload[1] mismatch");
            end
            @(negedge clk);
            frame_consumed = 1'b1;
            @(negedge clk);
            frame_consumed = 1'b0;
            payload_index = 16'd0;
        end
    endtask

    integer i;

    initial begin
        repeat (5) @(posedge clk);
        rst = 1'b0;
        repeat (5) @(posedge clk);

        send_frame_gap(8'h11, 8'h22, 16'h0101, 2, 32'hCAFE0001, 32'hCAFE0002, 20);
        expect_frame(8'h11, 8'h22, 16'h0101, 16'd2, 32'hCAFE0001, 32'hCAFE0002);

        push_word_gap(SYNC_WORD, 0);
        push_word_gap({8'h33, 8'h44, 16'h0202}, 0);
        push_word_gap({16'd2, 16'd0}, 0);
        push_word_gap(32'hBAD00001, 0);

        for (i = 0; i < 1100; i = i + 1) begin
            @(posedge clk);
            if (frame_ready) fail("half frame unexpectedly produced frame_ready");
        end
        if (dut.st !== 3'd0) fail("frame_rx did not return to HUNT after idle timeout");

        send_frame_gap(8'h55, 8'h66, 16'h0303, 2, 32'hFACE0001, 32'hFACE0002, 0);
        expect_frame(8'h55, 8'h66, 16'h0303, 16'd2, 32'hFACE0001, 32'hFACE0002);

        $display("PASS: tb_frame_rx_idle_timeout completed");
        $finish;
    end
endmodule