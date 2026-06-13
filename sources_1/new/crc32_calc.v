`timescale 1ns / 1ps
//------------------------------------------------------------------------------
// CRC32 Calculator (Ethernet polynomial 0x04C11DB7, parallel 32-bit/cycle)
//   - init=1: reset CRC to 0xFFFFFFFF
//   - en=1:   process one 32-bit data word
//   - finalize=1: apply final XOR (0xFFFFFFFF), result on crc_out next cycle
//------------------------------------------------------------------------------
module crc32_calc (
    input  wire        clk,
    input  wire        rst,
    input  wire        init,
    input  wire        en,
    input  wire [31:0] data,
    input  wire        finalize,
    output wire [31:0] crc_out
);
    reg [31:0] crc_reg, crc_latched;

    function [31:0] crc32_parallel;
        input [31:0] c_in; input [31:0] d_in;
        reg [31:0] c; integer i;
        begin
            c = c_in;
            for (i = 0; i < 32; i = i + 1)
                c = {c[30:0], 1'b0} ^ ({32{c[31] ^ d_in[31-i]}} & 32'h04C11DB7);
            crc32_parallel = c;
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin crc_reg <= 32'hFFFFFFFF; crc_latched <= 0; end
        else begin
            if (init)       crc_reg <= 32'hFFFFFFFF;
            else if (en)    crc_reg <= crc32_parallel(crc_reg, data);
            if (finalize)   crc_latched <= crc_reg ^ 32'hFFFFFFFF;
        end
    end
    assign crc_out = crc_latched;

endmodule
