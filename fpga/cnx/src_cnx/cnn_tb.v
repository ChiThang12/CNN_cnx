`timescale 1ns/10ps
`define CYCLE 15.4
// =============================================================================
// Module: cnn_tb  (debug-enhanced version)
// =============================================================================
module cnn_tb;

reg clk, rst, start;
reg        ready;
wire       done;
wire [7:0] result;

wire [31:0] BRAM_IF1_ADDR; wire [3:0]  BRAM_IF1_WE; wire BRAM_IF1_EN;
wire [31:0] BRAM_IF1_DOUT; wire [31:0] BRAM_IF1_DIN;
wire [31:0] BRAM_IF2_ADDR; wire [3:0]  BRAM_IF2_WE; wire BRAM_IF2_EN;
wire [31:0] BRAM_IF2_DOUT; wire [31:0] BRAM_IF2_DIN;
wire [31:0] BRAM_W1_ADDR;  wire [3:0]  BRAM_W1_WE;  wire BRAM_W1_EN;
wire [31:0] BRAM_W1_DOUT;  wire [31:0] BRAM_W1_DIN;
wire [31:0] BRAM_W2_ADDR;  wire [3:0]  BRAM_W2_WE;  wire BRAM_W2_EN;
wire [31:0] BRAM_W2_DOUT;  wire [31:0] BRAM_W2_DIN;
wire [31:0] BRAM_W3_ADDR;  wire [3:0]  BRAM_W3_WE;  wire BRAM_W3_EN;
wire [31:0] BRAM_W3_DOUT;  wire [31:0] BRAM_W3_DIN;
wire [31:0] BRAM_W4_ADDR;  wire [3:0]  BRAM_W4_WE;  wire BRAM_W4_EN;
wire [31:0] BRAM_W4_DOUT;  wire [31:0] BRAM_W4_DIN;

cnn_top cnn(
  .clk(clk),.rst(rst),.start(start),.ready(ready),.done(done),.result(result),
  .BRAM_IF1_ADDR(BRAM_IF1_ADDR),.BRAM_IF1_WE(BRAM_IF1_WE),.BRAM_IF1_EN(BRAM_IF1_EN),
  .BRAM_IF1_DOUT(BRAM_IF1_DOUT),.BRAM_IF1_DIN(BRAM_IF1_DIN),
  .BRAM_IF2_ADDR(BRAM_IF2_ADDR),.BRAM_IF2_WE(BRAM_IF2_WE),.BRAM_IF2_EN(BRAM_IF2_EN),
  .BRAM_IF2_DOUT(BRAM_IF2_DOUT),.BRAM_IF2_DIN(BRAM_IF2_DIN),
  .BRAM_W1_ADDR(BRAM_W1_ADDR),.BRAM_W1_WE(BRAM_W1_WE),.BRAM_W1_EN(BRAM_W1_EN),
  .BRAM_W1_DOUT(BRAM_W1_DOUT),.BRAM_W1_DIN(BRAM_W1_DIN),
  .BRAM_W2_ADDR(BRAM_W2_ADDR),.BRAM_W2_WE(BRAM_W2_WE),.BRAM_W2_EN(BRAM_W2_EN),
  .BRAM_W2_DOUT(BRAM_W2_DOUT),.BRAM_W2_DIN(BRAM_W2_DIN),
  .BRAM_W3_ADDR(BRAM_W3_ADDR),.BRAM_W3_WE(BRAM_W3_WE),.BRAM_W3_EN(BRAM_W3_EN),
  .BRAM_W3_DOUT(BRAM_W3_DOUT),.BRAM_W3_DIN(BRAM_W3_DIN),
  .BRAM_W4_ADDR(BRAM_W4_ADDR),.BRAM_W4_WE(BRAM_W4_WE),.BRAM_W4_EN(BRAM_W4_EN),
  .BRAM_W4_DOUT(BRAM_W4_DOUT),.BRAM_W4_DIN(BRAM_W4_DIN)
);

bram bram_w1(.clk(clk),.rst(rst),.wen(BRAM_W1_WE),.addr(BRAM_W1_ADDR),.en(BRAM_W1_EN),.dout(BRAM_W1_DOUT),.din(BRAM_W1_DIN));
bram bram_w2(.clk(clk),.rst(rst),.wen(BRAM_W2_WE),.addr(BRAM_W2_ADDR),.en(BRAM_W2_EN),.dout(BRAM_W2_DOUT),.din(BRAM_W2_DIN));
bram bram_w3(.clk(clk),.rst(rst),.wen(BRAM_W3_WE),.addr(BRAM_W3_ADDR),.en(BRAM_W3_EN),.dout(BRAM_W3_DOUT),.din(BRAM_W3_DIN));
bram bram_w4(.clk(clk),.rst(rst),.wen(BRAM_W4_WE),.addr(BRAM_W4_ADDR),.en(BRAM_W4_EN),.dout(BRAM_W4_DOUT),.din(BRAM_W4_DIN));
bram bram_if1(.clk(clk),.rst(rst),.wen(BRAM_IF1_WE),.addr(BRAM_IF1_ADDR),.en(BRAM_IF1_EN),.dout(BRAM_IF1_DOUT),.din(BRAM_IF1_DIN));
bram bram_if2(.clk(clk),.rst(rst),.wen(BRAM_IF2_WE),.addr(BRAM_IF2_ADDR),.en(BRAM_IF2_EN),.dout(BRAM_IF2_DOUT),.din(BRAM_IF2_DIN));

always #(`CYCLE / 2) clk = ~clk;

// ---------------------------------------------------------------------------
// X-propagation watchdog
// ---------------------------------------------------------------------------
always @(posedge clk) begin
  if (!rst && (^cnn.u_pe_array.pe_out_flat[31:0] === 1'bx)) begin
    $display("FATAL: pe_out[0] X at time %0t | state=%0d layer=%0d",
             $time, cnn.u_fsm.state, cnn.u_fsm.layer);
    $stop;
  end
end

// ---------------------------------------------------------------------------
// [PROBE] Layer3 first-group trace: print pe_pre_in and pe_out each L3_EXE
// ---------------------------------------------------------------------------
// Dng ?? xc nh?n conv2_out_flat ?ang ???c ??c ?ng
reg [5:0] last_state;
always @(posedge clk) begin
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


// ---------------------------------------------------------------------------
// Main stimulus
// ---------------------------------------------------------------------------
integer b, n, p, q;

initial begin
  clk   = 1'b0;
  rst   = 1'b1;
  start = 1'b0;
  ready = 1'b1;

  #1          rst   = 1'b0;
  #20         start = 1'b1;
  #(`CYCLE)   start = 1'b0;

  wait (done);
  #(`CYCLE * 2);

  $timeformat(-9, 2, " ns", 10);
  $display("\n===== Inference Done =====");
  $display("Simulation time = %t", $time);
  $display("Result (class)  = %0d  => Class %0d", result, result);

  // -----------------------------------------------------------------------
  // CHECK: conv2_out_flat port connection (xc nh?n fix Bug 1 ? c hi?u l?c)
  // In 8 gi tr? ??u c?a conv2_out_flat qua pe_array port
  // -----------------------------------------------------------------------
  $display("\n--- [CHECK] conv2_out_flat trong pe_array (first 8 bytes) ---");
  $write("  ");
  for (p = 0; p < 8; p = p + 1)
    $write("%0d ", cnn.u_pe_array.conv2_out_flat[p*8 +: 8]);
  $display("");

  // -----------------------------------------------------------------------
  // Conv2 output: ton b? 416 entries, in d?ng 4 ch_batch  13 col  8 PE
  // -----------------------------------------------------------------------
  $display("\n--- Conv2 out [ch_batch][col_pos][PE] (non-zero only) ---");
  for (b = 0; b < 4; b = b + 1)
    for (n = 0; n < 13; n = n + 1)
      for (p = 0; p < 8; p = p + 1) begin
        q = b * 104 + n * 8 + p;
        if (cnn.u_psum_fc_ctrl.conv2_out[q] != 0)
          $display("  conv2_out[ch%0d][col%0d][pe%0d] = %0d  (idx=%0d)",
                   b, n, p, cnn.u_psum_fc_ctrl.conv2_out[q], q);
      end

  // -----------------------------------------------------------------------
  // Dense1: ??u vo (conv2_out_flat qua pe_pre_in) vs ??u ra (dense1_psum)
  // -----------------------------------------------------------------------
  $display("\n--- Dense1 output [6 batch x 8 neuron] ---");
  for (b = 0; b < 6; b = b + 1) begin
    $write("  batch[%0d]: ", b);
    for (n = 0; n < 8; n = n + 1)
      $write("%0d ", $signed(cnn.u_psum_fc_ctrl.dense1_psum[b][n]));
    $display("");
  end

  // -----------------------------------------------------------------------
  // Dense2 scores
  // -----------------------------------------------------------------------
  $display("\n--- Dense2 scores ---");
  $display("  dense2_psum[0] (Benign)  = %0d", $signed(cnn.u_psum_fc_ctrl.dense2_psum[0]));
  $display("  dense2_psum[1] (Malware) = %0d", $signed(cnn.u_psum_fc_ctrl.dense2_psum[1]));

  // -----------------------------------------------------------------------
  // Conv2 psum sample (xc nh?n L2 v?n ?ng)
  // -----------------------------------------------------------------------
  $display("\n--- Conv2 psum[ch0][col0..2][0..7] ---");
  for (n = 0; n < 3; n = n + 1) begin
    $write("  col%0d: ", n);
    for (p = 0; p < 8; p = p + 1)
      $write("%0d ", $signed(cnn.u_psum_fc_ctrl.conv2_psum[0][n][p]));
    $display("");
  end

  // -----------------------------------------------------------------------
  // MaxPool sample
  // -----------------------------------------------------------------------
  $display("\n--- MaxPool output (bram_if2.mem[0..7]) ---");
  $write("  ");
  for (p = 0; p < 8; p = p + 1)
    $write("%08x ", bram_if2.mem[p]);
  $display("");

  // -----------------------------------------------------------------------
  // w_cache t?i th?i ?i?m k?t thc (ki?m tra L3 weights c load ?ng khng)
  // -----------------------------------------------------------------------
  $display("\n--- w_cache[0..17] sau khi sim (L3/L4 weights sample) ---");
  $write("  ");
  for (p = 0; p < 18; p = p + 1)
    $write("%02x ", cnn.u_cache_ctrl.w_cache[p]);
  $display("");

  // -----------------------------------------------------------------------
  // bram_w3 sample: 8 words ??u (Dense1 weights)
  // -----------------------------------------------------------------------
  $display("\n--- bram_w3.mem[0..7] (Dense1 weight words) ---");
  $write("  ");
  for (p = 0; p < 8; p = p + 1)
    $write("%08x ", bram_w3.mem[p]);
  $display("");

  $finish;
end

// ---------------------------------------------------------------------------
// Memory Initialization
// ---------------------------------------------------------------------------
initial begin
  $readmemh("D:/PROJECT_CNX/hardware/hardware/bram_w1.hex",  bram_w1.mem);
  $readmemh("D:/PROJECT_CNX/hardware/hardware/bram_w2.hex",  bram_w2.mem);
  $readmemh("D:/PROJECT_CNX/hardware/hardware/bram_w3.hex",  bram_w3.mem);
  $readmemh("D:/PROJECT_CNX/hardware/hardware/bram_w4.hex",  bram_w4.mem);
  $readmemh("D:/PROJECT_CNX/hardware/hardware/test_cases/test4_in32.hex",
            bram_if1.mem);
end

// ---------------------------------------------------------------------------
// Waveform Dump
// ---------------------------------------------------------------------------
initial begin
  $dumpfile("cnn_cnx.vcd");
  $dumpvars;
end



// ============================================================================
// Layer Output Debug Dumps
// ============================================================================
integer dbg_i;
reg dump_l2_done, dump_l3_done, dump_l4_done;

initial begin
  dump_l2_done = 0;
  dump_l3_done = 0;
  dump_l4_done = 0;
end

task dump_conv2_output;
begin
  $display("\n========== CONV2 OUTPUT ==========");
  for (dbg_i=0; dbg_i<416; dbg_i=dbg_i+1)
    $write("%0d ", cnn.conv2_out_flat[dbg_i*8 +: 8]);
  $display("\n==================================");
end
endtask

task dump_dense1_output;
begin
  $display("\n========== DENSE1 OUTPUT ==========");
  for (dbg_i=0; dbg_i<48; dbg_i=dbg_i+1)
    $display("dense1[%0d] = %0d",
             dbg_i,
             cnn.dense1_psum_flat[dbg_i*32 +: 32]);
  $display("===================================");
end
endtask

task dump_dense2_output;
begin
  $display("\n========== DENSE2 OUTPUT ==========");
  $display("class0 = %0d", cnn.u_psum_fc_ctrl.dense2_psum[0]);
  $display("class1 = %0d", cnn.u_psum_fc_ctrl.dense2_psum[1]);
  $display("===================================");
end
endtask

always @(posedge clk) begin
  if (!rst) begin

    // Layer2 -> Layer3 transition
    if (!dump_l2_done && cnn.u_fsm.state == 6'd18) begin
      dump_l2_done <= 1'b1;
      dump_conv2_output();
    end

    // Layer3 -> Layer4 transition
    if (!dump_l3_done && cnn.u_fsm.state == 6'd22) begin
      dump_l3_done <= 1'b1;
      dump_dense1_output();
    end

    // Final result
    if (!dump_l4_done && done) begin
      dump_l4_done <= 1'b1;
      dump_dense2_output();
    end

  end
end


endmodule
