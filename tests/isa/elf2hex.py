#!/usr/bin/env python3
"""Convert a flat binary (objcopy -O binary, linked at address 0) into the
one-32-bit-word-per-line hex file that axi_sram's $readmemh expects."""
import sys

data = open(sys.argv[1], "rb").read()
data += b"\0" * (-len(data) % 4)
with open(sys.argv[2], "w") as f:
    for i in range(0, len(data), 4):
        f.write(f"{int.from_bytes(data[i:i + 4], 'little'):08X}\n")
