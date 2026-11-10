`timescale 1ns/1ps

// Directed waveform replay. Inputs contain no DUT state or framing sideband.
module tb_can_receiver;
    reg clk = 0;
    reg reset_n = 0;
    reg can_rx = 1;
    always #10 clk = !clk;

    wire busy, frame_start, header_valid, frame_complete;
    wire stuff_error, form_error, unsupported_frame;
    wire [10:0] identifier;
    wire [3:0] dlc;
    wire [63:0] payload;
    wire [14:0] received_crc;
    wire ack_seen, crc_data_valid, crc_data_bit;
    can_sniffer dut (.*);

    integer received = 0, stuff_errors = 0, form_errors = 0, unsupported = 0;
    integer expected_count, expected_stuff, expected_form, expected_unsupported;
    integer expected_fd, waveform_fd, status, duration_ns, value;
    integer expected_id, expected_dlc, expected_crc, expected_ack;
    reg [63:0] expected_payload;
    string waveform_path, expected_path;

    always @(posedge clk) begin
        if (reset_n) begin
            if (stuff_error) stuff_errors = stuff_errors + 1;
            if (form_error) form_errors = form_errors + 1;
            if (unsupported_frame) unsupported = unsupported + 1;
            if (frame_complete) begin
                status = $fscanf(expected_fd, "%h %d %h %h %d\n",
                    expected_id, expected_dlc, expected_payload, expected_crc, expected_ack);
                if (status != 5) $fatal(1, "Unexpected completed frame");
                if (identifier !== 11'(expected_id) || dlc !== 4'(expected_dlc) ||
                    payload !== expected_payload || received_crc !== 15'(expected_crc) ||
                    ack_seen !== 1'(expected_ack))
                    $fatal(1, "Replay mismatch: ID=%03h DLC=%0d payload=%016h CRC=%04h ACK=%b",
                        identifier, dlc, payload, received_crc, ack_seen);
                received = received + 1;
            end
        end
    end

    initial begin
        if (!$value$plusargs("waveform=%s", waveform_path) ||
            !$value$plusargs("expected=%s", expected_path) ||
            !$value$plusargs("frames=%d", expected_count) ||
            !$value$plusargs("stuff_errors=%d", expected_stuff) ||
            !$value$plusargs("form_errors=%d", expected_form) ||
            !$value$plusargs("unsupported=%d", expected_unsupported))
            $fatal(1, "Missing replay arguments");
        waveform_fd = $fopen(waveform_path, "r");
        expected_fd = $fopen(expected_path, "r");
        if (!waveform_fd || !expected_fd) $fatal(1, "Cannot open replay files");
        repeat (10) @(negedge clk);
        reset_n = 1;
        while (!$feof(waveform_fd)) begin
            status = $fscanf(waveform_fd, "%d %d\n", duration_ns, value);
            if (status != 2 || duration_ns <= 0) $fatal(1, "Invalid waveform row");
            // Value 2 interrupts reception with reset, then returns bus idle.
            if (value == 2) begin
                reset_n = 0;
                can_rx = 1;
                #(duration_ns);
                reset_n = 1;
            end else begin
                can_rx = 1'(value);
                #(duration_ns);
            end
        end
        repeat (10) @(negedge clk);
        if (received != expected_count || stuff_errors != expected_stuff ||
            form_errors != expected_form || unsupported != expected_unsupported)
            $fatal(1, "Replay counts: frames=%0d/%0d stuff=%0d/%0d form=%0d/%0d unsupported=%0d/%0d",
                received, expected_count, stuff_errors, expected_stuff,
                form_errors, expected_form, unsupported, expected_unsupported);
        $fclose(waveform_fd);
        $fclose(expected_fd);
        $display("PASS: directed replay: %0d frames, %0d stuff errors, %0d form errors, %0d unsupported",
            received, stuff_errors, form_errors, unsupported);
        $finish;
    end

    initial begin
        #100000000;
        $fatal(1, "Replay timeout");
    end
endmodule
