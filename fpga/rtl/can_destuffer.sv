`timescale 1ns/1ps

module can_destuffer (
    input  wire clk,
    input  wire reset_n,
    input  wire clear,
    input  wire stuff_enable,
    input  wire bit_valid,
    input  wire bit_value,
    input  wire bit_sof,
    output reg  data_valid,
    output reg  data_bit,
    output reg  data_sof,
    output reg  stuff_error
);
    reg last_bit, expect_stuff;
    reg [2:0] run_length;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            last_bit <= 1;
            expect_stuff <= 0;
            run_length <= 0;
            data_valid <= 0;
            data_bit <= 1;
            data_sof <= 0;
            stuff_error <= 0;
        end else begin
            data_valid <= 0;
            data_sof <= 0;
            stuff_error <= 0;
            if (clear) begin
                expect_stuff <= 0;
                run_length <= 0;
            end else if (bit_valid) begin
                if (bit_sof) begin
                    last_bit <= bit_value;
                    run_length <= 1;
                    expect_stuff <= 0;
                    data_bit <= bit_value;
                    data_valid <= 1;
                    data_sof <= 1;
                end else if (expect_stuff) begin
                    // This takes priority over stuff_enable: the final CRC bit
                    // can itself require a stuff bit before the CRC delimiter.
                    if (bit_value == last_bit) stuff_error <= 1;
                    last_bit <= bit_value;
                    run_length <= 1;
                    expect_stuff <= 0;
                end else begin
                    data_bit <= bit_value;
                    data_valid <= 1;
                    if (stuff_enable) begin
                        last_bit <= bit_value;
                        if (run_length != 0 && bit_value == last_bit) begin
                            run_length <= run_length + 1'b1;
                            if (run_length == 4) expect_stuff <= 1;
                        end else run_length <= 1;
                    end else run_length <= 0;
                end
            end
        end
    end
endmodule
