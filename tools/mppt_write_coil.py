#!/usr/bin/env python3
# Write a single Modbus coil on an EPEVER Tracer MPPT controller.
#
# Coil addresses are from EPEVER's official "B-Series MODBUS Specification"
# (Read Coils 0x01 / Write Single Coil 0x05 section). The one this project
# actually uses is coil 0, "Charging device on/off" (1=on, 0=off) - the
# documented way to actually stop charging, as opposed to the "battery
# temperature warning lower limit" holding register (0x9018), which per the
# same spec only sets a status flag and does not stop charging by itself.

import argparse
import inspect
import sys

from pymodbus.client import ModbusSerialClient


def write_coil(port, baudrate, slave_id, address, value, timeout):
    client = ModbusSerialClient(
        port=port, baudrate=baudrate, bytesize=8, parity="N", stopbits=1, timeout=timeout
    )
    if not client.connect():
        raise ConnectionError(f"could not open {port}")

    slave_kw = (
        "device_id"
        if "device_id" in inspect.signature(client.write_coil).parameters
        else "slave"
    )

    try:
        result = client.write_coil(address=address, value=value, **{slave_kw: slave_id})
        if result.isError():
            raise IOError(f"failed to write coil {address}: {result}")

        # Read the coil back rather than trusting the write's own ack: this
        # is the only way to confirm the command actually took (e.g. a full
        # battery already not drawing charge current looks identical to
        # charging being switched off, so there's no other observable sign).
        readback = client.read_coils(address=address, count=1, **{slave_kw: slave_id})
        if readback.isError():
            raise IOError(f"wrote coil {address} but could not read it back: {readback}")
        actual = readback.bits[0]
        if actual != value:
            raise IOError(f"wrote coil {address}={value} but controller now reports {actual}")
        return actual
    finally:
        client.close()


def main():
    parser = argparse.ArgumentParser(
        description="Write a single coil on an EPEVER Tracer MPPT controller."
    )
    parser.add_argument("--port", required=True)
    parser.add_argument("--baudrate", type=int, default=115200)
    parser.add_argument("--slave-id", type=int, default=1)
    parser.add_argument("--address", type=int, required=True, help="coil address, e.g. 0 for charging device on/off")
    parser.add_argument("--value", type=int, required=True, choices=[0, 1])
    parser.add_argument("--timeout", type=float, default=3.0)
    args = parser.parse_args()

    try:
        actual = write_coil(args.port, args.baudrate, args.slave_id, args.address, bool(args.value), args.timeout)
    except Exception as exc:
        print(f"mppt_write_coil: {exc}", file=sys.stderr)
        return 1

    print(f"Coil {args.address} confirmed as {int(actual)} (read back after writing {args.value})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
