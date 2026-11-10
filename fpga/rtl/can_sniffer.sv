`timescale 1ns/1ps

// Receive-only top level. Connect can_rx to a CAN transceiver's logic-level RX.
// All outputs are in clk's domain; event/valid signals last one clock.
module can_sniffer #(
    parameter integer CLKS_PER_BIT = 50,
    parameter integer SAMPLE_POINT = 40,
    parameter integer SJW = 4
) (
    input  wire clk,
    input  wire reset_n,
    input  wire can_rx,
    output wire busy,
    output wire frame_start,
    output wire header_valid,
    output wire frame_complete,
    output wire stuff_error,
    output wire form_error,
    output wire unsupported_frame,
    output wire [10:0] identifier,
    output wire [3:0] dlc,
    output wire [63:0] payload,
    output wire [14:0] received_crc,
    output wire ack_seen,
    output wire crc_data_valid,
    output wire crc_data_bit
);
    wire rx_sync, bit_valid, bit_value, bit_sof;
    wire data_valid, data_bit, data_sof, stuff_enable, parser_abort;
    wire finish_frame, allow_sof;
    wire abort_frame = parser_abort || stuff_error;

    can_rx_sync synchroniser (
        .clk(clk), .reset_n(reset_n), .can_rx(can_rx), .rx_sync(rx_sync)
    );
    can_bit_timing #(
        .CLKS_PER_BIT(CLKS_PER_BIT), .SAMPLE_POINT(SAMPLE_POINT), .SJW(SJW)
    ) timing (
        .clk(clk), .reset_n(reset_n), .rx_sync(rx_sync),
        .finish_frame(finish_frame), .abort_frame(abort_frame), .allow_sof(allow_sof),
        .busy(busy), .bit_valid(bit_valid), .bit_value(bit_value), .bit_sof(bit_sof)
    );
    can_destuffer destuffer (
        .clk(clk), .reset_n(reset_n), .clear(abort_frame || frame_complete),
        .stuff_enable(stuff_enable), .bit_valid(bit_valid),
        .bit_value(bit_value), .bit_sof(bit_sof),
        .data_valid(data_valid), .data_bit(data_bit), .data_sof(data_sof),
        .stuff_error(stuff_error)
    );
    can_frame_parser parser (
        .clk(clk), .reset_n(reset_n), .data_valid(data_valid),
        .data_bit(data_bit), .data_sof(data_sof), .stuff_error(stuff_error),
        .stuff_enable(stuff_enable), .frame_start(frame_start),
        .header_valid(header_valid), .frame_complete(frame_complete),
        .form_error(form_error), .unsupported_frame(unsupported_frame),
        .abort_frame(parser_abort), .identifier(identifier), .dlc(dlc),
        .finish_frame(finish_frame), .allow_sof(allow_sof),
        .payload(payload), .received_crc(received_crc), .ack_seen(ack_seen),
        .crc_data_valid(crc_data_valid), .crc_data_bit(crc_data_bit)
    );
endmodule
