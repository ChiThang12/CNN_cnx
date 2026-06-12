
# fix_bugC_correct.py
# BUG C correct fix: skip addr increment at LAST cycle (counter==16), not first (counter==0)
# Explanation:
#   With 17 cycles (counter 0..16), addr increments 17 times but stride should be 16.
#   Skipping counter=0 (first) caused mem[0] to be captured twice.
#   Skipping counter=16 (last) fixes the stride without disturbing the capture timing.

with open('addr_gen.v', 'r', encoding='latin-1') as f:
    lines = f.readlines()

fixed = False
for i, line in enumerate(lines):
    # Find the line we incorrectly patched
    if 'L3_RD' in line and 'counter != 7' in line and 'FIX BUG C' in line:
        # Replace wrong fix (counter != 0) with correct fix (counter != 16)
        lines[i] = "      else if (state == L3_RD && counter != 7'd16)  // FIX BUG C: skip LAST cycle to maintain stride=16\n"
        fixed = True
        print(f'BUG C corrected at line {i+1}')
        break

if not fixed:
    print('Target not found, searching broader...')
    for i, line in enumerate(lines):
        if 'state == L3_RD' in line and 'counter' in line:
            print(f'Line {i+1}: {repr(line)}')

with open('addr_gen.v', 'w', encoding='latin-1') as f:
    f.writelines(lines)

# Verify
with open('addr_gen.v', 'r', encoding='latin-1') as f:
    content = f.read()

import re
m = re.search(r'else if.*L3_RD.*counter.*\n.*bram_w3_addr', content)
if m:
    print(f'Verified: {m.group()}')

print('Done.')
