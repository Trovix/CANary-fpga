"""Independently validate the source's optional on-wire trace (Python stdlib only).

This is a stimulus QA tool, not the FPGA receiver you will build. CRC validation
uses polynomial long division, rather than the shift-register code in the SV.
"""

import argparse
import csv
from pathlib import Path


def require(condition, message):
    if not condition:
        raise ValueError(message)


def crc_remainder(bits):
    remainder = int(bits, 2)
    polynomial = 0xC599  # includes the x^15 term
    while remainder.bit_length() >= polynomial.bit_length():
        remainder ^= polynomial << (remainder.bit_length() - polynomial.bit_length())
    return remainder


def decode_frame(wire):
    """Destuff until the parsed DLC says the CRC is complete; check the trailer."""
    require(bool(wire) and set(wire) <= {"0", "1"}, "non-binary or empty frame")
    decoded = []
    position = 0
    last = None
    run = 0
    stuffed = 0
    expected_length = 34  # 19 header + 15 CRC, then add DLC * 8
    while len(decoded) < expected_length:
        require(position < len(wire), "truncated stuffed region")
        value = wire[position]
        position += 1
        decoded.append(value)
        run = run + 1 if value == last else 1
        last = value
        if len(decoded) == 19:
            dlc = int("".join(decoded[15:19]), 2)
            require(dlc <= 8, "DLC outside the supported 0..8 range")
            expected_length += 8 * dlc
        if run == 5:
            require(position < len(wire), "missing stuff bit")
            require(wire[position] != last, f"stuff error at wire bit {position}")
            last = wire[position]
            position += 1
            run = 1
            stuffed += 1

    bits = "".join(decoded)
    require(bits[0] == "0", "SOF must be dominant")
    require(bits[12:15] == "000", "expected standard data frame (RTR/IDE/r0=0)")
    trailer = wire[position:]
    require(len(trailer) == 13, "expected delimiter, ACK, EOF and intermission")
    require(trailer[0] == "1" and trailer[2:] == "1" * 11, "invalid fixed-form trailer")
    # Both ACK values are permitted: the source can model an acknowledged bus
    # or leave the slot recessive. Our receiver will never need to drive ACK.
    require(crc_remainder(bits) == 0, "CRC mismatch")
    return {
        "id": int(bits[1:12], 2),
        "dlc": int(bits[15:19], 2),
        "data": bytes(int(bits[i:i+8], 2) for i in range(19, len(bits) - 15, 8)),
        "crc": int(bits[-15:], 2),
        "stuff_count": stuffed,
        "ack": trailer[1],
    }


def check_trace(path, first_id, last_id, sweeps, payload, dlc, bit_time_ns,
                extra_idle_bits, ack_dominant):
    count = 0
    total_stuff = 0
    previous_start = None
    previous_length = None
    with path.open(newline="", encoding="utf-8") as handle:
        for row in csv.DictReader(handle, delimiter="\t"):
            try:
                frame = decode_frame(row["bits"])
                expected_id = first_id + count % (last_id - first_id + 1)
                require(frame["id"] == expected_id == int(row["id"], 16), "ID/order mismatch")
                require(frame["dlc"] == dlc == int(row["dlc"]), "DLC mismatch")
                require(frame["data"] == payload[:dlc], "payload mismatch")
                require(int(row["payload"], 16) == int.from_bytes(payload, "big"), "payload metadata mismatch")
                require(frame["crc"] == int(row["crc"], 16), "CRC metadata mismatch")
                require(frame["stuff_count"] == int(row["stuff_count"]), "stuff-count mismatch")
                require(frame["ack"] == ("0" if ack_dominant else "1"), "ACK mismatch")
                start = int(row["start_ns"])
                if previous_start is not None:
                    require(start - previous_start == (previous_length + extra_idle_bits) * bit_time_ns,
                            "frame spacing mismatch")
                previous_start, previous_length = start, len(row["bits"])
                total_stuff += frame["stuff_count"]
                count += 1
            except (ValueError, KeyError) as error:
                raise ValueError(f"trace row {count + 2}: {error}") from error
    require(count == (last_id - first_id + 1) * sweeps, "incorrect frame count")
    print(f"PASS: {count} frames; IDs 0x{first_id:03X}..0x{last_id:03X}; "
          f"{total_stuff} stuff bits; payload, CRC, framing and spacing verified")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trace", type=Path)
    parser.add_argument("--first-id", type=lambda s: int(s, 0), default=0)
    parser.add_argument("--last-id", type=lambda s: int(s, 0), default=0x7FF)
    parser.add_argument("--sweeps", type=int, default=1)
    parser.add_argument("--payload", default="00FF55AA12345678")
    parser.add_argument("--dlc", type=int, default=8)
    parser.add_argument("--bit-time-ns", type=int, default=1000)
    parser.add_argument("--extra-idle-bits", type=int, default=0)
    parser.add_argument("--recessive-ack", action="store_true")
    args = parser.parse_args()
    payload = bytes.fromhex(args.payload)
    require(len(payload) == 8, "--payload must specify eight bytes (DLC selects the prefix)")
    require(0 <= args.first_id <= args.last_id <= 0x7FF, "invalid ID range")
    require(0 <= args.dlc <= 8 and args.sweeps > 0, "invalid DLC/sweeps")
    check_trace(args.trace, args.first_id, args.last_id, args.sweeps,
                payload, args.dlc, args.bit_time_ns, args.extra_idle_bits,
                not args.recessive_ack)


if __name__ == "__main__":
    main()
