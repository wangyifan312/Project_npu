#!/usr/bin/env python3
"""Generate bisected weight memh: zero a sub-range of cin=14's 288 bytes."""
import sys

SRC = 'tb/generated/resnet20_r1j_package_slice/layer2_0_conv1_weights.memh'
DST = 'tb/generated/resnet20_r1j_package_slice/layer2_0_conv1_weights_bisect.memh'

zero_start = int(sys.argv[1])
zero_end   = int(sys.argv[2])

with open(SRC, 'r') as f:
    lines = f.readlines()

for i in range(zero_start, min(zero_end, len(lines))):
    lines[i] = '00\n'

with open(DST, 'w') as f:
    f.writelines(lines)

# Count actual zeros in range
zeros = sum(1 for i in range(zero_start, min(zero_end, len(lines))) if lines[i].strip() == '00')
print(f'BISECT: zeroed [{zero_start}, {zero_end}) = {zeros} bytes -> {DST}')
