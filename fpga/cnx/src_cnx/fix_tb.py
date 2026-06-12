
# fix_tb.py - Rewrites the probe always block in cnn_tb.v
# Lines 67..141 (0-indexed: 66..140) are replaced with a clean version

with open('cnn_tb.v', 'r', encoding='latin-1') as f:
    lines = f.readlines()

# Verify we are replacing the right block
print(f"Total lines: {len(lines)}")
print(f"Line 67 (idx 66): {repr(lines[66][:60])}")
print(f"Line 141 (idx 140): {repr(lines[140][:60])}")

NEW_BLOCK = r"""always @(posedge clk) begin
  last_state <= cnn.u_fsm.state;

  // ===========================================================================
  // [PROBE 1] w_cache full dump khi bat dau L3_EXE group=0, batch=0
  //   Xac nhan BUG A: co du 64 bytes (8 PEs x 8 weights) duoc nap khong?
  //   Neu w_cache[8..63] = 00 -> thieu cycle o L3_RD
  // ===========================================================================
  if (cnn.u_fsm.state == 6'd17 && cnn.u_fsm.counter == 7'd0
      && cnn.u_fsm.ch_batch == 3'd0 && cnn.u_fsm.dense_cnt == 6'd0) begin
    $display("[P1] t=%0t wcache_indx=%0d khi vao L3_EXE (can=64, neu thieu -> BUG A)",
             $time, cnn.u_cache_ctrl.wcache_indx);
    $display("[P1] w_cache[ 0.. 7] PE0: %02x %02x %02x %02x %02x %02x %02x %02x",
             $time,
             cnn.u_cache_ctrl.w_cache[0],  cnn.u_cache_ctrl.w_cache[1],
             cnn.u_cache_ctrl.w_cache[2],  cnn.u_cache_ctrl.w_cache[3],
             cnn.u_cache_ctrl.w_cache[4],  cnn.u_cache_ctrl.w_cache[5],
             cnn.u_cache_ctrl.w_cache[6],  cnn.u_cache_ctrl.w_cache[7]);
    $display("[P1] w_cache[ 8..15] PE1: %02x %02x %02x %02x %02x %02x %02x %02x",
             $time,
             cnn.u_cache_ctrl.w_cache[8],  cnn.u_cache_ctrl.w_cache[9],
             cnn.u_cache_ctrl.w_cache[10], cnn.u_cache_ctrl.w_cache[11],
             cnn.u_cache_ctrl.w_cache[12], cnn.u_cache_ctrl.w_cache[13],
             cnn.u_cache_ctrl.w_cache[14], cnn.u_cache_ctrl.w_cache[15]);
    $display("[P1] w_cache[16..23] PE2: %02x %02x %02x %02x %02x %02x %02x %02x",
             $time,
             cnn.u_cache_ctrl.w_cache[16], cnn.u_cache_ctrl.w_cache[17],
             cnn.u_cache_ctrl.w_cache[18], cnn.u_cache_ctrl.w_cache[19],
             cnn.u_cache_ctrl.w_cache[20], cnn.u_cache_ctrl.w_cache[21],
             cnn.u_cache_ctrl.w_cache[22], cnn.u_cache_ctrl.w_cache[23]);
    $display("[P1] w_cache[24..31] PE3: %02x %02x %02x %02x %02x %02x %02x %02x",
             $time,
             cnn.u_cache_ctrl.w_cache[24], cnn.u_cache_ctrl.w_cache[25],
             cnn.u_cache_ctrl.w_cache[26], cnn.u_cache_ctrl.w_cache[27],
             cnn.u_cache_ctrl.w_cache[28], cnn.u_cache_ctrl.w_cache[29],
             cnn.u_cache_ctrl.w_cache[30], cnn.u_cache_ctrl.w_cache[31]);
    $display("[P1] w_cache[32..39] PE4: %02x %02x %02x %02x %02x %02x %02x %02x",
             $time,
             cnn.u_cache_ctrl.w_cache[32], cnn.u_cache_ctrl.w_cache[33],
             cnn.u_cache_ctrl.w_cache[34], cnn.u_cache_ctrl.w_cache[35],
             cnn.u_cache_ctrl.w_cache[36], cnn.u_cache_ctrl.w_cache[37],
             cnn.u_cache_ctrl.w_cache[38], cnn.u_cache_ctrl.w_cache[39]);
    $display("[P1] w_cache[40..47] PE5: %02x %02x %02x %02x %02x %02x %02x %02x",
             $time,
             cnn.u_cache_ctrl.w_cache[40], cnn.u_cache_ctrl.w_cache[41],
             cnn.u_cache_ctrl.w_cache[42], cnn.u_cache_ctrl.w_cache[43],
             cnn.u_cache_ctrl.w_cache[44], cnn.u_cache_ctrl.w_cache[45],
             cnn.u_cache_ctrl.w_cache[46], cnn.u_cache_ctrl.w_cache[47]);
    $display("[P1] w_cache[48..55] PE6: %02x %02x %02x %02x %02x %02x %02x %02x",
             $time,
             cnn.u_cache_ctrl.w_cache[48], cnn.u_cache_ctrl.w_cache[49],
             cnn.u_cache_ctrl.w_cache[50], cnn.u_cache_ctrl.w_cache[51],
             cnn.u_cache_ctrl.w_cache[52], cnn.u_cache_ctrl.w_cache[53],
             cnn.u_cache_ctrl.w_cache[54], cnn.u_cache_ctrl.w_cache[55]);
    $display("[P1] w_cache[56..63] PE7: %02x %02x %02x %02x %02x %02x %02x %02x",
             $time,
             cnn.u_cache_ctrl.w_cache[56], cnn.u_cache_ctrl.w_cache[57],
             cnn.u_cache_ctrl.w_cache[58], cnn.u_cache_ctrl.w_cache[59],
             cnn.u_cache_ctrl.w_cache[60], cnn.u_cache_ctrl.w_cache[61],
             cnn.u_cache_ctrl.w_cache[62], cnn.u_cache_ctrl.w_cache[63]);
  end

  // ===========================================================================
  // [PROBE 2] BRAM_W3 tung cycle trong L3_RD, batch=0, group=0
  //   Xac nhan BUG A: dem so dong de biet BRAM da doc duoc bao nhieu word
  //   Neu in it hon 17 dong -> L3_RD qua ngan (can 17 cycles: 0..16)
  // ===========================================================================
  if (cnn.u_fsm.state == 6'd16 && cnn.u_fsm.ch_batch == 3'd0
      && cnn.u_fsm.dense_cnt == 6'd0) begin
    $display("[P2] t=%0t L3_RD counter=%0d | BRAM_W3_ADDR=%0d BRAM_W3_DOUT=%08x wcache_indx=%0d",
             $time, cnn.u_fsm.counter,
             cnn.BRAM_W3_ADDR >> 2,
             cnn.BRAM_W3_DOUT,
             cnn.u_cache_ctrl.wcache_indx);
  end

  // ===========================================================================
  // [PROBE 3] conv2_out_flat tai dense_cnt=10..13 (vung ranh gioi bi zero)
  //   Xac nhan BUG B: du lieu bi 0 tu dense_cnt=11 vi stride sai?
  //   In ca gia tri raw cua flat bus de so sanh voi conv2_out thuc te
  // ===========================================================================
  if (cnn.u_fsm.state == 6'd16 && cnn.u_fsm.counter == 7'd1
      && cnn.u_fsm.ch_batch == 3'd0
      && (cnn.u_fsm.dense_cnt == 6'd10 || cnn.u_fsm.dense_cnt == 6'd11
       || cnn.u_fsm.dense_cnt == 6'd12 || cnn.u_fsm.dense_cnt == 6'd13)) begin
    $display("[P3] t=%0t dense_cnt=%0d | pe_pre_in: %0d %0d %0d %0d %0d %0d %0d %0d",
             $time, cnn.u_fsm.dense_cnt,
             cnn.u_pe_array.pe_pre_in[0], cnn.u_pe_array.pe_pre_in[1],
             cnn.u_pe_array.pe_pre_in[2], cnn.u_pe_array.pe_pre_in[3],
             cnn.u_pe_array.pe_pre_in[4], cnn.u_pe_array.pe_pre_in[5],
             cnn.u_pe_array.pe_pre_in[6], cnn.u_pe_array.pe_pre_in[7]);
    $display("[P3]   conv2_out_flat[bit_offset=%0d] raw bytes: %02x %02x %02x %02x %02x %02x %02x %02x",
             cnn.u_fsm.dense_cnt * 64,
             cnn.u_pe_array.conv2_out_flat[cnn.u_fsm.dense_cnt*64+0  +: 8],
             cnn.u_pe_array.conv2_out_flat[cnn.u_fsm.dense_cnt*64+8  +: 8],
             cnn.u_pe_array.conv2_out_flat[cnn.u_fsm.dense_cnt*64+16 +: 8],
             cnn.u_pe_array.conv2_out_flat[cnn.u_fsm.dense_cnt*64+24 +: 8],
             cnn.u_pe_array.conv2_out_flat[cnn.u_fsm.dense_cnt*64+32 +: 8],
             cnn.u_pe_array.conv2_out_flat[cnn.u_fsm.dense_cnt*64+40 +: 8],
             cnn.u_pe_array.conv2_out_flat[cnn.u_fsm.dense_cnt*64+48 +: 8],
             cnn.u_pe_array.conv2_out_flat[cnn.u_fsm.dense_cnt*64+56 +: 8]);
  end

  // ===========================================================================
  // [PROBE 4] L3_RD per group (giu nguyen)
  // ===========================================================================
  if (cnn.u_fsm.state == 6'd16 && cnn.u_fsm.counter == 7'd1
      && cnn.u_fsm.ch_batch == 3'd0) begin
    $display("[L3_RD] t=%0t ch_batch=%0d dense_cnt=%0d | pe_pre_in[0..7]: %0d %0d %0d %0d %0d %0d %0d %0d",
             $time,
             cnn.u_fsm.ch_batch, cnn.u_fsm.dense_cnt,
             cnn.u_pe_array.pe_pre_in[0], cnn.u_pe_array.pe_pre_in[1],
             cnn.u_pe_array.pe_pre_in[2], cnn.u_pe_array.pe_pre_in[3],
             cnn.u_pe_array.pe_pre_in[4], cnn.u_pe_array.pe_pre_in[5],
             cnn.u_pe_array.pe_pre_in[6], cnn.u_pe_array.pe_pre_in[7]);
  end

  // ===========================================================================
  // [PROBE 5] L3_ACC dense_cnt==51 -> pe_out tich luy cuoi batch
  // ===========================================================================
  if (cnn.u_fsm.state == 6'd18 && cnn.u_fsm.dense_cnt == 6'd51) begin
    $display("[L3_ACC51] t=%0t ch_batch=%0d | pe_out[0..7]: %0d %0d %0d %0d %0d %0d %0d %0d",
             $time, cnn.u_fsm.ch_batch,
             $signed(cnn.u_pe_array.pe_out_flat[31:0]),
             $signed(cnn.u_pe_array.pe_out_flat[63:32]),
             $signed(cnn.u_pe_array.pe_out_flat[95:64]),
             $signed(cnn.u_pe_array.pe_out_flat[127:96]),
             $signed(cnn.u_pe_array.pe_out_flat[159:128]),
             $signed(cnn.u_pe_array.pe_out_flat[191:160]),
             $signed(cnn.u_pe_array.pe_out_flat[223:192]),
             $signed(cnn.u_pe_array.pe_out_flat[255:224]));
  end

  // ===========================================================================
  // [PROBE 6] L3_OUT -> dense1_psum sau moi batch
  // ===========================================================================
  if (cnn.u_fsm.state == 6'd19) begin
    $display("[L3_OUT] t=%0t ch_batch=%0d | dense1_psum[ch][0..7]: %0d %0d %0d %0d %0d %0d %0d %0d",
             $time, cnn.u_fsm.ch_batch,
             $signed(cnn.u_psum_fc_ctrl.dense1_psum[cnn.u_fsm.ch_batch][0]),
             $signed(cnn.u_psum_fc_ctrl.dense1_psum[cnn.u_fsm.ch_batch][1]),
             $signed(cnn.u_psum_fc_ctrl.dense1_psum[cnn.u_fsm.ch_batch][2]),
             $signed(cnn.u_psum_fc_ctrl.dense1_psum[cnn.u_fsm.ch_batch][3]),
             $signed(cnn.u_psum_fc_ctrl.dense1_psum[cnn.u_fsm.ch_batch][4]),
             $signed(cnn.u_psum_fc_ctrl.dense1_psum[cnn.u_fsm.ch_batch][5]),
             $signed(cnn.u_psum_fc_ctrl.dense1_psum[cnn.u_fsm.ch_batch][6]),
             $signed(cnn.u_psum_fc_ctrl.dense1_psum[cnn.u_fsm.ch_batch][7]));
  end
end
"""

# Replace lines 67..141 (0-indexed 66..140)
new_lines = lines[:66] + [NEW_BLOCK + '\n'] + lines[141:]

with open('cnn_tb.v', 'w', encoding='latin-1') as f:
    f.writelines(new_lines)

print(f"Done. New file has {len(new_lines)} lines")
# Sanity check
with open('cnn_tb.v', 'r', encoding='latin-1') as f:
    content = f.read()
print(f"[P1] count: {content.count('[P1]')}")
print(f"[P2] count: {content.count('[P2]')}")
print(f"[P3] count: {content.count('[P3]')}")
print(f"$display count: {content.count('$display')}")
