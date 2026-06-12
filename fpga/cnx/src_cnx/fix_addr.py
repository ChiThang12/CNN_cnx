
# fix_addr.py
# BUG B fix: cnn_top.v - quan_en must be FALSE for L3/L4 (Dense layers)
# BUG C fix: addr_gen.v - bram_w3_addr_r must NOT increment at counter==0

# ============================================================
# BUG B: cnn_top.v relu_en / quan_en
# ============================================================
with open('cnn_top.v', 'r', encoding='latin-1') as f:
    content = f.read()

old_b = "  assign relu_en = (layer == 3'd1) || (layer == 3'd2) || (layer == 3'd3);\n  assign quan_en = relu_en;"
new_b = ("  // relu_en: active for Conv1(L1), Conv2(L2), Dense1(L3) output-final only\n"
         "  // quan_en: active ONLY for Conv1/Conv2 (to quantize feature maps to 8-bit)\n"
         "  //          MUST be FALSE for Dense1/Dense2 (accumulate full 32-bit sum)\n"
         "  assign relu_en = (layer == 3'd1) || (layer == 3'd2) || (layer == 3'd3) || (layer == 3'd4);\n"
         "  assign quan_en = (layer == 3'd1) || (layer == 3'd2);  // FIX BUG B: Dense layers must NOT quantize")

if old_b in content:
    content = content.replace(old_b, new_b, 1)
    print('BUG B fixed in cnn_top.v')
else:
    print('BUG B: target not found in cnn_top.v')

with open('cnn_top.v', 'w', encoding='latin-1') as f:
    f.write(content)

# ============================================================
# BUG C: addr_gen.v - skip counter==0 increment
# ============================================================
with open('addr_gen.v', 'r', encoding='latin-1') as f:
    lines = f.readlines()

fixed = False
for i, line in enumerate(lines):
    if line.rstrip() == '      else if (state == L3_RD)':
        # Check next line is the increment
        if i+2 < len(lines) and 'bram_w3_addr_r <= bram_w3_addr_r + 32' in lines[i+2]:
            lines[i] = "      else if (state == L3_RD && counter != 7'd0)  // FIX BUG C: skip prefetch cycle\n"
            fixed = True
            print(f'BUG C fixed in addr_gen.v at line {i+1}')
            break

if not fixed:
    print('BUG C: target not found in addr_gen.v')

with open('addr_gen.v', 'w', encoding='latin-1') as f:
    f.writelines(lines)

print('Done.')
