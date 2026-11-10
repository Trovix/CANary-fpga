# CANary FPGA

Initial receive-only Classical CAN receiver for my dissertation.

The implementation lives in **`fpga/rtl/can_receiver.sv`**. It contains one
module, with four commented sections:

1. Synchronise the asynchronous transceiver RX input.
2. Find SOF, track bit timing and sample the bus.
3. Remove stuff bits and detect stuffing errors.
4. Parse standard 11-bit data frames and capture their fields.

Everything runs on `clk`; valid pulses advance the later sections.
Default timing is 50 MHz / 1 Mbit/s, an 80% sample point and a resynchronisation
limit of four clock cycles. The only inputs are `clk`, `reset_n` and `can_rx`.
Reset must be released synchronously to `clk` by the integrating design.

The parser exposes ID, DLC, payload, received CRC and ACK state. Payload bytes
start at `[63:56]`; unused bytes remain zero. Event signals last one clock.
`header_valid` marks the parsed header; `frame_complete` marks the end of EOF.
**CRC validation is still pending:** frame completion does not mean CRC passed.
`crc_data_valid` and `crc_data_bit` provide the destuffed SOF-through-data stream
for that next step. This design never drives ACK or any other bus signal.
Remote/extended frames, DLC >8 and CAN FD are outside the current scope.

## Simulation

**`fpga/sim/tb_can_stimulus.sv`** generates CAN traffic, instantiates the receiver
as `dut`, and checks its outputs. Use `fpga/sim/run.do` in Questa, or
`fpga/sim/run.ps1` with Icarus Verilog and Python installed. The original
`check_can_trace.py` independently validates the generated stimulus trace.
Simulation output goes in `fpga/sim/out/` (ignored by Git).

This consolidation preserves the existing receiver logic. Known timing/boundary
and malformed-frame issues remain; the earlier regression was not fully passing.
The extra replay testbench and regression runner have been removed to keep this
initial setup small. Quartus board configuration and hardware validation are
still pending.
