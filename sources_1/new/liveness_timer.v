`timescale 1ns / 1ps

//------------------------------------------------------------------------------
// liveness_timer: generates one internal tick per second after ID assignment.
//------------------------------------------------------------------------------
module liveness_timer #(
    parameter CLK_FREQ_HZ = 160_000_000
) (
    input  wire clk,
    input  wire rst,
    output wire tick_1s
);
    reg [31:0] counter;

    always @(posedge clk) begin
        if (rst)
            counter <= 32'd0;
        else if (counter == CLK_FREQ_HZ - 1)
            counter <= 32'd0;
        else
            counter <= counter + 1'b1;
    end

    assign tick_1s = (counter == CLK_FREQ_HZ - 1);
endmodule
