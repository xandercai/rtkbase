#!/usr/bin/env python3
# Read one real-time snapshot from an EPEVER Tracer-series MPPT controller
# (tested against a Tracer-AN1210 G3) over Modbus RTU / RS485, and print it
# as a single line of JSON on stdout.
#
# Register addresses, scale factors and signedness come from EPEVER's
# published "B-Series MODBUS Specification" real-time data table (input
# registers, function code 0x04), cross-checked against the pyepsolartracer
# project's register map. All 16-bit values use a 0.01 scale unless noted;
# 32-bit values are stored as (low word at the lower address, high word at
# the next one): actual = low + high * 65536. Temperature registers are
# signed (two's complement) so sub-zero readings don't wrap to ~650 C.

import argparse
import inspect
import json
import sys
from datetime import datetime, timezone

from pymodbus.client import ModbusSerialClient

REALTIME_BLOCK_START = 0x3100
REALTIME_BLOCK_COUNT = 0x13  # covers 0x3100..0x3112 inclusive
BATTERY_SOC_ADDRESS = 0x311A

# name, offset within the block, word count, scale divisor, signed
REALTIME_FIELDS = [
    ("pv_voltage_v", 0, 1, 100, False),
    ("pv_current_a", 1, 1, 100, False),
    ("pv_power_w", 2, 2, 100, False),
    ("battery_voltage_v", 4, 1, 100, False),
    ("battery_charging_current_a", 5, 1, 100, False),
    ("battery_charging_power_w", 6, 2, 100, False),
    ("load_voltage_v", 12, 1, 100, False),
    ("load_current_a", 13, 1, 100, False),
    ("load_power_w", 14, 2, 100, False),
    ("battery_temperature_c", 16, 1, 100, True),
    ("controller_temperature_c", 17, 1, 100, True),
    ("heatsink_temperature_c", 18, 1, 100, True),
]


def to_signed16(raw):
    return raw - 0x10000 if raw & 0x8000 else raw


def decode_field(registers, offset, word_count, scale, signed):
    if word_count == 1:
        raw = registers[offset]
        if signed:
            raw = to_signed16(raw)
    else:
        raw = registers[offset] + (registers[offset + 1] << 16)
    return round(raw / scale, 2)


def read_snapshot(port, baudrate, slave_id, timeout):
    client = ModbusSerialClient(
        port=port, baudrate=baudrate, bytesize=8, parity="N", stopbits=1, timeout=timeout
    )
    if not client.connect():
        raise ConnectionError(f"could not open {port}")

    # pymodbus renamed the "slave" kwarg to "device_id" in newer 3.x releases.
    slave_kw = (
        "device_id"
        if "device_id" in inspect.signature(client.read_input_registers).parameters
        else "slave"
    )

    try:
        block = client.read_input_registers(
            address=REALTIME_BLOCK_START, count=REALTIME_BLOCK_COUNT, **{slave_kw: slave_id}
        )
        if block.isError():
            raise IOError(f"failed to read real-time data block: {block}")

        soc = client.read_input_registers(
            address=BATTERY_SOC_ADDRESS, count=1, **{slave_kw: slave_id}
        )
        if soc.isError():
            raise IOError(f"failed to read battery SOC: {soc}")

        snapshot = {
            name: decode_field(block.registers, offset, word_count, scale, signed)
            for name, offset, word_count, scale, signed in REALTIME_FIELDS
        }
        snapshot["battery_soc_pct"] = soc.registers[0]
        return snapshot
    finally:
        client.close()


def main():
    parser = argparse.ArgumentParser(
        description="Read a real-time snapshot from an EPEVER Tracer MPPT controller."
    )
    parser.add_argument("--port", required=True, help="serial device, e.g. /dev/epever485")
    parser.add_argument("--baudrate", type=int, default=115200)
    parser.add_argument("--slave-id", type=int, default=1)
    parser.add_argument("--timeout", type=float, default=3.0)
    args = parser.parse_args()

    try:
        snapshot = read_snapshot(args.port, args.baudrate, args.slave_id, args.timeout)
    except Exception as exc:
        print(f"mppt_read: {exc}", file=sys.stderr)
        return 1

    snapshot["timestamp_utc"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    snapshot["source"] = "epever_tracer_an1210_g3"
    print(json.dumps(snapshot, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
