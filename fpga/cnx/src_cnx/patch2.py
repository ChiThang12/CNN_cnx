file_path = 'cnn_tb.v'
with open(file_path, 'r', encoding='latin-1') as f:
    content = f.read()

# Them probe moi vao sau doan BUG PROBE hien tai
old = '''  // B?t kho?nh kh?c L3_RD counter==1 (l'''
new = '''  // [BUG PROBE 2] In raw bytes cua conv2_out_flat tai dense_cnt=10..12 (tap ranh gioi)
  if (cnn.u_fsm.state == 6'd17 && cnn.u_fsm.counter == 7'd0
      && cnn.u_fsm.ch_batch == 3'd0
      && (cnn.u_fsm.dense_cnt == 6'd10 || cnn.u_fsm.dense_cnt == 6'd11 || cnn.u_fsm.dense_cnt == 6'd12)) begin
    ("[PROBE2] t=%0t dense_cnt=%0d | conv2_out_flat offset_bit=%0d",
             , cnn.u_fsm.dense_cnt, cnn.u_fsm.dense_cnt * 64);
    ("         conv2_out_flat raw[d*64+0..+7]: %02x %02x %02x %02x %02x %02x %02x %02x",
             cnn.u_pe_array.conv2_out_flat[cnn.u_fsm.dense_cnt*64 +: 8],
             cnn.u_pe_array.conv2_out_flat[cnn.u_fsm.dense_cnt*64+8 +: 8],
             cnn.u_pe_array.conv2_out_flat[cnn.u_fsm.dense_cnt*64+16 +: 8],
             cnn.u_pe_array.conv2_out_flat[cnn.u_fsm.dense_cnt*64+24 +: 8],
             cnn.u_pe_array.conv2_out_flat[cnn.u_fsm.dense_cnt*64+32 +: 8],
             cnn.u_pe_array.conv2_out_flat[cnn.u_fsm.dense_cnt*64+40 +: 8],
             cnn.u_pe_array.conv2_out_flat[cnn.u_fsm.dense_cnt*64+48 +: 8],
             cnn.u_pe_array.conv2_out_flat[cnn.u_fsm.dense_cnt*64+56 +: 8]);
  end

  // [BUG PROBE 3] In wcache_indx de biet da nap duoc bao nhieu bytes truoc L3_EXE
  if (cnn.u_fsm.state == 6'd17 && cnn.u_fsm.counter == 7'd0 && cnn.u_fsm.ch_batch == 3'd0 && cnn.u_fsm.dense_cnt == 6'd0) begin
    ("[PROBE3] t=%0t | wcache_indx khi vao L3_EXE = %0d (can = 64)",
             , cnn.u_cache_ctrl.wcache_indx);
  end

  // B?t kho?nh kh?c L3_RD counter==1 (l'''

if old in content:
    content = content.replace(old, new, 1)
    with open(file_path, 'w', encoding='latin-1') as f:
        f.write(content)
    print('Patch 2 OK')
else:
    print('Target not found')
