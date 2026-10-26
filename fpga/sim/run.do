# Run in Questa's Transcript: do C:/Users/james/diss/fpga/sim/run.do
set sim_dir [file dirname [file normalize [info script]]]
file mkdir [file join $sim_dir out]
cd [file join $sim_dir out]
if {![file isdirectory work]} { vlib work }
vlog -sv [file join $sim_dir tb_can_stimulus.sv]
vsim -onfinish stop -voptargs=+acc work.tb_can_stimulus +trace=frames.tsv
add wave sim:/tb_can_stimulus/can_rx
add wave sim:/tb_can_stimulus/reset_n
add wave sim:/tb_can_stimulus/frame_active
add wave -radix hexadecimal sim:/tb_can_stimulus/current_id
add wave -radix hexadecimal sim:/tb_can_stimulus/current_payload
add wave -radix hexadecimal sim:/tb_can_stimulus/current_crc
add wave sim:/tb_can_stimulus/is_stuff_bit
add wave sim:/tb_can_stimulus/stuff_count
add wave sim:/tb_can_stimulus/wire_bit_index
add wave sim:/tb_can_stimulus/frames_sent
run -all
wave zoom range 0ns 150us
