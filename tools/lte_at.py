#!/usr/bin/env python3
# Send a single AT command to an LTE modem over a serial port and print its
# response. Written to replace the sim_modem library's Modem() handshake
# (ATZ + ATE1) for the Waveshare SIM7600G-H HAT: that handshake reliably
# failed with "ValueError: 'ATE1' is not in list" on this hardware even
# though the port and baud rate are correct (confirmed manually via minicom
# at 115200), so this talks to the port directly with no assumptions beyond
# "the module replies with a line containing OK or ERROR".

import argparse
import sys
import time

import serial


def send_at(port, baudrate, command, timeout):
    with serial.Serial(port=port, baudrate=baudrate, timeout=timeout) as ser:
        ser.reset_input_buffer()
        ser.write((command + "\r\n").encode("ascii"))
        buf = b""
        deadline = time.time() + timeout
        while time.time() < deadline:
            chunk = ser.read(256)
            if chunk:
                buf += chunk
                if b"OK" in buf or b"ERROR" in buf:
                    break
            else:
                time.sleep(0.05)
    return buf.decode("ascii", errors="replace")


def main():
    parser = argparse.ArgumentParser(description="Send one AT command and print the response.")
    parser.add_argument("--port", required=True)
    parser.add_argument("--baudrate", type=int, default=115200)
    parser.add_argument("--cmd", required=True, help='AT command, e.g. "AT+CFUN=0"')
    parser.add_argument("--timeout", type=float, default=5.0)
    args = parser.parse_args()

    try:
        response = send_at(args.port, args.baudrate, args.cmd, args.timeout)
    except Exception as exc:
        print(f"lte_at: could not talk to {args.port}: {exc}", file=sys.stderr)
        return 1

    print(response.strip())
    if "OK" in response:
        return 0
    print(f"lte_at: no OK in response to {args.cmd!r}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
