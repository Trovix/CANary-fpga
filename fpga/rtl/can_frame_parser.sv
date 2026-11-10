`timescale 1ns/1ps

// Initial parser for Classical CAN standard DATA frames, DLC 0..8 only.
// Captures the received CRC; it does NOT yet calculate or validate it.
module can_frame_parser (
    input  wire clk,
    input  wire reset_n,
    input  wire data_valid,
    input  wire data_bit,
    input  wire data_sof,
    input  wire stuff_error,
    output wire stuff_enable,
    output reg  frame_start,
    output reg  header_valid,
    output reg  frame_complete,
    output reg  form_error,
    output reg  unsupported_frame,
    output reg  abort_frame,
    output reg  finish_frame,
    output wire allow_sof,
    output reg  [10:0] identifier,
    output reg  [3:0] dlc,
    output reg  [63:0] payload,
    output reg  [14:0] received_crc,
    output reg  ack_seen,
    output wire crc_data_valid,
    output wire crc_data_bit
);
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
            abort_frame <= 0;
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
            abort_frame <= 0;
            finish_frame <= 0;
            if (stuff_error) begin
                state <= IDLE;
                abort_frame <= 1;
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
                        abort_frame <= 1;
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
                                abort_frame <= 1;
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
                                    abort_frame <= 1;
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
                                abort_frame <= 1;
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
