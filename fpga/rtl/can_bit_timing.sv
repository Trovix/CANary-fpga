`timescale 1ns/1ps

// Clock-enable based sampler: one FPGA clock is one timing quantum.
// Defaults: 50 MHz, 1 Mbit/s, 80% sample point, 80 ns resync limit.
module can_bit_timing #(
    parameter integer CLKS_PER_BIT = 50,
    parameter integer SAMPLE_POINT = 40,
    parameter integer SJW = 4
) (
    input  wire clk,
    input  wire reset_n,
    input  wire rx_sync,
    input  wire finish_frame,
    input  wire abort_frame,
    input  wire allow_sof,
    output reg  busy,
    output reg  bit_valid,
    output reg  bit_value,
    output reg  bit_sof
);
    localparam integer PHASE_WIDTH = $clog2(CLKS_PER_BIT);
    localparam integer IDLE_CLKS = 11 * CLKS_PER_BIT;
    localparam integer IDLE_WIDTH = $clog2(IDLE_CLKS + 1);
    reg [PHASE_WIDTH-1:0] phase;
    reg [IDLE_WIDTH-1:0] idle_count;
    reg previous_rx, previous_sample;
    reg idle_ready, sof_pending, resynced;
    wire falling_edge = previous_rx && !rx_sync;

    // Leave at least five clocks after sampling for parser feedback.
    initial begin
        if (CLKS_PER_BIT < 16 || SAMPLE_POINT < 2 ||
            SAMPLE_POINT > CLKS_PER_BIT - 5 || SJW < 1 ||
            SJW > CLKS_PER_BIT - SAMPLE_POINT)
            $fatal(1, "Invalid CAN bit timing parameters");
    end

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            phase <= 0;
            idle_count <= 0;
            previous_rx <= 1;
            previous_sample <= 1;
            idle_ready <= 0;
            sof_pending <= 0;
            resynced <= 0;
            busy <= 0;
            bit_valid <= 0;
            bit_value <= 1;
            bit_sof <= 0;
        end else begin
            previous_rx <= rx_sync;
            bit_valid <= 0;
            bit_sof <= 0;

            // At startup / after rejection, acquire eleven recessive bit times.
            if (!rx_sync) idle_count <= 0;
            else if (idle_count < IDLE_WIDTH'(IDLE_CLKS)) idle_count <= idle_count + 1'b1;
            if (!busy && rx_sync && idle_count >= IDLE_WIDTH'(IDLE_CLKS - 1))
                idle_ready <= 1;

            if (abort_frame) begin
                busy <= 0;
                idle_ready <= 0;
                idle_count <= 0;
                sof_pending <= 0;
            end else if (falling_edge && ((!busy && idle_ready) || allow_sof || finish_frame)) begin
                // Also recognise SOF at the third intermission bit. This
                // matters when two nodes' clocks differ slightly.
                busy <= 1;
                idle_ready <= 0;
                phase <= 0;
                sof_pending <= 1;
                previous_sample <= 1;
                resynced <= 1;
            end else if (finish_frame) begin
                // The parser has sampled EOF and all three intermission bits.
                // Do not demand eleven *nominal* bit times again: the sender
                // may run slightly faster than our clock.
                busy <= 0;
                idle_ready <= 1;
                sof_pending <= 0;
            end else if (busy) begin
                if (phase == PHASE_WIDTH'(SAMPLE_POINT - 1)) begin
                    bit_value <= rx_sync;
                    previous_sample <= rx_sync;
                    bit_valid <= 1;
                    bit_sof <= sof_pending;
                    sof_pending <= 0;
                end

                // Only recessive-to-dominant edges differing from the previous
                // sampled value can resynchronise, at most once per bit.
                if (falling_edge && previous_sample && !resynced &&
                    phase < PHASE_WIDTH'(SAMPLE_POINT - 1)) begin
                    // Late boundary: lengthen the segment before sampling.
                    if (int'(phase) + 1 <= SJW) phase <= 0;
                    else phase <= phase + 1'b1 - PHASE_WIDTH'(SJW);
                    resynced <= 1;
                end else if (falling_edge && previous_sample && !resynced &&
                             phase >= PHASE_WIDTH'(SAMPLE_POINT)) begin
                    // Early boundary: shorten the segment after sampling.
                    if (CLKS_PER_BIT - (int'(phase) + 1) <= SJW) begin
                        phase <= 0;
                        resynced <= 1;
                    end else begin
                        phase <= phase + 1'b1 + PHASE_WIDTH'(SJW);
                        resynced <= 1;
                    end
                end else if (phase == PHASE_WIDTH'(CLKS_PER_BIT - 1)) begin
                    phase <= 0;
                    resynced <= 0;
                end else begin
                    phase <= phase + 1'b1;
                end
            end
        end
    end
endmodule
