`timescale 1ns/1ps

// Receive-only Classical CAN receiver (standard 11-bit data frames). Connect can_rx to a CAN transceiver's logic-level RX.
// All outputs are in clk's domain; event/valid signals last one clock.
module can_receiver #(
    parameter integer CLKS_PER_BIT = 50,
    parameter integer SAMPLE_POINT = 40,
    parameter integer SJW = 4
) (
    input  wire clk,
    input  wire reset_n,
    input  wire can_rx,
    output reg busy,
    output reg frame_start,
    output reg header_valid,
    output reg frame_complete,
    output reg stuff_error,
    output reg form_error,
    output reg unsupported_frame,
    output reg [10:0] identifier,
    output reg [3:0] dlc,
    output reg [63:0] payload,
    output reg [14:0] received_crc,
    output reg ack_seen,
    output wire crc_data_valid,
    output wire crc_data_bit
);
    reg bit_valid, bit_value, bit_sof;
    reg data_valid, data_bit, data_sof;
    reg parser_abort, finish_frame;
    wire rx_sync, stuff_enable, allow_sof;
    wire abort_frame = parser_abort || stuff_error;

    // 1. Synchronise the asynchronous RX input
    (* async_reg = "true" *) reg [1:0] rx_ff;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) rx_ff <= 2'b11;
        else          rx_ff <= {rx_ff[0], can_rx};
    end

    assign rx_sync = rx_ff[1];

    // 2. Synchronise bit timing and sample the bus
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

    // 3. Remove stuff bits
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
            if (abort_frame || frame_complete) begin
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

    // 4. Track frame fields (CRC validation still pending)
    typedef enum logic [3:0] {
        IDLE, IDENTIFIER, RTR, IDE, R0, DLC, DATA, CRC,
        CRC_DELIMITER, ACK, ACK_DELIMITER, EOF_BITS, INTERMISSION
    } state_t;
    state_t state;
    reg [6:0] count;
    wire [3:0] next_dlc = {dlc[2:0], data_bit};

    assign stuff_enable = state >= IDENTIFIER && state <= CRC;
    assign allow_sof = state == INTERMISSION && count == 2;
    // Hook for the next stage: unstuffed SOF through the final data bit.
    // A future CRC accumulator resets on data_sof and uses these enables.
    assign crc_data_valid = data_valid && !stuff_error &&
                            (data_sof || (state >= IDENTIFIER && state <= DATA));
    assign crc_data_bit = data_bit;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state <= IDLE;
            count <= 0;
            frame_start <= 0;
            header_valid <= 0;
            frame_complete <= 0;
            form_error <= 0;
            unsupported_frame <= 0;
            parser_abort <= 0;
            finish_frame <= 0;
            identifier <= 0;
            dlc <= 0;
            payload <= 0;
            received_crc <= 0;
            ack_seen <= 0;
        end else begin
            frame_start <= 0;
            header_valid <= 0;
            frame_complete <= 0;
            form_error <= 0;
            unsupported_frame <= 0;
            parser_abort <= 0;
            finish_frame <= 0;
            if (stuff_error) begin
                state <= IDLE;
                parser_abort <= 1;
            end else if (data_valid) begin
                if (data_sof) begin
                    identifier <= 0;
                    dlc <= 0;
                    payload <= 0;
                    received_crc <= 0;
                    ack_seen <= 0;
                    count <= 0;
                    if (data_bit) begin
                        state <= IDLE;
                        form_error <= 1;
                        parser_abort <= 1;
                    end else begin
                        state <= IDENTIFIER;
                        frame_start <= 1;
                    end
                end else begin
                    case (state)
                        IDENTIFIER: begin
                            identifier <= {identifier[9:0], data_bit};
                            if (count == 10) begin state <= RTR; count <= 0; end
                            else count <= count + 1'b1;
                        end
                        RTR, IDE: begin
                            if (data_bit) begin
                                unsupported_frame <= 1;
                                parser_abort <= 1;
                                state <= IDLE;
                            end else if (state == RTR) state <= IDE;
                            else state <= R0;
                        end
                        R0: begin
                            // Classical CAN receivers tolerate either value of
                            // the reserved bit; CAN FD is outside this scope.
                            state <= DLC;
                            count <= 0;
                        end
                        DLC: begin
                            dlc <= next_dlc;
                            if (count == 3) begin
                                count <= 0;
                                if (next_dlc > 8) begin
                                    unsupported_frame <= 1;
                                    parser_abort <= 1;
                                    state <= IDLE;
                                end else begin
                                    header_valid <= 1;
                                    if (next_dlc == 0) state <= CRC;
                                    else state <= DATA;
                                end
                            end else count <= count + 1'b1;
                        end
                        DATA: begin
                            // First byte occupies [63:56], unused bytes stay zero.
                            payload[63-count] <= data_bit;
                            if (count == {dlc, 3'b000} - 1'b1) begin
                                state <= CRC;
                                count <= 0;
                            end else count <= count + 1'b1;
                        end
                        CRC: begin
                            received_crc <= {received_crc[13:0], data_bit};
                            if (count == 14) begin state <= CRC_DELIMITER; count <= 0; end
                            else count <= count + 1'b1;
                        end
                        ACK: begin
                            ack_seen <= !data_bit;
                            state <= ACK_DELIMITER;
                        end
                        CRC_DELIMITER, ACK_DELIMITER, EOF_BITS, INTERMISSION: begin
                            if (!data_bit) begin
                                form_error <= 1;
                                parser_abort <= 1;
                                state <= IDLE;
                            end else begin
                                case (state)
                                    CRC_DELIMITER: state <= ACK;
                                    ACK_DELIMITER: begin state <= EOF_BITS; count <= 0; end
                                    EOF_BITS: begin
                                        if (count == 6) begin
                                            frame_complete <= 1;
                                            state <= INTERMISSION;
                                            count <= 0;
                                        end
                                        else count <= count + 1'b1;
                                    end
                                    INTERMISSION: begin
                                        if (count == 2) begin
                                            finish_frame <= 1;
                                            state <= IDLE;
                                        end else count <= count + 1'b1;
                                    end
                                    default: state <= IDLE;
                                endcase
                            end
                        end
                        default: state <= IDLE;
                    endcase
                end
            end
        end
    end
endmodule
