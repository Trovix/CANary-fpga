"""Run receiver regression with Icarus Verilog and Python (no Python packages).

Usage from any directory: python fpga/sim/run_tests.py
Requires iverilog and vvp on PATH. Outputs go to fpga/sim/out/regression.
"""

import csv
import random
import shutil
import subprocess
from pathlib import Path

from check_can_trace import check_trace, crc_remainder


SIM = Path(__file__).resolve().parent
RTL = sorted((SIM.parent / "rtl").glob("*.sv"))
OUT = SIM / "out" / "regression"


def run(command):
    result = subprocess.run([str(arg) for arg in command], cwd=OUT,
                            text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(f"Command failed: {command}\n{result.stdout}{result.stderr}")
    if result.stderr:
        print(result.stderr, end="")
    return result.stdout


def stimulus(name, **parameters):
    executable = OUT / f"{name}.vvp"
    trace = OUT / f"{name}.tsv"
    defaults = dict(FIRST_ID=0, LAST_ID=0x7FF, SWEEPS=1, DLC=8,
                    PAYLOAD="64'h00FF55AA12345678", BIT_TIME_NS=1000,
                    EXTRA_IDLE_BITS=0, DUMP_FRAMES=0, ACK_DOMINANT=0)
    defaults.update(parameters)
    run(["iverilog", "-g2012", "-Wall", "-s", "tb_can_stimulus", "-o", executable,
         *(f"-Ptb_can_stimulus.{key}={value}" for key, value in defaults.items()),
         *RTL, SIM / "tb_can_stimulus.sv"])
    output = run(["vvp", executable, f"+trace={trace}"])
    assert "PASS: receiver decoded" in output, output
    print(f"{name}: ", end="", flush=True)
    check_trace(trace, defaults["FIRST_ID"], defaults["LAST_ID"], defaults["SWEEPS"],
                bytes.fromhex(defaults["PAYLOAD"].split("'h")[1]), defaults["DLC"],
                defaults["BIT_TIME_NS"], defaults["EXTRA_IDLE_BITS"],
                bool(defaults["ACK_DOMINANT"]))
    return trace


def unstuff(row):
    wire = row["bits"]
    body = ""
    position, run_length, last = 0, 0, None
    expected_length = 34 + 8 * int(row["dlc"])
    while len(body) < expected_length:
        bit = wire[position]
        body += bit
        position += 1
        run_length = run_length + 1 if bit == last else 1
        last = bit
        if run_length == 5:
            assert wire[position] != last
            last = wire[position]
            position += 1
            run_length = 1
    assert len(wire) - position == 13
    return body, wire[position:]


def stuff(body):
    wire, positions = "", []
    last, run_length = None, 0
    for bit in body:
        wire += bit
        run_length = run_length + 1 if bit == last else 1
        last = bit
        if run_length == 5:
            positions.append(len(wire))
            last = "1" if bit == "0" else "0"
            wire += last
            run_length = 1
    return wire, positions


def replace_field(body, first, end, bits):
    body = body[:first] + bits + body[end:]
    # Recalculate using the checker's polynomial division (not the SV LFSR).
    return body[:-15] + f"{crc_remainder(body[:-15] + '0' * 15):015b}"


def expectation(body, trailer):
    dlc = int(body[15:19], 2)
    data = body[19:-15].ljust(64, "0")
    return (f"{int(body[1:12], 2):03x} {dlc} {int(data, 2):016x} "
            f"{int(body[-15:], 2):04x} {int(trailer[1] == '0')}\n")


def directed(trace):
    with trace.open(newline="") as handle:
        rows = list(csv.DictReader(handle, delimiter="\t"))
    body, trailer = unstuff(rows[0x123])
    good, positions = stuff(body)
    terminal = None
    for row in rows:
        candidate, candidate_trailer = unstuff(row)
        wire, stuffed_at = stuff(candidate)
        if stuffed_at and stuffed_at[-1] == len(wire) - 1:
            terminal = candidate, candidate_trailer
            break
    assert terminal is not None, "Regression must exercise terminal CRC stuffing"
    waveform = []
    expected = []
    counts = dict(stuff_errors=0, form_errors=0, unsupported=0)

    def bits(wire, jitter=False):
        for bit in wire:
            waveform.append((1000 + (rng.choice((-20, 0, 20)) if jitter else 0), int(bit)))

    def idle():
        waveform.append((20007, 1))

    def valid(frame_body=body, frame_trailer=trailer, jitter=False):
        wire, _ = stuff(frame_body)
        bits(wire + frame_trailer, jitter)
        expected.append(expectation(frame_body, frame_trailer))

    def rejected(wire, error):
        bits(wire)
        counts[error] += 1
        idle()
        valid()
        idle()

    rng = random.Random(0xCA)
    # Attach partway through activity, then a stuck dominant bus: neither may
    # become a SOF until eleven recessive bit times have been observed.
    bits((good + trailer)[20:60])
    bits("0" * 30)
    idle()
    valid()
    idle()

    bad = list(good + trailer)
    bad[positions[0]] = bad[positions[0] - 1]
    rejected("".join(bad), "stuff_errors")

    terminal_wire, terminal_positions = stuff(terminal[0])
    valid(*terminal)  # required stuff bit immediately after the last CRC bit
    idle()
    bad = list(terminal_wire + terminal[1])
    bad[terminal_positions[-1]] = bad[terminal_positions[-1] - 1]
    rejected("".join(bad), "stuff_errors")

    # Fixed-form fields and the first two intermission bits. A dominant
    # third intermission bit is SOF, exercised separately below.
    for trailer_index in (0, 2, 3, 9, 10, 11):
        bad_trailer = trailer[:trailer_index] + "0" + trailer[trailer_index + 1:]
        if trailer_index >= 10:
            # EOF was already complete before the intermission error.
            expected.append(expectation(body, trailer))
        rejected(good + bad_trailer, "form_errors")

    for first, end, value in ((12, 13, "1"), (13, 14, "1"), (15, 19, "1001")):
        mutated = replace_field(body, first, end, value)
        rejected(stuff(mutated)[0] + trailer, "unsupported")

    # Either value of the reserved r0 bit is accepted in Classical CAN.
    valid(replace_field(body, 14, 15, "1"))
    idle()
    valid(frame_trailer=trailer[:1] + "0" + trailer[2:])
    idle()

    # The next frame starts on the third intermission bit.
    bits(good + trailer[:-1])
    expected.append(expectation(body, trailer))
    valid()
    idle()

    # CRC checking is intentionally not implemented: capture a wrong CRC
    # unchanged and complete the structurally correct frame.
    bad_crc = body[:-1] + ("1" if body[-1] == "0" else "0")
    valid(bad_crc)
    idle()

    # Reset during reception, reacquire idle, and receive the next frame.
    bits(good[:40])
    waveform.append((200, 2))
    idle()
    valid()
    idle()
    for _ in range(16):
        valid(jitter=True)
    idle()

    waveform_path = OUT / "directed.waveform"
    expected_path = OUT / "directed.expected"
    waveform_path.write_text("".join(f"{duration} {value}\n" for duration, value in waveform))
    expected_path.write_text("".join(expected))
    executable = OUT / "directed.vvp"
    run(["iverilog", "-g2012", "-Wall", "-s", "tb_can_receiver", "-o", executable,
         *RTL, SIM / "tb_can_receiver.sv"])
    output = run(["vvp", executable, f"+waveform={waveform_path}",
                  f"+expected={expected_path}", f"+frames={len(expected)}",
                  *(f"+{key}={value}" for key, value in counts.items())])
    print(output, end="")


def main():
    for tool in ("iverilog", "vvp"):
        if not shutil.which(tool):
            raise SystemExit(f"Install Icarus Verilog and put {tool} on PATH")
    OUT.mkdir(parents=True, exist_ok=True)
    trace = stimulus("all_ids")
    for dlc in range(9):
        stimulus(f"dlc_{dlc}", FIRST_ID=0x100, LAST_ID=0x11F, DLC=dlc)
    for payload in ("0000000000000000", "FFFFFFFFFFFFFFFF",
                    "5555555555555555", "AAAAAAAAAAAAAAAA"):
        stimulus(f"payload_{payload[:2]}", LAST_ID=127, PAYLOAD=f"64'h{payload}")
    for bit_time in (990, 995, 1005, 1010):
        stimulus(f"bit_time_{bit_time}", LAST_ID=127, BIT_TIME_NS=bit_time)
    for phase in (0, 3, 11, 19):
        stimulus(f"phase_{phase}", LAST_ID=15, START_OFFSET_NS=phase)
    stimulus("ack_and_sweeps", FIRST_ID=0x7F0, LAST_ID=0x7FF,
             ACK_DOMINANT=1, EXTRA_IDLE_BITS=9, SWEEPS=2)
    directed(trace)
    print("PASS: receiver regression complete")


if __name__ == "__main__":
    main()
