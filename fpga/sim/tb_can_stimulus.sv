`timescale 1ns/1ps

// Simulated CAN bus source.
module tb_can_stimulus;
    parameter integer FIRST_ID = 0;
    parameter integer LAST_ID = 11'h7ff;
    parameter integer SWEEPS = 1;           	// sweep once`
    parameter integer DLC = 8;
    parameter [63:0] PAYLOAD = 64'h00_FF_55_AA_12_34_56_78;
    parameter integer BIT_TIME_NS = 1000;  	// 1 Mbit/s
    parameter integer CLK_PERIOD_NS = 20;  	// receiver clock: 50 MHz
    parameter integer EXTRA_IDLE_BITS = 0; 	// additional to 3-bit intermission
    parameter integer DUMP_FRAMES = 4;     	// how many frames to VCD record
    parameter bit ACK_DOMINANT = 0;        	// no ACKing 

    reg clk = 0;				
    reg reset_n = 0;								 	// future use
    reg can_rx = 1;                        	// 0 = dominant; 1 = recessive
    reg frame_active = 0;		
    reg is_stuff_bit = 0;							
    reg [10:0] current_id = 0;
    reg [3:0] current_dlc = DLC;
    reg [63:0] current_payload = PAYLOAD;   // first byte is [63:56]
    reg [14:0] current_crc = 0;
    integer wire_bit_index = 0;             // zero-based, includes stuff bits
    integer stuff_count = 0;
    integer frames_sent = 0;

    // DUT will go here 
	 // can_sniffer dut (
	 //	.clk(clk),
	 //   .reset_n(reset_n),
	 //   .can_rx(can_rx)

	 
    always #(CLK_PERIOD_NS / 2.0) clk = ~clk; 			//clock

    reg body [0:127];                      				// unstuffed SOF through CRC
    integer body_length;
    reg last_wire_bit;
    integer run_length;
    integer trace_fd = 0;
    string trace_path;
    string sent_bits;
    time frame_start_ns;

    // CRC-15: 
    function automatic [14:0] crc_next(input [14:0] crc, input bit value);
        reg feedback;
        begin
            feedback = crc[14] ^ value;
            crc_next = {crc[13:0], 1'b0};
            if (feedback) crc_next = crc_next ^ 15'h4599;
        end
    endfunction

	 //add bit to body
    task automatic append_body(input bit value);
        begin
            body[body_length] = value;
            body_length = body_length + 1;
        end
    endtask
	 
	 //frame builder 
    task automatic build_frame(input [10:0] identifier);
        integer i;
        reg [14:0] crc;
        begin
            body_length = 0;
            append_body(0);                // SOF
            for (i = 10; i >= 0; i = i - 1) append_body(identifier[i]);
            append_body(0);                // RTR: data frame
            append_body(0);                // IDE: standard 11-bit ID
            append_body(0);                // reserved r0
            for (i = 3; i >= 0; i = i - 1) append_body(current_dlc[i]);
            for (i = 0; i < 8 * DLC; i = i + 1) append_body(PAYLOAD[63-i]);

            crc = 0;
            for (i = 0; i < body_length; i = i + 1)
                crc = crc_next(crc, body[i]);
            current_crc = crc;
            for (i = 14; i >= 0; i = i - 1) append_body(crc[i]);
        end
    endtask
	 
	 //send next bit
    task automatic send_wire_bit(input bit value, input bit stuffed);
        begin
            can_rx = value;
            is_stuff_bit = stuffed;
            if (trace_fd != 0) sent_bits = {sent_bits, value ? "1" : "0"};
            #(BIT_TIME_NS);
            wire_bit_index = wire_bit_index + 1;
        end
    endtask

	 //send frame
    task automatic send_frame(input [10:0] identifier);
        integer i;
        begin
            current_id = identifier;
            build_frame(identifier);
            stuff_count = 0;
            wire_bit_index = 0;
            run_length = 0;
            last_wire_bit = 1;
            sent_bits = "";
            frame_start_ns = $time;
            frame_active = 1;

            // bitstuff
            for (i = 0; i < body_length; i = i + 1) begin
                send_wire_bit(body[i], 0);
                if (body[i] == last_wire_bit) run_length = run_length + 1;
                else run_length = 1;
                last_wire_bit = body[i];
                if (run_length == 5) begin
                    send_wire_bit(!last_wire_bit, 1);
                    stuff_count = stuff_count + 1;
                    last_wire_bit = !last_wire_bit;
                    run_length = 1;
                end
            end

            // trailing "bits" and bobs
            send_wire_bit(1, 0);           // CRC delimiter
            send_wire_bit(!ACK_DOMINANT, 0); // ACK
            send_wire_bit(1, 0);           // ACK delimiter
            repeat (7) send_wire_bit(1, 0); // EOF
            frame_active = 0;
            repeat (3) send_wire_bit(1, 0); // intermission
				
				//logging
            if (trace_fd != 0)
                $fdisplay(trace_fd, "%0d\t%03h\t%0d\t%016h\t%04h\t%0d\t%s",
                    frame_start_ns, current_id, DLC, PAYLOAD, current_crc,
                    stuff_count, sent_bits);
            frames_sent = frames_sent + 1;
            if (frames_sent <= 4 || current_id == LAST_ID)
                $display("frame %0d: ID=0x%03h DLC=%0d CRC=0x%04h stuff=%0d",
                    frames_sent, current_id, DLC, current_crc, stuff_count);
            if (DUMP_FRAMES > 0 && frames_sent == DUMP_FRAMES) $dumpoff;
				
				//wait for however many idle bits
            repeat (EXTRA_IDLE_BITS) #(BIT_TIME_NS);
        end
    endtask

    integer sweep;
    integer identifier;
    initial begin
        //range check
		  if (FIRST_ID < 0 || LAST_ID > 2047 || FIRST_ID > LAST_ID)
            $fatal(1, "ID range must be within 0x000..0x7ff");
		  //more checks
        if (DLC < 0 || DLC > 8 || SWEEPS < 0 || EXTRA_IDLE_BITS < 0 ||
            DUMP_FRAMES < 0 || BIT_TIME_NS <= 0 || CLK_PERIOD_NS <= 0)
            $fatal(1, "Invalid stimulus parameters");
		  //does logging work?
        if ($value$plusargs("trace=%s", trace_path)) begin
            trace_fd = $fopen(trace_path, "w");
            if (trace_fd == 0) $fatal(1, "Cannot open trace: %s", trace_path);
            $fdisplay(trace_fd, "start_ns\tid\tdlc\tpayload\tcrc\tstuff_count\tbits");
        end
		  
		  //start log
        if (DUMP_FRAMES > 0) begin
            $dumpfile("can_stimulus.vcd");
            $dumpvars(0, reset_n, can_rx, frame_active, is_stuff_bit,
                current_id, current_dlc, current_payload, current_crc,
                wire_bit_index, stuff_count, frames_sent);
        end

        repeat (10) @(negedge clk);
        reset_n = 1;
        // offset bus edges from the rx clock.
        #(11 * BIT_TIME_NS + 7);
        sweep = 0;
		  //sweep sweep sweep!
        while (SWEEPS == 0 || sweep < SWEEPS) begin
            for (identifier = FIRST_ID; identifier <= LAST_ID; identifier = identifier + 1)
                send_frame(identifier[10:0]);
            sweep = sweep + 1;
        end
		  
		  //log finish
        if (trace_fd != 0) $fclose(trace_fd);
        $display("DONE: sent %0d standard CAN data frames", frames_sent);
        $finish;
    end
endmodule
