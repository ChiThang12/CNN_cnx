import sys

file_path = 'cnn_tb.v'
try:
    with open(file_path, 'r', encoding='latin-1') as f:
        content = f.read()

    target = 'last_state <= cnn.u_fsm.state;'
    replacement = '''  last_state <= cnn.u_fsm.state;

  // [BUG PROBE L3_EXE] In ra 16 bytes dau tien cua w_cache tai L3_EXE (counter=0, group=0)
  if (cnn.u_fsm.state == 6\\'d17 && cnn.u_fsm.counter == 7\\'d0 && cnn.u_fsm.ch_batch == 3\\'d0 && cnn.u_fsm.dense_cnt == 6\\'d0) begin
    $display("[BUG PROBE] t=%0t | w_cache[0..7] (PE0 weights): %02x %02x %02x %02x %02x %02x %02x %02x",
             $time,
             cnn.u_cache_ctrl.w_cache[0], cnn.u_cache_ctrl.w_cache[1], cnn.u_cache_ctrl.w_cache[2], cnn.u_cache_ctrl.w_cache[3],
             cnn.u_cache_ctrl.w_cache[4], cnn.u_cache_ctrl.w_cache[5], cnn.u_cache_ctrl.w_cache[6], cnn.u_cache_ctrl.w_cache[7]);
    $display("[BUG PROBE] t=%0t | w_cache[8..15] (PE1 weights): %02x %02x %02x %02x %02x %02x %02x %02x",
             $time,
             cnn.u_cache_ctrl.w_cache[8], cnn.u_cache_ctrl.w_cache[9], cnn.u_cache_ctrl.w_cache[10], cnn.u_cache_ctrl.w_cache[11],
             cnn.u_cache_ctrl.w_cache[12], cnn.u_cache_ctrl.w_cache[13], cnn.u_cache_ctrl.w_cache[14], cnn.u_cache_ctrl.w_cache[15]);
  end'''
    if target in content:
        content = content.replace(target, replacement)
        with open(file_path, 'w', encoding='latin-1') as f:
            f.write(content)
        print('Inserted BUG PROBE successfully.')
    else:
        print('Target string not found.')
except Exception as e:
    print('Error:', e)
