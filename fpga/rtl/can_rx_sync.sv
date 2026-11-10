`timescale 1ns/1ps

// Only this module touches the asynchronous transceiver RX pin.
module can_rx_sync (
    input  wire clk,
    input  wire reset_n,
    input  wire can_rx,
    output wire rx_sync
);
    (* async_reg = "true" *) reg [1:0] rx_ff;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) rx_ff <= 2'b11;
        else          rx_ff <= {rx_ff[0], can_rx};
    end

    assign rx_sync = rx_ff[1];
endmodule
